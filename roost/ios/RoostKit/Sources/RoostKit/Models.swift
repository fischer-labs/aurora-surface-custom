import Foundation

/// PocketBase JSON object.
public typealias JSON = [String: Any]

public extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String { self[k] as? String ?? "" }
    func ss(_ k: String) -> [String] { (self[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
    func b(_ k: String) -> Bool { (self[k] as? Bool) ?? ((self[k] as? NSNumber)?.boolValue ?? false) }
    func d(_ k: String) -> Double { (self[k] as? NSNumber)?.doubleValue ?? Double(s(k)) ?? 0 }
    func i(_ k: String) -> Int { Int(d(k)) }
    func ints(_ k: String) -> [Int] { (self[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [] }
    func date(_ k: String) -> Date? { PBDate.parse(s(k)) }
    func sharing(_ k: String) -> Sharing? {
        guard let o = self[k] as? JSON else { return nil }
        return Sharing(roles: o["roles"] as? [String: String], people: o["people"] as? [String: String])
    }
}

/// PocketBase date strings: "2026-11-24 22:00:00.000Z" (also accepts RFC 3339).
public enum PBDate {
    static let formats = ["yyyy-MM-dd HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"]
    static let parsers: [DateFormatter] = formats.map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = $0
        return f
    }
    static let writer: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let t = s.hasSuffix("Z") ? String(s.dropLast()) + "+0000" : s
        for p in parsers { if let d = p.date(from: t) { return d } }
        return nil
    }

    public static func string(_ d: Date?) -> String { d.map { writer.string(from: $0) } ?? "" }
}

func sharingJSON(_ s: Sharing?) -> Any {
    guard let s else { return NSNull() }
    var o: JSON = [:]
    if let r = s.roles { o["roles"] = r }
    if let p = s.people { o["people"] = p }
    return o
}

// MARK: - Records

public struct Family: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var timezone: String
    public var weekStart: Int
    public var owner: String
    public var members: [String]
    public var admins: [String]

    public init(json j: JSON) {
        id = j.s("id"); name = j.s("name"); timezone = j.s("timezone"); weekStart = j.i("weekStart")
        owner = j.s("owner"); members = j.ss("members"); admins = j.ss("admins")
    }
    public var json: JSON { ["id": id, "name": name, "timezone": timezone, "weekStart": weekStart, "owner": owner, "members": members, "admins": admins] }
    public var tz: TimeZone { .roost(timezone) }
}

public struct Member: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: String
    public var user: String
    public var name: String
    public var role: Role
    public var color: String
    public var emoji: String
    public var birthday: Date?
    public var notifyAll: Bool
    public var sortOrder: Double

    public init(id: String = "", family: String, user: String = "", name: String, role: Role, color: String = "blue", emoji: String = "") {
        self.id = id; self.family = family; self.user = user; self.name = name; self.role = role
        self.color = color; self.emoji = emoji; self.birthday = nil; self.notifyAll = false; self.sortOrder = 0
    }
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); user = j.s("user"); name = j.s("name")
        role = Role(rawValue: j.s("role")) ?? .kid; color = j.s("color"); emoji = j.s("emoji")
        birthday = j.date("birthday"); notifyAll = j.b("notifyAll"); sortOrder = j.d("sortOrder")
    }
    public var json: JSON {
        ["id": id, "family": family, "user": user, "name": name, "role": role.rawValue, "color": color, "emoji": emoji,
         "birthday": PBDate.string(birthday), "notifyAll": notifyAll, "sortOrder": sortOrder]
    }
    public var initials: String {
        let parts = name.split(separator: " ")
        return String((parts.first?.prefix(1) ?? "") + (parts.count > 1 ? parts.last!.prefix(1) : ""))
    }
    public var hasLogin: Bool { !user.isEmpty }
}

