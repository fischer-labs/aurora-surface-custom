import SwiftUI
import BackgroundTasks
import RoostKit

@main
struct RoostApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(DeviceCalendars.shared)
                .tint(.ember)
                .task { await app.bootstrap() }
                .onOpenURL { app.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, app.store != nil {
                        Task { await app.becameActive() }
                        DeviceCalendars.shared.reload()
                    }
                    if phase == .background { BackgroundRefresh.schedule() }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { ReminderScheduler.shared.configure() }
        BackgroundRefresh.register()
        // Rounded navigation titles, like the Today greeting and the web headings.
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xF5EFE7) : UIColor(hex: 0x1E1A16) }
        let nav = UINavigationBar.appearance()
        if let d = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle).withSymbolicTraits(.traitBold)?.withDesign(.rounded) {
            nav.largeTitleTextAttributes = [.font: UIFont(descriptor: d, size: 0), .foregroundColor: ink]
        }
        if let d = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline).withDesign(.rounded) {
            nav.titleTextAttributes = [.font: UIFont(descriptor: d, size: 0), .foregroundColor: ink]
        }
        return true
    }
}

/// Periodic background sync so reminders stay current even if the app isn't opened.
enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "app.roost") + ".refresh" }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                if let store = ReminderScheduler.shared.store {
                    await store.syncNow()
                    ReminderScheduler.shared.reschedule(store)
                }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }
}
