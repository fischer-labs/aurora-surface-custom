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
    /// The session expired; unsent changes are kept until the same person signs in again.
    var needsSignIn = false
    struct Rejected: Identifiable { let id = UUID(); var what: String; var message: String }
    /// Changes the server refused, newest first.
    var rejected: [Rejected] = []

    /// Called when the server says we're no longer in this family.
    @ObservationIgnored var onRemovedFromFamily: (() -> Void)?
    /// Called when the session can't be renewed.
    @ObservationIgnored var onSessionExpired: (() -> Void)?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var inFlight: String?
    @ObservationIgnored private var realtime: RealtimeClient?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var backoff: Double = 2
    /// Records changed here (or echoed back) and when, so a sync in flight can't overwrite newer local data.
    @ObservationIgnored private var touched: [String: Date] = [:]
    @ObservationIgnored private var syncStartedAt = Date.distantPast

    init(snapshot s: Snapshot, userId: String, remote: PocketBaseClient?) {
        self.userId = userId
        self.remote = remote
        family = s.family; members = s.members; calendars = s.calendars; events = s.events; busy = s.busy
        lists = s.lists; tasks = s.tasks; grocery = s.grocery; learned = s.learned; infoCards = s.infoCards
        invites = s.invites; feeds = s.feeds; lastSync = s.lastSync
        outbox = Snapshot.loadOutbox(familyId: s.family.id, user: userId) ?? s.outbox
    }

    private func persistOutbox() {
        guard !isLocal else { return }
        Snapshot.writeOutbox(familyId: family.id, user: userId, ops: outbox)
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
        return calendar(e.calendar)?.color ?? "brown"
    }

    /// Calendars and lists that still exist (items in removed ones are hidden and not reminded).
    var liveCalendarIds: Set<String> { Set(calendars.filter { !$0.deleted }.map(\.id)) }
    var liveListIds: Set<String> { Set(lists.filter { !$0.deleted }.map(\.id)) }

    func occurrences(from: Date, to: Date, hiddenCalendars: Set<String> = [], people: Set<String> = [], includeBusy: Bool = true) -> [Occurrence] {
        let live = liveCalendarIds
        var src = events.filter { !$0.deleted && live.contains($0.calendar) && !hiddenCalendars.contains($0.calendar) }
        if includeBusy { src += busy.filter { !hiddenCalendars.contains($0.calendar) } }
        if !people.isEmpty {
            src = src.filter { e in e.members.contains(where: { people.contains($0) }) || (!e.driver.isEmpty && people.contains(e.driver)) }
        }
        return Occurrence.expand(src, from: from, to: to)
    }

    func tasksDue(on day: Date) -> [TaskItem] {
        let key = LocalDateTime(day, in: .current).date.description
        let live = liveListIds
        return tasks.filter { !$0.deleted && !$0.completed && live.contains($0.list) && $0.due.hasPrefix(key) }
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
        touched[id] = Date()
        // Fold into the latest queued op for this record — never into the one being sent right now.
        var target: Int?
        if kind == .update, let j = outbox.lastIndex(where: { $0.recordId == id && $0.collection == collection }),
           outbox[j].kind != .delete, outbox[j].id != inFlight {
            target = j
        }
        if let i = target {
            outbox[i].body.merge(body) { _, new in new }
        } else {
            outbox.append(OutboxOp(collection: collection, recordId: id, kind: kind, body: body))
        }
        persistOutbox()
        saveSoon()
        Task { await flush() }
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        func enc(_ v: Any?) -> Data? { try? JSONSerialization.data(withJSONObject: [v ?? NSNull()], options: [.sortedKeys]) }
        return enc(a) == enc(b)
    }

    /// Creates send everything; updates send only changed fields (never `family`), so a stale
    /// copy on this phone can't overwrite someone else's newer edits.
    private func commit(_ collection: String, id: String, old: JSON?, new: JSON) {
        guard let old else { enqueue(collection, id: id, kind: .create, body: new); return }
        var diff: JSON = [:]
        for (k, v) in new where k != "family" && !FamilyStore.same(old[k], v) { diff[k] = v }
        if !diff.isEmpty { enqueue(collection, id: id, kind: .update, body: diff) }
    }

    /// Re-applies changes still queued for a record on top of what the server returned.
    private func withPending(_ rec: JSON, collection: String) -> JSON {
        var out = rec
        for o in outbox where o.collection == collection && o.recordId == rec.s("id") && o.kind != .delete {
            out.merge(o.body) { _, new in new }
        }
        return out
    }

    private func describe(_ op: OutboxOp) -> String {
        let noun = ["events": "event", "tasks": "to-do", "groceryItems": "grocery item", "lists": "list", "calendars": "calendar",
                    "infoCards": "card", "memberships": "person"][op.collection] ?? "change"
        let name = op.body.s("title").isEmpty ? op.body.s("name") : op.body.s("title")
        return name.isEmpty ? "a \(noun) change" : "\(noun) “\(name)”"
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = backoff
        backoff = min(backoff * 2, 60)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Tries to renew an expired token without bothering the user.
    private func renewSession() async -> Bool {
        guard let remote else { return false }
        do {
            _ = try await remote.authRefresh()
            Keychain.set("token", remote.token ?? "")
            return true
        } catch { return false }
    }

    func flush() async {
        guard let remote, !flushing, !needsSignIn else { return }
        flushing = true
        defer { flushing = false; inFlight = nil }
        while let op = outbox.first {
            inFlight = op.id
            do {
                var rec: JSON?
                switch op.kind {
                case .create:
                    var body = op.body
                    body["id"] = op.recordId
                    do {
                        rec = try await remote.create(op.collection, body)
                    } catch let e as PBError where e.fieldErrors["id"] != nil {
                        // Already created (a retry after a lost response): update instead.
                        rec = try await remote.update(op.collection, id: op.recordId, op.body)
                    }
                case .update:
                    rec = try await remote.update(op.collection, id: op.recordId, op.body)
                case .delete:
                    try await remote.delete(op.collection, id: op.recordId)
                }
                inFlight = nil
                outbox.removeAll { $0.id == op.id }
                persistOutbox()
                if let rec {
                    touched[op.recordId] = Date()
                    apply(withPending(rec, collection: op.collection), collection: op.collection)
                }
                if syncState == .offline { syncState = .idle }
                backoff = 2
            } catch let e as PBError where e.isAuth {
                inFlight = nil
                if await renewSession() { continue }
                needsSignIn = true
                syncState = .error("Please sign in again to send your changes.")
                saveSoon()
                onSessionExpired?()
                return
            } catch let e as PBError where e.isDefinitive {
                // The server refused (permissions/validation): drop it, say so, and restore its copy.
                inFlight = nil
                outbox.removeAll { $0.id == op.id }
                persistOutbox()
                rejected.insert(Rejected(what: describe(op), message: e.errorDescription ?? e.message), at: 0)
                if rejected.count > 20 { rejected.removeLast(rejected.count - 20) }
                syncState = .error("Couldn't save \(describe(op)).")
                if !outbox.contains(where: { $0.recordId == op.recordId }) {
                    touched[op.recordId] = nil
                    Task { await self.restore(op) }
                }
            } catch {
                // Offline, timeouts, 5xx while the home server restarts: keep it and retry.
                inFlight = nil
                syncState = .offline
                scheduleRetry()
                saveSoon()
                return
            }
        }
        saveSoon()
    }

    private func restore(_ op: OutboxOp) async {
        guard let remote else { return }
        do {
            if let j = try await remote.send("GET", "api/collections/\(op.collection)/records/\(op.recordId)") as? JSON, !j.s("id").isEmpty {
                apply(j, collection: op.collection)
            }
        } catch let e as PBError where e.status == 404 && op.kind == .create {
            remove(id: op.recordId, collection: op.collection)
        } catch {}
        saveSoon()
    }

    func dismissRejected() {
        rejected = []
        syncState = outbox.isEmpty ? .idle : .offline
    }

    // MARK: - Sync

    static let synced = ["calendars", "events", "lists", "tasks", "groceryItems", "groceryLearned", "infoCards"]

    /// One sync at a time; callers during a sync wait for it.
    func syncNow() async {
        if let t = syncTask { await t.value; return }
        let t = Task { await self.doSync() }
        syncTask = t
        await t.value
        syncTask = nil
    }

    private func doSync() async {
        guard let remote, !needsSignIn else { return }
        syncState = .syncing
        await flush()
        guard !needsSignIn else { return }
        let started = Date()
        syncStartedAt = started
        do {
            let fam: JSON
            do {
                fam = try await remote.send("GET", "api/collections/families/records/\(family.id)") as? JSON ?? [:]
            } catch let e as PBError where e.status == 404 || e.status == 403 {
                // We were removed from this family: forget what we cached.
                onRemovedFromFamily?()
                return
            }
            guard fam.s("id") == family.id else { throw PBError(status: 0, message: "Unexpected answer from the server.", fieldErrors: [:]) }
            family = Family(json: fam)
            let f = "family = \(PocketBaseClient.quote(family.id))"
            members = try await remote.list("memberships", filter: f, sort: "sortOrder,created").map(Member.init(json:))
            let pendingIds = Set(outbox.map(\.recordId))
            let keep: (String) -> Bool = { id in pendingIds.contains(id) || (self.touched[id] ?? .distantPast) >= started }
            calendars = merge(calendars, try await remote.list("calendars", filter: f + " && deleted = false").map(FamilyCalendar.init(json:)), keep)
            events = merge(events, try await remote.list("events", filter: f + " && deleted = false").map(CalendarEvent.init(json:)), keep)
            lists = merge(lists, try await remote.list("lists", filter: f + " && deleted = false").map(TaskList.init(json:)), keep)
            tasks = merge(tasks, try await remote.list("tasks", filter: f + " && deleted = false").map(TaskItem.init(json:)), keep)
            grocery = merge(grocery, try await remote.list("groceryItems", filter: f + " && deleted = false").map(GroceryItem.init(json:)), keep)
            learned = try await remote.list("groceryLearned", filter: f).map(LearnedTerm.init(json:))
            infoCards = merge(infoCards, try await remote.list("infoCards", filter: f + " && deleted = false").map(InfoCard.init(json:)), keep)
            if isAdmin { invites = (try? await remote.list("invites", filter: f + " && usedBy = ''", sort: "-created").map(Invite.init(json:))) ?? [] }
            feeds = (try? await remote.list("feeds", filter: f).map(Feed.init(json:))) ?? []
            let from = Calendar.current.date(byAdding: .day, value: -45, to: Date())!
            let to = Calendar.current.date(byAdding: .day, value: 400, to: Date())!
            busy = (try? await remote.busy(family: family.id, from: from, to: to)) ?? busy
            lastSync = Date()
            syncState = outbox.isEmpty ? (rejected.isEmpty ? .idle : syncState) : .offline
            saveSoon()
        } catch let e as PBError {
            if e.isAuth {
                if await renewSession() { syncTask = nil; await doSync(); return }
                needsSignIn = true
                onSessionExpired?()
            }
            syncState = e.isDefinitive || e.isAuth ? .error(e.message) : .offline
        } catch {
            syncState = .offline
        }
    }

    /// Server list wins, except records with unsent writes or changed since this sync started.
    private func merge<T: Identifiable>(_ local: [T], _ server: [T], _ keep: (String) -> Bool) -> [T] where T.ID == String {
        var out = server
        let serverIds = Set(server.map(\.id))
        for l in local where keep(l.id) {
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
            self.touched[record.s("id")] = Date()
            if action == "delete" { self.remove(id: record.s("id"), collection: coll) } else { self.apply(self.withPending(record, collection: coll), collection: coll) }
            if coll == "memberships" || coll == "calendars" || coll == "lists" {
                // Access may have changed; one coalesced full pull is cheap and authoritative.
                self.resyncTask?.cancel()
                self.resyncTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.syncNow()
                }
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
        let old = events.first { $0.id == e.id }
        e.updated = Date()
        put(&events, e)
        commit("events", id: e.id, old: old?.writable, new: e.writable)
    }

    func delete(event e: CalendarEvent) {
        guard var cur = events.first(where: { $0.id == e.id }) else { return }
        cur.deleted = true
        put(&events, cur)
        enqueue("events", id: e.id, kind: .update, body: ["deleted": true])
        // Occurrences edited on their own belong to the series and go with it.
        for var child in events where child.recurrenceParent == e.id && !child.deleted {
            child.deleted = true
            put(&events, child)
            enqueue("events", id: child.id, kind: .update, body: ["deleted": true])
        }
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

    private func shiftKey(_ key: String, by minutes: Int, allDay: Bool) -> String? {
        LocalDateTime(iso: key).map { $0.adding(minutes: minutes).key(allDay: allDay) }
    }

    /// "Save for all events": moves the series by the same wall-clock shift and keeps skipped dates skipped.
    func saveSeriesEdit(original o: Occurrence, edited: CalendarEvent) {
        guard let master = events.first(where: { $0.id == o.event.id }) else { save(event: edited); return }
        let tz = master.timeZone
        let delta = LocalDateTime(edited.start, in: tz).minuteNumber - LocalDateTime(o.start, in: tz).minuteNumber
        var out = edited
        out.id = master.id
        out.start = LocalDateTime(master.start, in: tz).adding(minutes: delta).toDate(in: tz)
        out.end = out.start.addingTimeInterval(edited.end.timeIntervalSince(edited.start))
        out.exdates = master.exdates.compactMap { shiftKey($0, by: delta, allDay: edited.allDay) }
        save(event: out)
    }

    /// "Save for future events": ends the old series and starts a new one that keeps the later
    /// skipped dates and the remaining COUNT.
    func saveFollowingEdit(original o: Occurrence, edited: CalendarEvent) {
        guard let master = events.first(where: { $0.id == o.event.id }) else { return }
        let tz = master.timeZone
        let delta = LocalDateTime(edited.start, in: tz).minuteNumber - LocalDateTime(o.start, in: tz).minuteNumber
        var copy = edited
        copy.id = RecordID.make()
        copy.recurrenceParent = ""
        copy.exdates = master.exdates.filter { $0 >= o.key }.compactMap { shiftKey($0, by: delta, allDay: edited.allDay) }
        if let oldCount = RRule(master.rrule)?.count, var newRule = RRule(edited.rrule) {
            let before = RecurrenceExpander.expand(start: LocalDateTime(master.start, in: tz), durationMinutes: master.durationMinutes,
                                                   allDay: master.allDay, tz: tz, rrule: master.rrule, exdates: [],
                                                   rangeStart: master.start, rangeEnd: o.start)
                .filter { $0.key(allDay: master.allDay) < o.key }.count
            newRule.count = max(1, oldCount - before)
            copy.rrule = newRule.string
        }
        endSeries(before: o)
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
        let old = tasks.first { $0.id == t.id }
        put(&tasks, t)
        commit("tasks", id: t.id, old: old?.writable, new: t.writable)
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
        let old = grocery.first { $0.id == it.id }
        put(&grocery, it)
        commit("groceryItems", id: it.id, old: old?.writable, new: it.writable)
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
        let old = lists.first { $0.id == l.id }
        if isLocal { l.viewers = [userId]; l.editors = [userId] }
        put(&lists, l)
        commit("lists", id: l.id, old: old?.writable, new: l.writable)
    }

    func save(calendar c: FamilyCalendar) {
        var c = c
        c.family = family.id
        let old = calendars.first { $0.id == c.id }
        if isLocal { c.viewers = [userId]; c.editors = [userId] }
        put(&calendars, c)
        commit("calendars", id: c.id, old: old?.writable, new: c.writable)
    }

    func save(card c: InfoCard) {
        var c = c
        c.family = family.id
        let old = infoCards.first { $0.id == c.id }
        if isLocal { c.viewers = [userId]; c.editors = [userId] }
        put(&infoCards, c)
        commit("infoCards", id: c.id, old: old?.writable, new: c.writable)
    }

    func save(member m: Member) {
        let old = members.first { $0.id == m.id }
        let canSetRole = old == nil || (isAdmin && m.user != userId)
        func body(_ x: Member) -> JSON {
            var b: JSON = ["name": x.name, "color": x.color, "emoji": x.emoji, "birthday": PBDate.string(x.birthday),
                           "notifyAll": x.notifyAll, "sortOrder": x.sortOrder]
            if canSetRole { b["role"] = x.role.rawValue }
            return b
        }
        put(&members, m)
        var new = body(m)
        if old == nil { new["family"] = family.id }
        commit("memberships", id: m.id, old: old.map(body), new: new)
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