public struct FamilyCalendar: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case family, personal, subscription }
    public var id: String
    public var family: String
    public var name: String
    public var color: String
    public var kind: Kind
    public var owner: String
    public var sharing: Sharing?
    public var defaultReminders: [Int]
    public var sourceUrl: String
    public var lastSyncedAt: Date?
    public var syncError: String
    public var viewers: [String]
    public var editors: [String]
    public var busyViewers: [String]
    public var sortOrder: Double
    public var deleted: Bool
    public var updated: Date?

    public init(id: String = "", family: String, name: String, color: String, kind: Kind) {
        self.id = id; self.family = family; self.name = name; self.color = color; self.kind = kind
        owner = ""; sharing = nil; defaultReminders = [30]; sourceUrl = ""; lastSyncedAt = nil; syncError = ""
        viewers = []; editors = []; busyViewers = []; sortOrder = 0; deleted = false; updated = nil
    }
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); name = j.s("name"); color = j.s("color")
        kind = Kind(rawValue: j.s("kind")) ?? .family; owner = j.s("owner"); sharing = j.sharing("sharing")
        defaultReminders = j.ints("defaultReminders"); sourceUrl = j.s("sourceUrl"); lastSyncedAt = j.date("lastSyncedAt")
        syncError = j.s("syncError"); viewers = j.ss("viewers"); editors = j.ss("editors"); busyViewers = j.ss("busyViewers")
        sortOrder = j.d("sortOrder"); deleted = j.b("deleted"); updated = j.date("updated")
    }
    public var json: JSON {
        ["id": id, "family": family, "name": name, "color": color, "kind": kind.rawValue, "owner": owner, "sharing": sharingJSON(sharing),
         "defaultReminders": defaultReminders, "sourceUrl": sourceUrl, "lastSyncedAt": PBDate.string(lastSyncedAt), "syncError": syncError,
         "viewers": viewers, "editors": editors, "busyViewers": busyViewers, "sortOrder": sortOrder, "deleted": deleted, "updated": PBDate.string(updated)]
    }
    /// Fields a client may write.
    public var writable: JSON {
        ["family": family, "name": name, "color": color, "kind": kind.rawValue, "owner": owner, "sharing": sharingJSON(sharing),
         "defaultReminders": defaultReminders, "sourceUrl": sourceUrl, "sortOrder": sortOrder, "deleted": deleted]
    }
}

public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: String
    public var calendar: String
    public var title: String
    public var notes: String
    public var location: String
    public var url: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var tz: String
    public var rrule: String
    public var exdates: [String]
    public var recurrenceParent: String
    public var members: [String]
    public var driver: String
    public var category: String
    public var reminders: [Int]
    public var isPrivate: Bool
    public var color: String
    public var source: String
    public var createdBy: String
    public var deleted: Bool
    public var updated: Date?
    /// Server-provided busy block (sanitized).
    public var isBusyBlock: Bool = false

    public init(id: String = "", calendar: String, title: String, start: Date, end: Date, allDay: Bool = false, tz: String) {
        self.id = id; family = ""; self.calendar = calendar; self.title = title; notes = ""; location = ""; url = ""
        self.start = start; self.end = end; self.allDay = allDay; self.tz = tz; rrule = ""; exdates = []; recurrenceParent = ""
        members = []; driver = ""; category = ""; reminders = []; isPrivate = false; color = ""; source = "roost"
        createdBy = ""; deleted = false; updated = nil
    }
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); calendar = j.s("calendar"); title = j.s("title"); notes = j.s("notes")
        location = j.s("location"); url = j.s("url"); start = j.date("start") ?? Date(); end = j.date("end") ?? start
        allDay = j.b("allDay"); tz = j.s("tz"); rrule = j.s("rrule"); exdates = j.ss("exdates")
        recurrenceParent = j.s("recurrenceParent"); members = j.ss("members"); driver = j.s("driver"); category = j.s("category")
        reminders = j.ints("reminders"); isPrivate = j.b("private"); color = j.s("color"); source = j.s("source")
        createdBy = j.s("createdBy"); deleted = j.b("deleted"); updated = j.date("updated")
        isBusyBlock = j.s("title") == "Busy" && j["busy"] as? Bool == true
    }
    public var json: JSON {
        var j = writable
        j["id"] = id; j["family"] = family; j["source"] = source; j["createdBy"] = createdBy
        j["updated"] = PBDate.string(updated); j["busy"] = isBusyBlock
        return j
    }
    public var writable: JSON {
        ["calendar": calendar, "title": title, "notes": notes, "location": location, "url": url,
         "start": PBDate.string(start), "end": PBDate.string(end), "allDay": allDay, "tz": tz, "rrule": rrule,
         "exdates": exdates, "recurrenceParent": recurrenceParent, "members": members, "driver": driver,
         "category": category, "reminders": reminders, "private": isPrivate, "color": color, "deleted": deleted]
    }
    public var isReadOnlyImport: Bool { source == "ics" }
    public var timeZone: TimeZone { .roost(tz) }
    public var durationMinutes: Int {
        if allDay {
            let s = LocalDateTime(start, in: timeZone), e = LocalDateTime(end, in: timeZone)
            return max(1, e.date.dayNumber - s.date.dayNumber) * 1440
        }
        return max(0, Int(end.timeIntervalSince(start) / 60))
    }
}

