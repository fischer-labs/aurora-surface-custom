import Foundation
import RoostKit

/// Defaults for on-device-only mode, mirroring what the server seeds.
enum LocalSeed {
    static let familyId = "localfamily0001"
    static let userId = "localuser000001"

    static func snapshot(familyName: String, yourName: String) -> Snapshot {
        let tz = TimeZone.current.identifier
        let family = Family(json: ["id": familyId, "name": familyName, "timezone": tz, "owner": userId, "members": [userId], "admins": [userId]])
        var s = Snapshot(family: family)
        var me = Member(id: RecordID.make(), family: familyId, user: userId, name: yourName.isEmpty ? "Me" : yourName, role: .owner, color: "blue")
        me.sortOrder = 0
        s.members = [me]

        var famCal = FamilyCalendar(id: RecordID.make(), family: familyId, name: "Family", color: "orange", kind: .family)
        famCal.viewers = [userId]; famCal.editors = [userId]; famCal.defaultReminders = [30]
        var mine = FamilyCalendar(id: RecordID.make(), family: familyId, name: me.name, color: "blue", kind: .personal)
        mine.owner = me.id; mine.viewers = [userId]; mine.editors = [userId]; mine.sortOrder = 1; mine.defaultReminders = [15]
        s.calendars = [famCal, mine]

        var groceries = TaskList(id: RecordID.make(), family: familyId, name: "Groceries", kind: .grocery, icon: "cart", color: "green")
        groceries.viewers = [userId]; groceries.editors = [userId]
        var todo = TaskList(id: RecordID.make(), family: familyId, name: "To-Do", kind: .todo, icon: "checklist", color: "blue")
        todo.viewers = [userId]; todo.editors = [userId]; todo.sortOrder = 1
        s.lists = [groceries, todo]

        var c1 = InfoCard(id: RecordID.make(), family: familyId, title: "Emergency contacts", kind: "contact")
        c1.body = "Pediatrician: \nPoison Control: 1-800-222-1222\nNeighbor: \nGrandparents: "
        c1.pinned = true; c1.viewers = [userId]; c1.editors = [userId]
        var c2 = InfoCard(id: RecordID.make(), family: familyId, title: "Allergies & medications", kind: "medical")
        c2.body = "Allergies: none known\nMedications: \nInsurance: "
        c2.pinned = true; c2.viewers = [userId]; c2.editors = [userId]; c2.sortOrder = 1
        s.infoCards = [c1, c2]
        return s
    }
}
