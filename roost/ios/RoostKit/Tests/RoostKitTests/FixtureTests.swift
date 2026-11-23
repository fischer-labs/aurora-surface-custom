import Foundation
import XCTest
@testable import RoostKit

/// Runs the cross-platform acceptance fixtures in roost/shared/fixtures.
final class FixtureTests: XCTestCase {
    static let sharedDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared")

    func fixture(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.sharedDir.appendingPathComponent("fixtures/\(name).json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testBundledTaxonomyMatchesShared() throws {
        let shared = try Data(contentsOf: Self.sharedDir.appendingPathComponent("grocery/taxonomy.json"))
        let bundled = try Data(contentsOf: Bundle.module.url(forResource: "taxonomy", withExtension: "json")!)
        XCTAssertEqual(shared, bundled, "Run: cp shared/grocery/taxonomy.json ios/RoostKit/Sources/RoostKit/Resources/")
        XCTAssertGreaterThan(GroceryTaxonomy.bundled.termCount, 2000)
        XCTAssertEqual(GroceryTaxonomy.bundled.categories.count, 20)
    }

    func testGroceryParse() throws {
        let fx = try fixture("grocery")
        let cat = GroceryCategorizer()
        for c in fx["parse"] as! [[String: Any]] {
            let input = c["input"] as! String
            let p = try XCTUnwrap(GroceryParser.parse(input), input)
            XCTAssertEqual(p.name, c["name"] as? String, "name: \(input)")
            XCTAssertEqual(p.quantity, (c["quantity"] as? NSNumber)?.doubleValue, "qty: \(input)")
            XCTAssertEqual(p.unit, c["unit"] as? String, "unit: \(input)")
            XCTAssertEqual(cat.categorize(p.name).category, c["category"] as? String, "category: \(input)")
        }
    }

    func testGroceryCategorize() throws {
        let fx = try fixture("grocery")
        let cat = GroceryCategorizer()
        for c in fx["categorize"] as! [[String: Any]] {
            let input = c["input"] as! String
            let r = cat.categorize(input)
            XCTAssertEqual(r.category, c["category"] as? String, input)
            XCTAssertEqual(r.source, c["source"] as? String, input)
        }
        for c in fx["learned"] as! [[String: Any]] {
            let learned = c["learned"] as! [String: String]
            let r = GroceryCategorizer(learned: learned).categorize(c["input"] as! String)
            XCTAssertEqual(r.category, c["category"] as? String)
            XCTAssertEqual(r.source, c["source"] as? String)
        }
    }

    func testGroceryMerge() throws {
        let fx = try fixture("grocery")
        for c in fx["mergeKey"] as! [[String: Any]] {
            let same = GroceryMerge.mergeKey(c["a"] as! String) == GroceryMerge.mergeKey(c["b"] as! String)
            XCTAssertEqual(same, c["same"] as! Bool, "\(c["a"]!) vs \(c["b"]!)")
        }
        for c in fx["merge"] as! [[String: Any]] {
            let e = c["existing"] as! [String: Any]
            let existing = GroceryMerge.Existing(name: e["name"] as! String, quantity: (e["quantity"] as? NSNumber)?.doubleValue,
                                                 unit: e["unit"] as? String, checked: e["checked"] as! Bool)
            let p = GroceryParser.parse(c["add"] as! String)!
            let d = GroceryMerge.decide(adding: p, to: [existing])
            XCTAssertEqual(d.action.rawValue, c["action"] as? String, c["add"] as! String)
            XCTAssertEqual(d.quantity, (c["quantity"] as? NSNumber)?.doubleValue, c["add"] as! String)
            XCTAssertEqual(d.unit, c["unit"] as? String, c["add"] as! String)
        }
    }

    func testQuickAdd() throws {
        let fx = try fixture("quickadd")
        let now = LocalDateTime(iso: fx["now"] as! String)!
        for c in fx["cases"] as! [[String: Any]] {
            let text = c["text"] as! String
            let e = c["expect"] as! [String: Any]
            let r = QuickAddParser.parse(text, now: now, mode: QuickAddMode(rawValue: c["mode"] as! String)!)
            func hm(_ m: Int?) -> String? { m.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } }
            XCTAssertEqual(r.title, e["title"] as? String, "title: \(text)")
            XCTAssertEqual(r.date?.description, e["date"] as? String, "date: \(text)")
            XCTAssertEqual(hm(r.timeMinutes), e["time"] as? String, "time: \(text)")
            XCTAssertEqual(r.endDate?.description, e["endDate"] as? String, "endDate: \(text)")
            XCTAssertEqual(hm(r.endTimeMinutes), e["endTime"] as? String, "endTime: \(text)")
            XCTAssertEqual(r.allDay, e["allDay"] as? Bool, "allDay: \(text)")
            XCTAssertEqual(r.rrule, e["rrule"] as? String, "rrule: \(text)")
            XCTAssertEqual(r.mentions, e["mentions"] as? [String], "mentions: \(text)")
            XCTAssertEqual(r.driver, e["driver"] as? String, "driver: \(text)")
            XCTAssertEqual(r.tag, e["tag"] as? String, "tag: \(text)")
            XCTAssertEqual(r.priority, e["priority"] as? Int, "priority: \(text)")
            XCTAssertEqual(r.reminders, e["reminders"] as? [Int], "reminders: \(text)")
        }
    }