public struct TaskList: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case todo, grocery, packing }
    public var id: String
    public var family: String
    public var name: String
    public var kind: Kind
    public var icon: String
    public var color: String
    public var owner: String
    public var sharing: Sharing?
    public var storeOrder: [String]
    public var viewers: [String]
    public var editors: [String]
    public var sortOrder: Double
    public var archived: Bool
    public var deleted: Bool

    public init(id: String = "", family: String, name: String, kind: Kind, icon: String = "checklist", color: String = "blue") {
        self.id = id; self.family = family; self.name = name; self.kind = kind; self.icon = icon; self.color = color
        owner = ""; sharing = nil; storeOrder = []; viewers = []; editors = []; sortOrder = 0; archived = false; deleted = false
    }
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); name = j.s("name"); kind = Kind(rawValue: j.s("kind")) ?? .todo
        icon = j.s("icon"); color = j.s("color"); owner = j.s("owner"); sharing = j.sharing("sharing")
        storeOrder = j.ss("storeOrder"); viewers = j.ss("viewers"); editors = j.ss("editors"); sortOrder = j.d("sortOrder")
        archived = j.b("archived"); deleted = j.b("deleted")
    }
    public var json: JSON { var j = writable; j["id"] = id; j["viewers"] = viewers; j["editors"] = editors; return j }
    public var writable: JSON {
        ["family": family, "name": name, "kind": kind.rawValue, "icon": icon, "color": color, "owner": owner,
         "sharing": sharingJSON(sharing), "storeOrder": storeOrder, "sortOrder": sortOrder, "archived": archived, "deleted": deleted]
    }
}

public struct TaskItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: String
    public var list: String
    public var title: String
    public var notes: String
    public var due: String
    public var assignees: [String]
    public var priority: Int
    public var rrule: String
    public var completed: Bool
    public var completedAt: Date?
    public var completedBy: String
    public var parent: String
    public var reminders: [Int]
    public var tags: [String]
    public var sortOrder: Double
    public var createdBy: String
    public var deleted: Bool
    public var updated: Date?

    public init(id: String = "", list: String, title: String) {
        self.id = id; family = ""; self.list = list; self.title = title; notes = ""; due = ""; assignees = []; priority = 0
        rrule = ""; completed = false; completedAt = nil; completedBy = ""; parent = ""; reminders = []; tags = []
        sortOrder = 0; createdBy = ""; deleted = false; updated = nil
    }
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); list = j.s("list"); title = j.s("title"); notes = j.s("notes"); due = j.s("due")
        assignees = j.ss("assignees"); priority = j.i("priority"); rrule = j.s("rrule"); completed = j.b("completed")
        completedAt = j.date("completedAt"); completedBy = j.s("completedBy"); parent = j.s("parent"); reminders = j.ints("reminders")
        tags = j.ss("tags"); sortOrder = j.d("sortOrder"); createdBy = j.s("createdBy"); deleted = j.b("deleted"); updated = j.date("updated")
    }
    public var json: JSON { var j = writable; j["id"] = id; j["family"] = family; j["createdBy"] = createdBy; j["completedBy"] = completedBy; j["updated"] = PBDate.string(updated); return j }
    public var writable: JSON {
        ["list": list, "title": title, "notes": notes, "due": due, "assignees": assignees, "priority": priority, "rrule": rrule,
         "completed": completed, "completedAt": PBDate.string(completedAt), "parent": parent, "reminders": reminders,
         "tags": tags, "sortOrder": sortOrder, "deleted": deleted]
    }
    public var dueLocal: LocalDateTime? { LocalDateTime(iso: due) }
    public var dueHasTime: Bool { due.count > 10 }
}

public struct GroceryItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: String
    public var list: String
    public var name: String
    public var quantity: Double?
    public var unit: String
    public var note: String
    public var category: String
    public var categorySource: String
    public var checked: Bool
    public var checkedAt: Date?
    public var addedBy: String
    public var sortOrder: Double
    public var deleted: Bool
    public var updated: Date?

    public init(id: String = "", list: String, name: String, category: String) {
        self.id = id; family = ""; self.list = list; self.name = name; quantity = nil; unit = ""; note = ""
        self.category = category; categorySource = "dictionary"; checked = false; checkedAt = nil; addedBy = ""
        sortOrder = 0; deleted = false; updated = nil
    }
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); list = j.s("list"); name = j.s("name")
        let q = j.d("quantity"); quantity = q > 0 ? q : nil
        unit = j.s("unit"); note = j.s("note"); category = j.s("category"); categorySource = j.s("categorySource")
        checked = j.b("checked"); checkedAt = j.date("checkedAt"); addedBy = j.s("addedBy"); sortOrder = j.d("sortOrder")
        deleted = j.b("deleted"); updated = j.date("updated")
    }
    public var json: JSON { var j = writable; j["id"] = id; j["family"] = family; j["checkedAt"] = PBDate.string(checkedAt); j["addedBy"] = addedBy; j["updated"] = PBDate.string(updated); return j }
    public var writable: JSON {
        ["list": list, "name": name, "quantity": quantity ?? 0, "unit": unit, "note": note, "category": category,
         "categorySource": categorySource.isEmpty ? "none" : categorySource, "checked": checked, "sortOrder": sortOrder, "deleted": deleted]
    }
    public var quantityLabel: String? { GroceryParser.formatQuantity(quantity, unit: unit.isEmpty ? nil : unit) }
}

