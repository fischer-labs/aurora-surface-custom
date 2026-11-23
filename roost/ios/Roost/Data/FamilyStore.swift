import Foundation
import Observation
import RoostKit

/// All data for the open family. Every mutation is applied locally first,
/// persisted, then sent to the server through an ordered outbox.
@MainActor
@Observable
final class FamilyStore {
    enum SyncState: Equatable { case idle, syncing, offline, error(String) }

    let userId: String
    let remote: PocketBaseClient?

    var family: Family
    var members: [Member]
    var calendars: [FamilyCalendar]
    var events: [CalendarEvent]
    var busy: [CalendarEvent]
    var lists: [TaskList]
    var tasks: [TaskItem]
    var grocery: [GroceryItem]
    var learned: [LearnedTerm]
    var infoCards: [InfoCard]
    var invites: [Invite]
    var feeds: [Feed]
    var syncState: SyncState = .idle
    var lastSync: Date?
    private(set) var outbox: [OutboxOp]

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var realtime: RealtimeClient?

    init(snapshot s: Snapshot, userId: String, remote: PocketBaseClient?) {
        self.userId = userId
        self.remote = remote
        family = s.family; members = s.members; calendars = s.calendars; events = s.events; busy = s.busy
        lists = s.lists; tasks = s.tasks; grocery = s.grocery; learned = s.learned; infoCards = s.infoCards
        invites = s.invites; feeds = s.feeds; outbox = s.outbox; lastSync = s.lastSync
    }

    var isLocal: Bool { remote == nil }

    // MARK: - Derived

