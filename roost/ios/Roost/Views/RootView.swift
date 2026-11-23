import SwiftUI
import RoostKit

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                VStack(spacing: 16) {
                    RoostLogo(size: 84)
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.roostBG)
            case .onboarding:
                OnboardingView()
            case .ready:
                if let store = app.store {
                    MainTabs().environment(store)
                } else {
                    OnboardingView()
                }
            }
        }
        .animation(.default, value: app.phase)
    }
}

enum MainTab: String { case today, calendar, lists, grocery, more }

struct MainTabs: View {
    @Environment(FamilyStore.self) private var store
    @AppStorage("tab") private var tab: MainTab = .today
    @State private var prefs = CalendarPrefs()

    var body: some View {
        TabView(selection: $tab) {
            TodayView(selectTab: { tab = $0 })
                .tabItem { Label("Today", systemImage: "sun.horizon.fill") }.tag(MainTab.today)
            CalendarScreen()
                .tabItem { Label("Calendar", systemImage: "calendar") }.tag(MainTab.calendar)
            ListsScreen()
                .tabItem { Label("To-Dos", systemImage: "checklist") }.tag(MainTab.lists)
            GroceryScreen()
                .tabItem { Label("Groceries", systemImage: "cart.fill") }.tag(MainTab.grocery)
            MoreScreen()
                .tabItem { Label("Family", systemImage: "person.2.fill") }.tag(MainTab.more)
        }
        .environment(prefs)
        .onAppear {
            ReminderScheduler.shared.store = store
            ReminderScheduler.shared.reschedule(store)
        }
    }
}

/// Calendar display preferences, persisted.
@MainActor
@Observable
final class CalendarPrefs {
    var hiddenCalendars: Set<String> { didSet { save() } }
    var people: Set<String> { didSet { save() } }
    var showDevice: Bool { didSet { save() } }
    var showBusy: Bool { didSet { save() } }
    var showTasks: Bool { didSet { save() } }
    var colorByPerson: Bool { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        hiddenCalendars = Set(d.stringArray(forKey: "cal.hidden") ?? [])
        people = Set(d.stringArray(forKey: "cal.people") ?? [])
        showDevice = d.object(forKey: "cal.device") as? Bool ?? true
        showBusy = d.object(forKey: "cal.busy") as? Bool ?? true
        showTasks = d.object(forKey: "cal.tasks") as? Bool ?? true
        colorByPerson = d.object(forKey: "cal.byPerson") as? Bool ?? true
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Array(hiddenCalendars), forKey: "cal.hidden")
        d.set(Array(people), forKey: "cal.people")
        d.set(showDevice, forKey: "cal.device")
        d.set(showBusy, forKey: "cal.busy")
        d.set(showTasks, forKey: "cal.tasks")
        d.set(colorByPerson, forKey: "cal.byPerson")
    }

    var isFiltered: Bool { !hiddenCalendars.isEmpty || !people.isEmpty }
}