public struct LearnedTerm: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: String
    public var term: String
    public var category: String
    public init(json j: JSON) { id = j.s("id"); family = j.s("family"); term = j.s("term"); category = j.s("category") }
    public var json: JSON { ["id": id, "family": family, "term": term, "category": category] }
}

public struct InfoCard: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: String
    public var title: String
    public var body: String
    public var kind: String
    public var icon: String
    public var phone: String
    public var address: String
    public var aboutMember: String
    public var pinned: Bool
    public var owner: String
    public var sharing: Sharing?
    public var viewers: [String]
    public var editors: [String]
    public var sortOrder: Double
    public var deleted: Bool

    public init(id: String = "", family: String, title: String, kind: String = "note") {
        self.id = id; self.family = family; self.title = title; body = ""; self.kind = kind; icon = ""; phone = ""; address = ""
        aboutMember = ""; pinned = false; owner = ""; sharing = nil; viewers = []; editors = []; sortOrder = 0; deleted = false
    }
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); title = j.s("title"); body = j.s("body"); kind = j.s("kind"); icon = j.s("icon")
        phone = j.s("phone"); address = j.s("address"); aboutMember = j.s("aboutMember"); pinned = j.b("pinned"); owner = j.s("owner")
        sharing = j.sharing("sharing"); viewers = j.ss("viewers"); editors = j.ss("editors"); sortOrder = j.d("sortOrder"); deleted = j.b("deleted")
    }
    public var json: JSON { var j = writable; j["id"] = id; j["viewers"] = viewers; j["editors"] = editors; return j }
    public var writable: JSON {
        ["family": family, "title": title, "body": body, "kind": kind.isEmpty ? "note" : kind, "icon": icon, "phone": phone,
         "address": address, "aboutMember": aboutMember, "pinned": pinned, "sharing": sharingJSON(sharing), "sortOrder": sortOrder, "deleted": deleted]
    }
}

public struct Invite: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: String
    public var code: String
    public var role: Role
    public var name: String
    public var membership: String
    public var expiresAt: Date?
    public var usedBy: String
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); code = j.s("code"); role = Role(rawValue: j.s("role")) ?? .relative
        name = j.s("name"); membership = j.s("membership"); expiresAt = j.date("expiresAt"); usedBy = j.s("usedBy")
    }
    public var json: JSON { ["id": id, "family": family, "code": code, "role": role.rawValue, "name": name, "membership": membership, "expiresAt": PBDate.string(expiresAt), "usedBy": usedBy] }
}

public struct Feed: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: String
    public var user: String
    public var token: String
    public var name: String
    public var includeBusy: Bool
    public init(json j: JSON) {
        id = j.s("id"); family = j.s("family"); user = j.s("user"); token = j.s("token"); name = j.s("name"); includeBusy = j.b("includeBusy")
    }
    public var json: JSON { ["id": id, "family": family, "user": user, "token": token, "name": name, "includeBusy": includeBusy] }
}

public struct UserProfile: Hashable, Sendable {
    public var id: String
    public var email: String
    public var name: String
    public init(json j: JSON) { id = j.s("id"); email = j.s("email"); name = j.s("name") }
    public var json: JSON { ["id": id, "email": email, "name": name] }
}

/// A single occurrence of an event, ready for display.
public struct Occurrence: Identifiable, Hashable, Sendable {
    public var event: CalendarEvent
    public var start: Date
    public var end: Date
    public var key: String
    public var id: String { event.id + "|" + key }

    /// Expands events into occurrences overlapping [from, to).
    public static func expand(_ events: [CalendarEvent], from: Date, to: Date) -> [Occurrence] {
        var out: [Occurrence] = []
        for e in events where !e.deleted {
            let tz = e.timeZone
            let startLocal = LocalDateTime(e.start, in: tz)
            let dur = e.durationMinutes
            let starts = RecurrenceExpander.expand(start: startLocal, durationMinutes: dur, allDay: e.allDay, tz: tz,
                                                   rrule: e.rrule.isEmpty ? nil : e.rrule, exdates: Set(e.exdates),
                                                   rangeStart: from, rangeEnd: to)
            for s in starts {
                let sd = s.toDate(in: tz)
                let ed = e.allDay ? s.adding(minutes: dur).toDate(in: tz) : sd.addingTimeInterval(TimeInterval(dur * 60))
                out.append(Occurrence(event: e, start: sd, end: ed, key: s.key(allDay: e.allDay)))
            }
        }
        return out.sorted { $0.start == $1.start ? ($0.event.allDay && !$1.event.allDay) : $0.start < $1.start }
    }
}