    var me: Member? { members.first { $0.user == userId } }
    var myRole: Role { me?.role ?? .owner }
    var isAdmin: Bool { isLocal || myRole.isAdmin }
    var sortedMembers: [Member] { members.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
    func member(_ id: String) -> Member? { members.first { $0.id == id } }
    func members(_ ids: [String]) -> [Member] { ids.compactMap(member) }
    func calendar(_ id: String) -> FamilyCalendar? { calendars.first { $0.id == id } }
    func list(_ id: String) -> TaskList? { lists.first { $0.id == id } }

    var liveCalendars: [FamilyCalendar] { calendars.filter { !$0.deleted }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
    var liveLists: [TaskList] { lists.filter { !$0.deleted && !$0.archived }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
    var groceryLists: [TaskList] { liveLists.filter { $0.kind == .grocery } }
    var taskLists: [TaskList] { liveLists.filter { $0.kind != .grocery } }
    var liveCards: [InfoCard] { infoCards.filter { !$0.deleted }.sorted { ($0.pinned ? 0 : 1, $0.sortOrder) < ($1.pinned ? 0 : 1, $1.sortOrder) } }

    func canEdit(_ c: FamilyCalendar) -> Bool { c.kind != .subscription && (isLocal || c.editors.contains(userId)) }
    func canManage(_ c: FamilyCalendar) -> Bool { isAdmin || (c.owner != "" && c.owner == me?.id) }
    func canEdit(_ l: TaskList) -> Bool { isLocal || l.editors.contains(userId) }
    func canEdit(_ e: CalendarEvent) -> Bool { !e.isReadOnlyImport && !e.isBusyBlock && (calendar(e.calendar).map(canEdit) ?? false) }
    func canEdit(_ t: TaskItem) -> Bool { (list(t.list).map(canEdit) ?? false) || (me.map { t.assignees.contains($0.id) } ?? false) }
    func canEdit(_ c: InfoCard) -> Bool { isLocal || isAdmin || c.editors.contains(userId) }
    var editableCalendars: [FamilyCalendar] { liveCalendars.filter(canEdit) }

    var categorizer: GroceryCategorizer {
        GroceryCategorizer(learned: Dictionary(learned.map { ($0.term, $0.category) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Color for an event: its first person, else its calendar.
    func colorName(for e: CalendarEvent, byPerson: Bool = true) -> String {
        if !e.color.isEmpty { return e.color }
        if byPerson, let m = e.members.first.flatMap(member) { return m.color }
        return calendar(e.calendar)?.color ?? "orange"
    }

    func occurrences(from: Date, to: Date, hiddenCalendars: Set<String> = [], people: Set<String> = [], includeBusy: Bool = true) -> [Occurrence] {
        var src = events.filter { !$0.deleted && !hiddenCalendars.contains($0.calendar) }
        if includeBusy { src += busy.filter { !hiddenCalendars.contains($0.calendar) } }
        if !people.isEmpty {
            src = src.filter { e in e.members.contains(where: { people.contains($0) }) || (!e.driver.isEmpty && people.contains(e.driver)) }
        }
        return Occurrence.expand(src, from: from, to: to)
    }

    func tasksDue(on day: Date) -> [TaskItem] {
        let key = LocalDateTime(day, in: .current).date.description
        return tasks.filter { !$0.deleted && !$0.completed && $0.due.hasPrefix(key) }
    }

    // MARK: - Persistence

    var snapshot: Snapshot {
        var s = Snapshot(family: family)
        s.members = members; s.calendars = calendars; s.events = events; s.busy = busy; s.lists = lists; s.tasks = tasks
        s.grocery = grocery; s.learned = learned; s.infoCards = infoCards; s.invites = invites; s.feeds = feeds
        s.outbox = outbox; s.lastSync = lastSync
        return s
    }

    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.snapshot.write()
            ReminderScheduler.shared.reschedule(self)
        }
    }

    // MARK: - Generic local upsert

    private func put<T: Identifiable>(_ arr: inout [T], _ item: T) where T.ID == String {
        if let i = arr.firstIndex(where: { $0.id == item.id }) { arr[i] = item } else { arr.append(item) }
    }

    /// Applies a server record (from a pull, a write echo or realtime).
    func apply(_ j: JSON, collection: String) {
        switch collection {
        case "families": family = Family(json: j)
        case "memberships": put(&members, Member(json: j))
        case "calendars": put(&calendars, FamilyCalendar(json: j))
        case "events": put(&events, CalendarEvent(json: j))
        case "lists": put(&lists, TaskList(json: j))
        case "tasks": put(&tasks, TaskItem(json: j))
        case "groceryItems": put(&grocery, GroceryItem(json: j))
        case "groceryLearned": put(&learned, LearnedTerm(json: j))
        case "infoCards": put(&infoCards, InfoCard(json: j))
        case "invites": put(&invites, Invite(json: j))
        case "feeds": put(&feeds, Feed(json: j))
        default: break
        }
    }

    func remove(id: String, collection: String) {
        switch collection {
        case "memberships": members.removeAll { $0.id == id }
        case "calendars": calendars.removeAll { $0.id == id }
        case "events": events.removeAll { $0.id == id }
        case "lists": lists.removeAll { $0.id == id }
        case "tasks": tasks.removeAll { $0.id == id }
        case "groceryItems": grocery.removeAll { $0.id == id }
        case "groceryLearned": learned.removeAll { $0.id == id }
        case "infoCards": infoCards.removeAll { $0.id == id }
        case "invites": invites.removeAll { $0.id == id }
        case "feeds": feeds.removeAll { $0.id == id }
        default: break
        }
    }

    // MARK: - Outbox

    private func enqueue(_ collection: String, id: String, kind: OutboxOp.Kind, body: JSON) {
        guard !isLocal else { saveSoon(); return }
        // Fold updates into a pending create/update of the same record.
        if kind == .update, let i = outbox.lastIndex(where: { $0.recordId == id && $0.collection == collection && $0.kind != .delete }) {
            outbox[i].body.merge(body) { _, new in new }
        } else {
            outbox.append(OutboxOp(collection: collection, recordId: id, kind: kind, body: body))
        }
        saveSoon()
        Task { await flush() }
    }

    func flush() async {
        guard let remote, !flushing else { return }
        flushing = true
        defer { flushing = false }
        while let op = outbox.first {
            do {
                switch op.kind {
                case .create:
                    var body = op.body
                    body["id"] = op.recordId
                    do {
                        apply(try await remote.create(op.collection, body), collection: op.collection)
                    } catch let e as PBError where e.fieldErrors["id"] != nil {
                        // Already created (a retry after a lost response): update instead.
                        apply(try await remote.update(op.collection, id: op.recordId, op.body), collection: op.collection)
                    }
                case .update:
                    apply(try await remote.update(op.collection, id: op.recordId, op.body), collection: op.collection)
                case .delete:
                    try await remote.delete(op.collection, id: op.recordId)
                }
                outbox.removeFirst()
                if syncState == .offline { syncState = .idle }
            } catch let e as PBError where e.isOffline {
                syncState = .offline
                break
            } catch let e as PBError {
                // The server refused (permissions/validation): drop it and resync that collection.
                outbox.removeFirst()
                syncState = .error(e.errorDescription ?? e.message)
                Task { await syncNow() }
            } catch {
                outbox.removeFirst()
            }
        }
        saveSoon()
    }

    // MARK: - Sync

    static let synced = ["calendars", "events", "lists", "tasks", "groceryItems", "groceryLearned", "infoCards"]

    func syncNow() async {
        guard let remote else { return }
        syncState = .syncing
        await flush()
        do {
            let fam = try await remote.send("GET", "api/collections/families/records/\(family.id)") as? JSON ?? [:]
            family = Family(json: fam)
            let f = "family = \(PocketBaseClient.quote(family.id))"
            members = try await remote.list("memberships", filter: f, sort: "sortOrder,created").map(Member.init(json:))
            let pendingIds = Set(outbox.map(\.recordId))
            calendars = merge(calendars, try await remote.list("calendars", filter: f + " && deleted = false").map(FamilyCalendar.init(json:)), pendingIds)
            events = merge(events, try await remote.list("events", filter: f + " && deleted = false").map(CalendarEvent.init(json:)), pendingIds)
            lists = merge(lists, try await remote.list("lists", filter: f + " && deleted = false").map(TaskList.init(json:)), pendingIds)
            tasks = merge(tasks, try await remote.list("tasks", filter: f + " && deleted = false").map(TaskItem.init(json:)), pendingIds)
            grocery = merge(grocery, try await remote.list("groceryItems", filter: f + " && deleted = false").map(GroceryItem.init(json:)), pendingIds)
            learned = try await remote.list("groceryLearned", filter: f).map(LearnedTerm.init(json:))
            infoCards = merge(infoCards, try await remote.list("infoCards", filter: f + " && deleted = false").map(InfoCard.init(json:)), pendingIds)
            if isAdmin { invites = (try? await remote.list("invites", filter: f + " && usedBy = ''", sort: "-created").map(Invite.init(json:))) ?? [] }
            feeds = (try? await remote.list("feeds", filter: f).map(Feed.init(json:))) ?? []
            let from = Calendar.current.date(byAdding: .day, value: -45, to: Date())!
            let to = Calendar.current.date(byAdding: .day, value: 400, to: Date())!
            busy = (try? await remote.busy(family: family.id, from: from, to: to)) ?? busy
            lastSync = Date()
            syncState = outbox.isEmpty ? .idle : .offline
            saveSoon()
        } catch let e as PBError {
            syncState = e.isOffline ? .offline : .error(e.message)
        } catch {
            syncState = .error(error.localizedDescription)
        }
    }

    /// Server list wins, but keep local records that still have unsent writes.
    private func merge<T: Identifiable>(_ local: [T], _ server: [T], _ pending: Set<String>) -> [T] where T.ID == String {
        var out = server
        let serverIds = Set(server.map(\.id))
        for l in local where pending.contains(l.id) {
            if let i = out.firstIndex(where: { $0.id == l.id }) { out[i] = l } else if !serverIds.contains(l.id) { out.append(l) }
        }
        return out
    }

    func startRealtime() {
        guard let remote, realtime == nil else { return }
        let topics = ["families/" + family.id, "memberships/*"] + FamilyStore.synced.map { "\($0)/*" } + ["invites/*"]
        let rt = RealtimeClient(baseURL: remote.baseURL, token: { remote.token }, topics: topics)
        realtime = rt
        rt.start(onMessage: { [weak self] topic, action, record in
            guard let self else { return }
            let coll = String(topic.split(separator: "/").first ?? "")
            guard record.s("family").isEmpty || record.s("family") == self.family.id || coll == "families" else { return }
            if action == "delete" { self.remove(id: record.s("id"), collection: coll) } else { self.apply(record, collection: coll) }
            if coll == "memberships" || coll == "calendars" || coll == "lists" {
                // Access may have changed; a full pull is cheap and authoritative.
                Task { await self.syncNow() }
            }
            self.saveSoon()
        }, onReconnect: { [weak self] in
            Task { await self?.syncNow() }
        })
    }

    func stopRealtime() {
        realtime?.stop()
        realtime = nil
    }

    // MARK: - Events

    func newEvent(start: Date, allDay: Bool = false, calendarId: String? = nil) -> CalendarEvent {
        let cal = calendarId.flatMap(calendar) ?? editableCalendars.first { $0.kind == .family } ?? editableCalendars.first
        var e = CalendarEvent(id: RecordID.make(), calendar: cal?.id ?? "", title: "", start: start,
                              end: allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600),
                              allDay: allDay, tz: family.timezone.isEmpty ? TimeZone.current.identifier : family.timezone)
        e.family = family.id
        e.reminders = cal?.defaultReminders ?? [30]
        e.createdBy = userId
        return e
    }

    func save(event e: CalendarEvent) {
        var e = e
        e.family = family.id
        if e.tz.isEmpty { e.tz = TimeZone.current.identifier }
        let isNew = !events.contains { $0.id == e.id }
        e.updated = Date()
        put(&events, e)
        enqueue("events", id: e.id, kind: isNew ? .create : .update, body: e.writable)
    }

    func delete(event e: CalendarEvent) {
        guard var cur = events.first(where: { $0.id == e.id }) else { return }
        cur.deleted = true
        put(&events, cur)
        enqueue("events", id: e.id, kind: .update, body: ["deleted": true])
    }

    /// Removes one occurrence of a recurring event.
    func deleteOccurrence(_ o: Occurrence) {
        guard var master = events.first(where: { $0.id == o.event.id }) else { return }
        if !master.exdates.contains(o.key) { master.exdates.append(o.key) }
        put(&events, master)
        enqueue("events", id: master.id, kind: .update, body: ["exdates": master.exdates])
    }

    /// Ends a series before this occurrence ("delete this and following").
    func endSeries(before o: Occurrence) {
        guard var master = events.first(where: { $0.id == o.event.id }), var rule = RRule(master.rrule) else { return }
        let tz = master.timeZone
        let prevDay = LocalDateTime(o.start, in: tz).date.adding(days: -1)
        rule.count = nil
        rule.until = .date(prevDay)
        master.rrule = rule.string
        put(&events, master)
        enqueue("events", id: master.id, kind: .update, body: ["rrule": master.rrule])
    }

    /// Saves an edit to a single occurrence: excludes it from the series and creates a standalone copy.
    func saveOccurrenceEdit(original o: Occurrence, edited: CalendarEvent) {
        deleteOccurrence(o)
        var copy = edited
        copy.id = RecordID.make()
        copy.rrule = ""
        copy.exdates = []
        copy.recurrenceParent = o.event.id
        save(event: copy)
    }

    /// Saves an edit for this and following occurrences: splits the series.
    func saveFollowingEdit(original o: Occurrence, edited: CalendarEvent) {
        endSeries(before: o)
        var copy = edited
        copy.id = RecordID.make()
        copy.exdates = []
        save(event: copy)
    }

    // MARK: - Tasks

    func newTask(list: String, title: String = "") -> TaskItem {
        var t = TaskItem(id: RecordID.make(), list: list, title: title)
        t.family = family.id
        t.createdBy = userId
        t.sortOrder = Double((tasks.filter { $0.list == list }.map(\.sortOrder).max() ?? 0) + 1)
        return t
    }

    func save(task t: TaskItem) {
        var t = t
        t.family = family.id
        t.updated = Date()
        let isNew = !tasks.contains { $0.id == t.id }
        put(&tasks, t)
        enqueue("tasks", id: t.id, kind: isNew ? .create : .update, body: t.writable)
    }

    func toggle(task t: TaskItem) {
        guard var cur = tasks.first(where: { $0.id == t.id }) else { return }
        if !cur.completed && !cur.rrule.isEmpty && !cur.due.isEmpty {
            // Recurring: log a completed copy and roll the original forward.
            var done = cur
            done.id = RecordID.make()
            done.rrule = ""
            done.completed = true
            done.completedAt = Date()
            save(task: done)
            if let next = TaskRecurrence.nextDue(due: cur.due, rrule: cur.rrule, completedAt: LocalDateTime(Date(), in: .current)) {
                cur.due = next
            } else {
                cur.completed = true
                cur.completedAt = Date()
            }
            save(task: cur)
            return
        }
        cur.completed.toggle()
        cur.completedAt = cur.completed ? Date() : nil
        save(task: cur)
    }

    func delete(task t: TaskItem) {
        guard var cur = tasks.first(where: { $0.id == t.id }) else { return }
        cur.deleted = true
        put(&tasks, cur)
        enqueue("tasks", id: cur.id, kind: .update, body: ["deleted": true])
        for sub in tasks where sub.parent == t.id && !sub.deleted { delete(task: sub) }
    }

    func subtasks(of t: TaskItem) -> [TaskItem] { tasks.filter { $0.parent == t.id && !$0.deleted }.sorted { $0.sortOrder < $1.sortOrder } }

    // MARK: - Groceries

    /// Adds one or more lines ("milk, 2 lb chicken\neggs"). Returns names that need smart categorization.
    @discardableResult
    func addGroceries(_ text: String, list: String) -> [GroceryItem] {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" }).map(String.init)
        let cat = categorizer
        var unknown: [GroceryItem] = []
        for line in lines {
            guard let p = GroceryParser.parse(line) else { continue }
            let existing = grocery.filter { $0.list == list && !$0.deleted }
            let d = GroceryMerge.decide(adding: p, to: existing.map { GroceryMerge.Existing(name: $0.name, quantity: $0.quantity, unit: $0.unit.isEmpty ? nil : $0.unit, checked: $0.checked) })
            switch d.action {
            case .merge, .uncheck:
                var it = existing[d.targetIndex!]
                it.quantity = d.quantity
                it.unit = d.unit ?? ""
                it.checked = false
                it.checkedAt = nil
                save(grocery: it)
            case .new:
                let r = cat.categorize(p.name)
                var it = GroceryItem(id: RecordID.make(), list: list, name: p.name, category: r.category)
                it.family = family.id
                it.categorySource = r.source
                it.quantity = p.quantity
                it.unit = p.unit ?? ""
                it.addedBy = userId
                it.sortOrder = Date().timeIntervalSince1970
                save(grocery: it)
                if r.source == "none" { unknown.append(it) }
            }
        }
        if !unknown.isEmpty { Task { await smartCategorize(unknown) } }
        return unknown
    }

    func save(grocery it: GroceryItem) {
        var it = it
        it.family = family.id
        it.updated = Date()
        let isNew = !grocery.contains { $0.id == it.id }
        put(&grocery, it)
        enqueue("groceryItems", id: it.id, kind: isNew ? .create : .update, body: it.writable)
    }

    func toggle(grocery it: GroceryItem) {
        var it = it
        it.checked.toggle()
        it.checkedAt = it.checked ? Date() : nil
        save(grocery: it)
    }

    func delete(grocery it: GroceryItem) {
        var it = it
        it.deleted = true
        put(&grocery, it)
        enqueue("groceryItems", id: it.id, kind: .update, body: ["deleted": true])
    }

    func clearChecked(list: String) {
        for it in grocery where it.list == list && it.checked && !it.deleted { delete(grocery: it) }
    }

    /// Moves an item to another aisle and remembers the choice for the household.
    func setCategory(_ it: GroceryItem, to category: String, learn: Bool = true) {
        var it = it
        it.category = category
        it.categorySource = "manual"
        save(grocery: it)
        guard learn else { return }
        let term = GroceryCategorizer.learnKey(it.name)
        guard !term.isEmpty else { return }
        learned.removeAll { $0.term == term }
        let l = LearnedTerm(json: ["id": RecordID.make(), "family": family.id, "term": term, "category": category])
        learned.append(l)
        enqueue("groceryLearned", id: l.id, kind: .create, body: ["family": family.id, "term": term, "category": category])
    }

    /// Unknown items → Apple's on-device model (iOS 26+) or the server's LLM.
    func smartCategorize(_ items: [GroceryItem]) async {
        var guesses: [String: String] = [:]
        if let local = await SmartCategorizer.categorize(items.map(\.name)) { guesses = local }
        if guesses.isEmpty, let remote { guesses = (try? await remote.categorize(family: family.id, items: items.map(\.name))) ?? [:] }
        for it in items {
            guard let c = guesses[it.name], c != "other", var cur = grocery.first(where: { $0.id == it.id }), cur.categorySource == "none" else { continue }
            cur.category = c
            cur.categorySource = "ai"
            save(grocery: cur)
        }
    }

    /// Items bought before that aren't on the list now, most frequent first.
    func suggestions(list: String, limit: Int = 12) -> [String] {
        let onList = Set(grocery.filter { $0.list == list && !$0.deleted && !$0.checked }.map { GroceryMerge.mergeKey($0.name) })
        var counts: [String: (name: String, n: Int)] = [:]
        for it in grocery where it.list == list {
            let k = GroceryMerge.mergeKey(it.name)
            guard !onList.contains(k) else { continue }
            counts[k, default: (it.name, 0)].n += 1
        }
        return counts.values.sorted { $0.n == $1.n ? $0.name < $1.name : $0.n > $1.n }.prefix(limit).map(\.name)
    }

    func orderedCategories(for list: TaskList) -> [GroceryCategory] {
        let all = GroceryTaxonomy.bundled.categories
        guard !list.storeOrder.isEmpty else { return all }
        let pos = Dictionary(uniqueKeysWithValues: list.storeOrder.enumerated().map { ($1, $0) })
        return all.sorted { (pos[$0.key] ?? 1000 + $0.order) < (pos[$1.key] ?? 1000 + $1.order) }
    }

    // MARK: - Lists, calendars, cards, people

    func save(list l: TaskList) {
        var l = l
        l.family = family.id
        let isNew = !lists.contains { $0.id == l.id }
        if isLocal { l.viewers = [userId]; l.editors = [userId] }
        put(&lists, l)
        enqueue("lists", id: l.id, kind: isNew ? .create : .update, body: l.writable)
    }

    func save(calendar c: FamilyCalendar) {
        var c = c
        c.family = family.id
        let isNew = !calendars.contains { $0.id == c.id }
        if isLocal { c.viewers = [userId]; c.editors = [userId] }
        put(&calendars, c)
        enqueue("calendars", id: c.id, kind: isNew ? .create : .update, body: c.writable)
    }

    func save(card c: InfoCard) {
        var c = c
        c.family = family.id
        let isNew = !infoCards.contains { $0.id == c.id }
        if isLocal { c.viewers = [userId]; c.editors = [userId] }
        put(&infoCards, c)
        enqueue("infoCards", id: c.id, kind: isNew ? .create : .update, body: c.writable)
    }

    func save(member m: Member) {
        let isNew = !members.contains { $0.id == m.id }
        put(&members, m)
        var body: JSON = ["name": m.name, "color": m.color, "emoji": m.emoji, "birthday": PBDate.string(m.birthday),
                          "notifyAll": m.notifyAll, "sortOrder": m.sortOrder]
        if isNew { body["family"] = family.id; body["role"] = m.role.rawValue }
        else if isAdmin && m.user != userId { body["role"] = m.role.rawValue }
        enqueue("memberships", id: m.id, kind: isNew ? .create : .update, body: body)
    }

    func remove(member m: Member) {
        members.removeAll { $0.id == m.id }
        enqueue("memberships", id: m.id, kind: .delete, body: [:])
    }

    func createInvite(role: Role, name: String, membership: String?) async throws -> Invite {
        guard let remote else { throw PBError(status: 0, message: "Invites need a Roost server.", fieldErrors: [:]) }
        var body: JSON = ["family": family.id, "role": role.rawValue, "name": name]
        if let membership { body["membership"] = membership }
        let inv = Invite(json: try await remote.create("invites", body))
        put(&invites, inv)
        return inv
    }

    func ensureFeed() async throws -> Feed {
        if let f = feeds.first(where: { $0.user == userId }) { return f }
        guard let remote else { throw PBError(status: 0, message: "Calendar feeds need a Roost server.", fieldErrors: [:]) }
        let f = Feed(json: try await remote.create("feeds", ["family": family.id, "user": userId, "name": family.name, "includeBusy": true]))
        put(&feeds, f)
        return f
    }

    func refresh(subscription c: FamilyCalendar) async -> String? {
        guard let remote else { return "Needs a server." }
        do {
            let r = try await remote.refreshSubscription(calendar: c.id)
            await syncNow()
            return r.ok ? nil : r.error
        } catch { return (error as? PBError)?.message ?? error.localizedDescription }
    }
}
