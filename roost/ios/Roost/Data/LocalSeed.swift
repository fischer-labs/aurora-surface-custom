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
        var todo = TaskList(id: RecordID.make(), family: familyId, name: "Household", kind: .todo, icon: "checklist", color: "blue")
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

// MARK: - Demo family (screenshots, App Review, trying the app)

extension LocalSeed {
    static func demo(now: Date = Date()) -> Snapshot {
        var s = snapshot(familyName: "The Riveras", yourName: "Alex Rivera")
        let cal = Calendar.current
        let tz = TimeZone.current.identifier
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        func at(_ offset: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day(offset))! }
        func next(_ weekday: Int) -> Int { (weekday - cal.component(.weekday, from: today) + 7) % 7 } // 1 = Sunday

        let alex = s.members[0].id
        func person(_ name: String, _ role: Role, _ color: String, _ order: Double, login: Bool = false) -> String {
            var m = Member(id: RecordID.make(), family: familyId, user: login ? RecordID.make() : "", name: name, role: role, color: color)
            m.sortOrder = order
            s.members.append(m)
            return m.id
        }
        let sam = person("Sam", .parent, "violet", 1, login: true)
        let emma = person("Emma", .kid, "pink", 2)
        let leo = person("Leo", .kid, "green", 3)
        let maria = person("Maria", .caregiver, "teal", 4, login: true)
        _ = person("Grandma Jo", .relative, "amber", 5, login: true)

        let famCal = s.calendars[0].id, alexCal = s.calendars[1].id
        func event(_ title: String, _ start: Date, _ end: Date, cal: String? = nil, rrule: String = "", members: [String] = [],
                   driver: String = "", location: String = "", allDay: Bool = false) {
            var e = CalendarEvent(id: RecordID.make(), calendar: cal ?? famCal, title: title, start: start, end: end, allDay: allDay, tz: tz)
            e.family = familyId; e.rrule = rrule; e.members = members; e.driver = driver; e.location = location
            e.reminders = allDay ? [900] : [30]; e.createdBy = userId
            s.events.append(e)
        }
        let tue = next(3), wed = next(4), thu = next(5), fri = next(6), sat = next(7)
        event("Library story time", at(0, 10), at(0, 11), members: [leo], driver: maria, location: "Eastside Library")
        event("Dinner with the Parks", at(0, 18, 30), at(0, 20), members: [alex, sam])
        event("Soccer practice", at(tue, 16), at(tue, 17, 30), rrule: "FREQ=WEEKLY;BYDAY=TU,TH", members: [emma], driver: sam, location: "Riverside Park field 3")
        event("Piano lesson", at(wed, 15, 30), at(wed, 16, 15), rrule: "FREQ=WEEKLY", members: [leo], driver: maria, location: "Ms. Chen’s studio")
        event("Pediatrician — Leo checkup", at(fri, 10), at(fri, 10, 45), members: [leo], driver: alex, location: "Lakeside Pediatrics")
        event("Swim lessons", at(sat, 9), at(sat, 10), rrule: "FREQ=WEEKLY;BYDAY=SA", members: [emma, leo])
        event("Thanksgiving at Grandma’s", day(thu), day(thu + 1), members: [alex, sam, emma, leo], allDay: true)
        event("Date night", at(sat, 19), at(sat, 22), members: [alex, sam])
        event("School holiday concert", at(10, 18), at(10, 19, 30), members: [emma, leo], location: "Lincoln Elementary gym")
        event("Clinic", at(1, 8), at(1, 17), cal: alexCal, rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE", members: [alex])

        let todo = s.lists[1].id, groceries = s.lists[0].id
        func key(_ d: Date, time: Bool = false) -> String { LocalDateTime(d, in: .current).key(allDay: !time) }
        func task(_ title: String, due: String = "", assignees: [String] = [], priority: Int = 0, rrule: String = "") {
            var t = TaskItem(id: RecordID.make(), list: todo, title: title)
            t.family = familyId; t.due = due; t.assignees = assignees; t.priority = priority; t.rrule = rrule; t.createdBy = userId
            s.tasks.append(t)
        }
        task("Sign Emma’s field trip permission slip", due: key(day(0)), assignees: [alex], priority: 2)
        task("Pick up Leo’s prescription", due: key(at(1, 15), time: true), assignees: [maria])
        task("Order birthday gift for Leo’s friend", due: key(day(fri)), priority: 1)
        task("Take out recycling", due: key(day(1)), assignees: [sam], rrule: "FREQ=WEEKLY")
        task("Book flights for winter break", due: key(day(6)), assignees: [sam])
        task("Renew passports", priority: 3)

        let cat = GroceryCategorizer()
        for line in ["2 lbs chicken breast", "milk x2", "bananas", "baby spinach", "frozen peas", "Cheerios", "paper towels", "dog food",
                     "greek yogurt", "sourdough bread", "AA batteries", "3 avocados", "half and half", "gochujang", "kombucha"] {
            guard let p = GroceryParser.parse(line) else { continue }
            var g = GroceryItem(id: RecordID.make(), list: groceries, name: p.name, category: cat.categorize(p.name).category)
            g.family = familyId; g.quantity = p.quantity; g.unit = p.unit ?? ""; g.sortOrder = Double(s.grocery.count)
            g.checked = ["Bananas", "Cheerios"].contains(p.name)
            s.grocery.append(g)
        }

        var ped = InfoCard(id: RecordID.make(), family: familyId, title: "Pediatrician", kind: "contact")
        ped.phone = "(555) 201-4400"; ped.address = "1200 Lakeside Dr"; ped.pinned = true
        ped.body = "Dr. Okafor — Lakeside Pediatrics\nAfter hours: nurse line (555) 201-4499"
        ped.viewers = [userId]; ped.editors = [userId]
        var bed = InfoCard(id: RecordID.make(), family: familyId, title: "Bedtime routine", kind: "routine")
        bed.body = "7:00 bath · 7:30 two books · 7:45 lights out (Leo needs the hall light on)"
        bed.aboutMember = leo; bed.pinned = true; bed.viewers = [userId]; bed.editors = [userId]
        s.infoCards.insert(contentsOf: [ped, bed], at: 0)
        return s
    }
}
