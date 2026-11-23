import XCTest
@testable import RoostKit

/// All-day events are floating dates (code review #12).
final class FloatingDateTests: XCTestCase {
    func testAllDayEventStaysOnItsDateInAnotherTimeZone() {
        let chicago = TimeZone(identifier: "America/Chicago")!, la = TimeZone(identifier: "America/Los_Angeles")!
        let start = LocalDateTime(LocalDate(2026, 12, 4)).toDate(in: chicago)
        let e = CalendarEvent(id: "e1", calendar: "c", title: "Field trip", start: start,
                              end: Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: start)!, allDay: true, tz: chicago.identifier)
        let occ = Occurrence.expand([e], from: start.addingTimeInterval(-3 * 86400), to: start.addingTimeInterval(3 * 86400), viewer: la)
        XCTAssertEqual(occ.count, 1)
        XCTAssertEqual(occ[0].key, "2026-12-04")
        XCTAssertEqual(LocalDateTime(occ[0].start, in: la).description, "2026-12-04T00:00")
        XCTAssertEqual(LocalDateTime(occ[0].end, in: la).description, "2026-12-05T00:00")
    }

    func testDefinitiveErrors() {
        XCTAssertTrue(PBError(status: 403, message: "").isDefinitive)
        XCTAssertFalse(PBError(status: 502, message: "").isDefinitive)
        XCTAssertFalse(PBError(status: 0, message: "").isDefinitive)
        XCTAssertFalse(PBError(status: 401, message: "").isDefinitive)
    }
}

final class SpokenListTests: XCTestCase {
    func testSplitsSpokenListsButKeepsKnownAndItems() {
        XCTAssertEqual(GroceryParser.splitSpokenList("milk, eggs and bread"), "milk, eggs, bread")
        XCTAssertEqual(GroceryParser.splitSpokenList("half and half and eggs"), "half and half, eggs")
        XCTAssertEqual(GroceryParser.splitSpokenList("2 boxes mac and cheese and apples"), "2 boxes mac and cheese, apples")
        XCTAssertEqual(GroceryParser.splitSpokenList("ham and mustard"), "ham, mustard")
        XCTAssertEqual(GroceryParser.splitSpokenList("Peas And Carrots"), "Peas and Carrots")
    }
}
