import AppIntents
import Foundation
import RoostKit

// Siri, Shortcuts and Spotlight actions. They run in the app's process (in the
// background when possible) and go through the same store/outbox as the UI.

@MainActor
enum IntentBridge {
    /// Opens the family if the app was launched just for an intent.
    static func store() async throws -> FamilyStore {
        let app = AppModel.shared
        if app.store == nil && app.phase == .launching { await app.bootstrap() }
        guard let store = app.store else {
            throw IntentError.message("Open Roost and sign in to your family first.")
        }
        return store
    }

    /// Writes the change to disk right away (the app may be suspended any moment), then
    /// gives the outbox a moment to reach the server.
    static func finish(_ store: FamilyStore) async {
        store.snapshot.write()
        await store.flush()
        store.saveSoon()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)
    var localizedStringResource: LocalizedStringResource {
        switch self { case .message(let m): return LocalizedStringResource(stringLiteral: m) }
    }
}

struct AddGroceriesIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Groceries"
    static var description = IntentDescription("Adds one or more items to the family grocery list. They're sorted into aisles automatically.")
    static var openAppWhenRun = false

    @Parameter(title: "Items", requestValueDialog: "What should I add?")
    var items: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.store()
        guard let list = store.groceryLists.first(where: store.canEdit) else {
            throw IntentError.message("You don't have a grocery list you can edit.")
        }
        // "milk, eggs and bread" → separate lines, but "half and half" stays one item.
        let text = GroceryParser.splitSpokenList(items)
        let before = Set(store.grocery.map(\.id))
        store.addGroceries(text, list: list.id)
        let added = store.grocery.filter { !before.contains($0.id) }.map(\.name)
        await IntentBridge.finish(store)
        let names = added.isEmpty ? items : ListFormatter.localizedString(byJoining: added)
        return .result(dialog: "Added \(names) to \(list.name).")
    }
}

struct AddTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a To-Do"
    static var description = IntentDescription("Adds a to-do in plain English, like “Call the pediatrician tomorrow 9am”.")
    static var openAppWhenRun = false

    @Parameter(title: "To-do", requestValueDialog: "What's the to-do?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.store()
        let p = QuickAddParser.parse(text, now: LocalDateTime(Date(), in: .current), mode: .task)
        let lists = store.taskLists.filter(store.canEdit)
        guard let list = p.tag.flatMap({ tag in lists.first { $0.name.lowercased() == tag.lowercased() } }) ?? lists.first else {
            throw IntentError.message("You don't have a to-do list you can edit.")
        }
        var t = store.newTask(list: list.id, title: p.title.isEmpty ? text : p.title)
        if let s = p.start { t.due = p.timeMinutes != nil ? s.description : s.date.description }
        t.rrule = p.rrule ?? ""
        t.priority = p.priority
        t.reminders = p.timeMinutes != nil ? [0] : []
        store.save(task: t)
        await IntentBridge.finish(store)
        let when = Fmt.due(t).map { ", due \($0.lowercased())" } ?? ""
        return .result(dialog: "Added “\(t.title)”\(when).")
    }
}

struct AddEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Family Calendar"
    static var description = IntentDescription("Adds an event in plain English, like “Soccer Tuesday 4 to 5:30pm”.")
    static var openAppWhenRun = false

    @Parameter(title: "Event", requestValueDialog: "What's the event, and when?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.store()
        let p = QuickAddParser.parse(text, now: LocalDateTime(Date(), in: .current), mode: .event)
        guard !p.title.isEmpty, let day = p.date else { throw IntentError.message("I couldn't tell what or when that is.") }
        let tz = TimeZone.current
        let start = (p.start ?? LocalDateTime(day)).toDate(in: tz)
        var e = store.newEvent(start: start, allDay: p.allDay)
        guard !e.calendar.isEmpty else { throw IntentError.message("You don't have a calendar you can add to.") }
        e.title = p.title
        e.tz = tz.identifier
        e.rrule = p.rrule ?? ""
        if let end = p.end { e.end = end.toDate(in: tz) } else if p.allDay { e.end = LocalDateTime(day.adding(days: 1)).toDate(in: tz) }
        e.members = p.mentions.compactMap { n in store.members.first { $0.name.lowercased().hasPrefix(n.lowercased()) }?.id }
        if !p.reminders.isEmpty { e.reminders = p.reminders }
        store.save(event: e)
        await IntentBridge.finish(store)
        let when = p.allDay ? Fmt.dayTitle(start) : "\(Fmt.dayTitle(start)) at \(Fmt.time(start))"
        return .result(dialog: "Added \(e.title), \(when.lowercased()).")
    }
}

struct NextUpIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Next"
    static var description = IntentDescription("Tells you the family's next event and who's driving.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.store()
        if !store.isLocal { await store.syncNow() }
        let now = Date()
        let upcoming = store.occurrences(from: now, to: now.addingTimeInterval(7 * 86400)).filter { !$0.event.allDay && $0.end > now }
        guard let o = upcoming.first else { return .result(dialog: "Nothing on the family calendar in the next week.") }
        var line = o.start <= now ? "Right now: \(o.event.title), until \(Fmt.time(o.end))" : "\(o.event.title), \(Fmt.dayTitle(o.start).lowercased()) at \(Fmt.time(o.start))"
        let who = store.members(o.event.members).map(\.name)
        if !who.isEmpty { line += ", with \(ListFormatter.localizedString(byJoining: who))" }
        if let d = store.member(o.event.driver) { line += ". \(d.name) is driving" }
        return .result(dialog: "\(line).")
    }
}

struct GroceryListIntent: AppIntent {
    static var title: LocalizedStringResource = "Read the Grocery List"
    static var description = IntentDescription("Reads what's still on the grocery list, by aisle.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.store()
        guard let list = store.groceryLists.first else { throw IntentError.message("No grocery list is shared with you.") }
        let open = store.grocery.filter { $0.list == list.id && !$0.deleted && !$0.checked }
        guard !open.isEmpty else { return .result(dialog: "The grocery list is empty.") }
        var parts: [String] = []
        for c in store.orderedCategories(for: list) {
            let names = open.filter { $0.category == c.key }.map(\.name)
            if !names.isEmpty { parts.append("\(c.name): \(ListFormatter.localizedString(byJoining: names))") }
        }
        return .result(dialog: "\(open.count) items. \(parts.joined(separator: ". ")).")
    }
}

struct RoostShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddGroceriesIntent(), phrases: [
            "Add to groceries in \(.applicationName)",
            "Add to the \(.applicationName) grocery list",
            "\(.applicationName) groceries",
        ], shortTitle: "Add Groceries", systemImageName: "cart.badge.plus")
        AppShortcut(intent: AddTodoIntent(), phrases: [
            "Add a to-do in \(.applicationName)",
            "Remind the family in \(.applicationName)",
        ], shortTitle: "Add To-Do", systemImageName: "checklist")
        AppShortcut(intent: AddEventIntent(), phrases: [
            "Add to the family calendar in \(.applicationName)",
            "New \(.applicationName) event",
        ], shortTitle: "Add Event", systemImageName: "calendar.badge.plus")
        AppShortcut(intent: NextUpIntent(), phrases: [
            "What's next in \(.applicationName)",
            "What's on the \(.applicationName) calendar",
        ], shortTitle: "What's Next", systemImageName: "clock")
        AppShortcut(intent: GroceryListIntent(), phrases: [
            "Read my \(.applicationName) grocery list",
            "What's on the \(.applicationName) grocery list",
        ], shortTitle: "Grocery List", systemImageName: "cart")
    }
}
