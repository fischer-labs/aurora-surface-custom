import Foundation
import RoostKit

/// On-disk cache of one family's data plus the pending outbox.
struct Snapshot {
    var family: Family
    var members: [Member] = []
    var calendars: [FamilyCalendar] = []
    var events: [CalendarEvent] = []
    var busy: [CalendarEvent] = []
    var lists: [TaskList] = []
    var tasks: [TaskItem] = []
    var grocery: [GroceryItem] = []
    var learned: [LearnedTerm] = []
    var infoCards: [InfoCard] = []
    var invites: [Invite] = []
    var feeds: [Feed] = []
    var outbox: [OutboxOp] = []
    var lastSync: Date?

    init(family: Family) { self.family = family }

    static func url(familyId: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Roost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("family-\(familyId).json")
    }

    var json: JSON {
        [
            "version": 1,
            "family": family.json,
            "members": members.map(\.json),
            "calendars": calendars.map(\.json),
            "events": events.map(\.json),
            "busy": busy.map(\.json),
            "lists": lists.map(\.json),
            "tasks": tasks.map(\.json),
            "grocery": grocery.map(\.json),
            "learned": learned.map(\.json),
            "infoCards": infoCards.map(\.json),
            "invites": invites.map(\.json),
            "feeds": feeds.map(\.json),
            "outbox": outbox.map(\.json),
            "lastSync": PBDate.string(lastSync),
        ]
    }

    init(json j: JSON) {
        family = Family(json: j["family"] as? JSON ?? [:])
        func arr(_ k: String) -> [JSON] { j[k] as? [JSON] ?? [] }
        members = arr("members").map(Member.init(json:))
        calendars = arr("calendars").map(FamilyCalendar.init(json:))
        events = arr("events").map(CalendarEvent.init(json:))
        busy = arr("busy").map { (b: JSON) -> CalendarEvent in
            var e = CalendarEvent(json: b)
            e.isBusyBlock = true
            return e
        }
        lists = arr("lists").map(TaskList.init(json:))
        tasks = arr("tasks").map(TaskItem.init(json:))
        grocery = arr("grocery").map(GroceryItem.init(json:))
        learned = arr("learned").map(LearnedTerm.init(json:))
        infoCards = arr("infoCards").map(InfoCard.init(json:))
        invites = arr("invites").map(Invite.init(json:))
        feeds = arr("feeds").map(Feed.init(json:))
        outbox = arr("outbox").compactMap(OutboxOp.init(json:))
        lastSync = PBDate.parse(j.s("lastSync"))
    }

    static func load(familyId: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(familyId: familyId)),
              let j = try? JSONSerialization.jsonObject(with: data) as? JSON,
              !(j["family"] as? JSON ?? [:]).s("id").isEmpty else { return nil }
        return Snapshot(json: j)
    }

    func write() {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: Snapshot.url(familyId: family.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete(familyId: String) { try? FileManager.default.removeItem(at: url(familyId: familyId)) }
}

/// A pending write, replayed in order when the server is reachable.
struct OutboxOp: Identifiable {
    enum Kind: String { case create, update, delete }
    var id: String = RecordID.make()
    var collection: String
    var recordId: String
    var kind: Kind
    var body: JSON

    init(collection: String, recordId: String, kind: Kind, body: JSON) {
        self.collection = collection; self.recordId = recordId; self.kind = kind; self.body = body
    }

    init?(json j: JSON) {
        guard let k = Kind(rawValue: j.s("kind")) else { return nil }
        id = j.s("id"); collection = j.s("collection"); recordId = j.s("recordId"); kind = k; body = j["body"] as? JSON ?? [:]
    }

    var json: JSON { ["id": id, "collection": collection, "recordId": recordId, "kind": kind.rawValue, "body": body] }
}

enum RecordID {
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    /// PocketBase-compatible 15-char id, generated on device so offline creates keep their identity.
    static func make() -> String { String((0..<15).map { _ in alphabet.randomElement()! }) }
}
