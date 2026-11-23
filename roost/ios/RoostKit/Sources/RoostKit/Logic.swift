import Foundation

// MARK: - Day layout (shared/README.md §6)

public struct LayoutItem: Sendable {
    public var id: String
    public var start: Int // minutes from midnight
    public var end: Int
    public init(id: String, start: Int, end: Int) { self.id = id; self.start = start; self.end = end }
}

public struct LayoutSlot: Equatable, Sendable {
    public var col: Int
    public var cols: Int
    public init(col: Int, cols: Int) { self.col = col; self.cols = cols }
}

public enum DayLayout {
    public static func layout(_ items: [LayoutItem]) -> [String: LayoutSlot] {
        let norm = items.map { LayoutItem(id: $0.id, start: $0.start, end: $0.end > $0.start ? $0.end : $0.start + 15) }
        let sorted = norm.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.id < b.id
        }
        var result: [String: LayoutSlot] = [:]
        var cluster: [(LayoutItem, Int)] = []
        var colEnds: [Int] = []
        var clusterEnd = Int.min
        func flush() {
            for (it, c) in cluster { result[it.id] = LayoutSlot(col: c, cols: colEnds.count) }
            cluster = []; colEnds = []; clusterEnd = Int.min
        }
        for it in sorted {
            if !cluster.isEmpty && it.start >= clusterEnd { flush() }
            if let c = colEnds.firstIndex(where: { $0 <= it.start }) {
                colEnds[c] = it.end
                cluster.append((it, c))
            } else {
                colEnds.append(it.end)
                cluster.append((it, colEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, it.end)
        }
        flush()
        return result
    }
}

// MARK: - Access (§7)

public enum AccessLevel: String, Codable, Comparable, Sendable, CaseIterable {
    case none, busy, view, edit
    var rank: Int { [.none: 0, .busy: 1, .view: 2, .edit: 3][self]! }
    public static func < (a: AccessLevel, b: AccessLevel) -> Bool { a.rank < b.rank }
    public var label: String {
        switch self {
        case .none: return "No access"
        case .busy: return "Busy only"
        case .view: return "Can view"
        case .edit: return "Can edit"
        }
    }
}

public enum Role: String, Codable, CaseIterable, Sendable, Identifiable {
    case owner, parent, caregiver, relative, kid
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .owner: return "Owner"
        case .parent: return "Parent"
        case .caregiver: return "Caregiver"
        case .relative: return "Family"
        case .kid: return "Kid"
        }
    }
    public var blurb: String {
        switch self {
        case .owner: return "Full control, including roles and sharing."
        case .parent: return "Manages calendars, lists, invites and sharing."
        case .caregiver: return "Nanny or sitter: kids' schedule, groceries, assigned to-dos, care info."
        case .relative: return "Grandparents and family: view the family calendar and care info."
        case .kid: return "Sees the family calendar, adds to groceries, checks off their to-dos."
        }
    }
    public var isAdmin: Bool { self == .owner || self == .parent }
}

public struct Sharing: Codable, Hashable, Sendable {
    public var roles: [String: String]?
    public var people: [String: String]?
    public init(roles: [String: String]? = nil, people: [String: String]? = nil) { self.roles = roles; self.people = people }
}

public enum Access {
    static let defaults: [String: [Role: AccessLevel]] = [
        "calendar:family": [.owner: .edit, .parent: .edit, .caregiver: .edit, .relative: .view, .kid: .view],
        "calendar:personal": [.owner: .view, .parent: .view, .caregiver: .busy, .relative: .none, .kid: .none],
        "calendar:subscription": [.owner: .view, .parent: .view, .caregiver: .view, .relative: .view, .kid: .view],
        "list:todo": [.owner: .edit, .parent: .edit, .caregiver: .none, .relative: .none, .kid: .none],
        "list:grocery": [.owner: .edit, .parent: .edit, .caregiver: .edit, .relative: .none, .kid: .edit],
        "list:packing": [.owner: .edit, .parent: .edit, .caregiver: .edit, .relative: .none, .kid: .view],
        "info:card": [.owner: .edit, .parent: .edit, .caregiver: .view, .relative: .view, .kid: .none],
    ]

    public static func defaultLevel(resource: String, subkind: String, role: Role) -> AccessLevel {
        defaults[resource + ":" + subkind]?[role] ?? .none
    }

    public static func effectiveLevel(resource: String, subkind: String, role: Role, membershipId: String,
                                      sharing: Sharing?, isOwner: Bool) -> AccessLevel {
        if isOwner { return .edit }
        var level: AccessLevel
        if let raw = sharing?.people?[membershipId], let l = AccessLevel(rawValue: raw) {
            level = l
        } else if let raw = sharing?.roles?[role.rawValue], let l = AccessLevel(rawValue: raw) {
            level = l
        } else {
            level = defaultLevel(resource: resource, subkind: subkind, role: role)
        }
        if level == .busy && resource != "calendar" { level = .none }
        return level
    }
}

// MARK: - Task recurrence (§8)

public enum TaskRecurrence {
    /// Next due value ("YYYY-MM-DD" or "YYYY-MM-DDTHH:mm") after completing a recurring task.
    public static func nextDue(due: String, rrule: String, completedAt: LocalDateTime) -> String? {
        guard let start = LocalDateTime(iso: due), let rule = RRule(rrule) else { return nil }
        let allDay = due.count <= 10
        var found: LocalDateTime?
        RecurrenceExpander.iterate(start: start, rule: rule, fromPeriod: 0) { c in
            if c > start && c.date > completedAt.date { found = c; return false }
            return true
        }
        return found.map { $0.key(allDay: allDay) }
    }
}

extension RecurrenceExpander {
    /// Walks occurrences in order (DTSTART first, honoring COUNT/UNTIL in
    /// local time). `body` returns false to stop.
    public static func iterate(start: LocalDateTime, rule: RRule, fromPeriod: Int, tz: TimeZone = TimeZone(identifier: "UTC")!,
                               _ body: (LocalDateTime) -> Bool) {
        var emitted = 0
        func pastUntil(_ c: LocalDateTime) -> Bool {
            guard let u = rule.until else { return false }
            switch u {
            case .date(let d): return c.date > d
            case .local(let l): return c > l
            case .utc(let instant): return c.toDate(in: tz) > instant
            }
        }
        if fromPeriod == 0 && !rule.candidates(period: 0, start: start).contains(start.date) {
            emitted += 1
            if !body(start) { return }
        }
        var period = fromPeriod
        var iterations = 0
        while iterations < maxIterations {
            iterations += 1
            for d in rule.candidates(period: period, start: start) {
                let c = LocalDateTime(d, start.hour, start.minute)
                if c < start { continue }
                if pastUntil(c) { return }
                if let cnt = rule.count, emitted >= cnt { return }
                emitted += 1
                if !body(c) { return }
            }
            period += 1
        }
    }
}
