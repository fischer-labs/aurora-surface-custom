import Foundation
import XCTest
@testable import RoostKit

/// Talks to a real roost-server. Runs only when ROOST_TEST_SERVER is set to a
/// fresh server (e.g. http://127.0.0.1:8099), so CI without a server skips it.
final class ServerIntegrationTests: XCTestCase {
    func testRoundTripAgainstServer() async throws {
        guard let raw = ProcessInfo.processInfo.environment["ROOST_TEST_SERVER"], let url = URL(string: raw) else {
            throw XCTSkip("ROOST_TEST_SERVER not set")
        }
        let pb = PocketBaseClient(baseURL: url)
        let email = "swift-\(UUID().uuidString.prefix(8))@example.com"
        try await pb.signUp(email: email, password: "correct-horse-1", name: "Swift Parent", inviteCode: nil)
        let (_, user) = try await pb.authWithPassword(email: email, password: "correct-horse-1")
        XCTAssertEqual(user.name, "Swift Parent")

        let famJSON = try await pb.create("families", ["name": "Swift Family", "timezone": "America/Chicago"])
        let family = Family(json: famJSON)
        let calendars = try await pb.list("calendars", filter: "family = \(PocketBaseClient.quote(family.id))").map(FamilyCalendar.init(json:))
        XCTAssertEqual(Set(calendars.map(\.kind)), [.family, .personal])
        let famCal = calendars.first { $0.kind == .family }!
        XCTAssertTrue(famCal.editors.contains(user.id))

        // Quick add → event → server → expand.
        let tz = TimeZone(identifier: "America/Chicago")!
        let qa = QuickAddParser.parse("Soccer every tue 4-5:30pm remind 30m", now: LocalDateTime(iso: "2026-11-23T09:00")!, mode: .event)
        var ev = CalendarEvent(calendar: famCal.id, title: qa.title, start: qa.start!.toDate(in: tz), end: qa.end!.toDate(in: tz), tz: tz.identifier)
        ev.rrule = qa.rrule ?? ""
        ev.reminders = qa.reminders
        let saved = CalendarEvent(json: try await pb.create("events", ev.writable))
        XCTAssertEqual(saved.family, family.id)
        XCTAssertEqual(saved.rrule, "FREQ=WEEKLY;BYDAY=TU")
        XCTAssertEqual(saved.reminders, [30])
        XCTAssertEqual(saved.start, ev.start)

        let range = (LocalDateTime(iso: "2026-11-23T00:00")!.toDate(in: tz), LocalDateTime(iso: "2026-12-15T00:00")!.toDate(in: tz))
        let occ = Occurrence.expand([saved], from: range.0, to: range.1)
        XCTAssertEqual(occ.map(\.key), ["2026-11-24T16:00", "2026-12-01T16:00", "2026-12-08T16:00"])

        // Grocery with categorization and a learned term.
        let lists = try await pb.list("lists").map(TaskList.init(json:))
        let grocery = lists.first { $0.kind == .grocery }!
        let parsed = GroceryParser.parse("2 lbs chicken breast")!
        var item = GroceryItem(list: grocery.id, name: parsed.name, category: GroceryCategorizer().categorize(parsed.name).category)
        item.quantity = parsed.quantity
        item.unit = parsed.unit ?? ""
        let savedItem = GroceryItem(json: try await pb.create("groceryItems", item.writable))
        XCTAssertEqual(savedItem.category, "meat")
        XCTAssertEqual(savedItem.quantity, 2)
        XCTAssertEqual(savedItem.quantityLabel, "2 lb")

        // Invite flow preview.
        let inv = Invite(json: try await pb.create("invites", ["family": family.id, "role": "caregiver", "name": "Nanny"]))
        let preview = try await pb.invitePreview(code: inv.code)
        XCTAssertEqual(preview.family, "Swift Family")
        XCTAssertEqual(preview.role, .caregiver)

        // Errors decode into PBError.
        do {
            _ = try await pb.create("events", ["calendar": "nope", "title": "x"])
            XCTFail("expected an error")
        } catch let e as PBError {
            XCTAssertTrue([400, 403, 404].contains(e.status), "\(e)")
        }
    }
}