    func testRecurrence() throws {
        let fx = try fixture("recurrence")
        let iso = ISO8601DateFormatter()
        for c in fx["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let tz = TimeZone(identifier: c["tz"] as! String)!
            let allDay = c["allDay"] as! Bool
            let start = LocalDateTime(iso: c["start"] as! String)!
            let end = LocalDateTime(iso: c["end"] as! String)!
            let dur = allDay ? (end.date.dayNumber - start.date.dayNumber) * 1440
                : Int(end.toDate(in: tz).timeIntervalSince(start.toDate(in: tz)) / 60)
            let rs = LocalDateTime(iso: c["rangeStart"] as! String)!.toDate(in: tz)
            let re = LocalDateTime(iso: c["rangeEnd"] as! String)!.toDate(in: tz)
            let occ = RecurrenceExpander.expand(start: start, durationMinutes: dur, allDay: allDay, tz: tz,
                                                rrule: c["rrule"] as? String, exdates: Set(c["exdates"] as! [String]),
                                                rangeStart: rs, rangeEnd: re)
            XCTAssertEqual(occ.map { $0.key(allDay: allDay) }, c["expected"] as! [String], name)
            if let utc = c["expectedUtc"] as? [String] {
                XCTAssertEqual(occ.map { iso.string(from: $0.toDate(in: tz)) }, utc, "utc: \(name)")
            }
        }
    }

    func testRRuleRoundTrip() {
        for s in ["FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR", "FREQ=MONTHLY;BYDAY=-1FR", "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH",
                  "FREQ=DAILY;COUNT=5", "FREQ=WEEKLY;BYDAY=TH;UNTIL=20261217", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"] {
            XCTAssertEqual(RRule(s)?.string, s)
        }
        XCTAssertNil(RRule("BYDAY=MO"))
    }

    func testLayout() throws {
        let fx = try fixture("layout")
        for c in fx["cases"] as! [[String: Any]] {
            let items = (c["items"] as! [[String: Any]]).map { LayoutItem(id: $0["id"] as! String, start: $0["start"] as! Int, end: $0["end"] as! Int) }
            let got = DayLayout.layout(items)
            for (id, v) in c["expected"] as! [String: [Int]] {
                XCTAssertEqual(got[id], LayoutSlot(col: v[0], cols: v[1]), "\(c["name"]!): \(id)")
            }
        }
    }

    func testAccess() throws {
        let fx = try fixture("access")
        for c in fx["cases"] as! [[String: Any]] {
            let sharingObj = c["sharing"] as! [String: Any]
            let sharing = Sharing(roles: sharingObj["roles"] as? [String: String], people: sharingObj["people"] as? [String: String])
            let got = Access.effectiveLevel(resource: c["resource"] as! String, subkind: c["subkind"] as! String,
                                            role: Role(rawValue: c["role"] as! String)!, membershipId: c["membershipId"] as! String,
                                            sharing: sharing, isOwner: c["isOwner"] as! Bool)
            XCTAssertEqual(got.rawValue, c["expected"] as? String, "\(c)")
        }
    }

    func testTaskRecurrence() throws {
        let fx = try fixture("taskrecurrence")
        for c in fx["cases"] as! [[String: Any]] {
            let got = TaskRecurrence.nextDue(due: c["due"] as! String, rrule: c["rrule"] as! String,
                                             completedAt: LocalDateTime(iso: c["completedAt"] as! String)!)
            XCTAssertEqual(got, c["expected"] as? String, c["name"] as! String)
        }
    }

    func testLocalDateMath() {
        XCTAssertEqual(LocalDate(1970, 1, 1).dayNumber, 0)
        XCTAssertEqual(LocalDate(1970, 1, 1).weekday, 4) // Thursday
        XCTAssertEqual(LocalDate(2026, 11, 23).weekday, 1) // Monday
        XCTAssertEqual(LocalDate(dayNumber: LocalDate(2028, 2, 29).dayNumber), LocalDate(2028, 2, 29))
        XCTAssertEqual(LocalDate(1969, 12, 31).weekday, 3)
        XCTAssertEqual(LocalDateTime(minuteNumber: -1).description, "1969-12-31T23:59")
    }
}
