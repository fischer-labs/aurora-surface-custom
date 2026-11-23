import Foundation
import UserNotifications
import RoostKit

/// Schedules local notifications for the next 14 days of reminders that
/// concern this person. iOS keeps at most 64 pending requests, so we keep the
/// soonest 60.
@MainActor
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderScheduler()
    nonisolated static let prefix = "roost."
    /// Snoozes live under their own prefix so rescheduling never cancels them.
    nonisolated static let snoozePrefix = "roostsnooze."
    weak var store: FamilyStore?

    private let center = UNUserNotificationCenter.current()

    func configure() {
        center.delegate = self
        let complete = UNNotificationAction(identifier: "COMPLETE", title: "Mark done", options: [])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Remind me in 10 min", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "TASK", actions: [complete, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "EVENT", actions: [snooze], intentIdentifiers: []),
        ])
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func clearAll() {
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(ReminderScheduler.prefix) || $0.hasPrefix(ReminderScheduler.snoozePrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    struct Pending { var id: String; var fire: Date; var title: String; var body: String; var category: String; var taskId: String?; var due: String? }

    func reschedule(_ store: FamilyStore) {
        self.store = store
        let pending = compute(store, now: Date())
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                let old = reqs.map(\.identifier).filter { $0.hasPrefix(ReminderScheduler.prefix) }
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: old)
                for p in pending {
                    let c = UNMutableNotificationContent()
                    c.title = p.title
                    c.body = p.body
                    c.sound = .default
                    c.categoryIdentifier = p.category
                    if let t = p.taskId { c.userInfo = ["taskId": t, "due": p.due ?? ""] }
                    c.threadIdentifier = p.category
                    let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.fire)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    center.add(UNNotificationRequest(identifier: p.id, content: c, trigger: trigger))
                }
            }
        }
    }

    func compute(_ store: FamilyStore, now: Date) -> [Pending] {
        let horizon = now.addingTimeInterval(14 * 86400)
        let me = store.me
        let notifyAll = me?.notifyAll ?? false
        var out: [Pending] = []

        let liveCals = store.liveCalendarIds, liveLists = store.liveListIds
        let relevantEvents = store.events.filter { e in
            guard !e.deleted, !e.reminders.isEmpty, liveCals.contains(e.calendar) else { return false }
            if store.isLocal || notifyAll { return true }
            guard let me else { return false }
            if e.members.contains(me.id) || e.driver == me.id { return true }
            return e.members.isEmpty && e.createdBy == store.userId
        }
        let maxLead = TimeInterval((relevantEvents.flatMap(\.reminders).max() ?? 0) * 60)
        for o in Occurrence.expand(relevantEvents, from: now, to: horizon.addingTimeInterval(maxLead)) {
            for m in o.event.reminders {
                let fire = o.start.addingTimeInterval(TimeInterval(-m * 60))
                guard fire > now, fire < horizon else { continue }
                var body = Fmt.range(o)
                if !o.event.location.isEmpty { body += " · " + o.event.location }
                if let d = store.member(o.event.driver) { body += " · 🚗 " + d.name }
                out.append(Pending(id: "\(ReminderScheduler.prefix)e.\(o.event.id).\(o.key).\(m)", fire: fire,
                                   title: o.event.title, body: body, category: "EVENT", taskId: nil, due: nil))
            }
        }

        let familyTZ = TimeZone(identifier: store.family.timezone) ?? .current
        for t in store.tasks where !t.deleted && !t.completed && !t.reminders.isEmpty && liveLists.contains(t.list) {
            guard let due = t.dueLocal else { continue }
            let mine = store.isLocal || notifyAll || (me.map { t.assignees.contains($0.id) } ?? false) || (t.assignees.isEmpty && t.createdBy == store.userId)
            guard mine else { continue }
            // Due times are in the family's time zone; a due date reminds at 9 AM local.
            let anchor = t.due.count > 10 ? due.toDate(in: familyTZ) : due.adding(minutes: 9 * 60).toDate(in: .current)
            for m in t.reminders {
                let fire = anchor.addingTimeInterval(TimeInterval(-m * 60))
                guard fire > now, fire < horizon else { continue }
                out.append(Pending(id: "\(ReminderScheduler.prefix)t.\(t.id).\(m)", fire: fire, title: t.title,
                                   body: Fmt.due(t).map { "Due \($0)" } ?? "To-do", category: "TASK", taskId: t.id, due: t.due))
            }
        }
        return Array(out.sorted { $0.fire < $1.fire }.prefix(60))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        let taskId = content.userInfo["taskId"] as? String
        let dueAtNotice = content.userInfo["due"] as? String
        let title = content.title
        let body = content.body
        let category = content.categoryIdentifier
        if action == "COMPLETE", let id = taskId {
            // May be a cold or background launch: open the family first.
            await AppModel.shared.bootstrap()
            await MainActor.run {
                guard let store = AppModel.shared.store ?? ReminderScheduler.shared.store,
                      let t = store.tasks.first(where: { $0.id == id }) else { return }
                // Complete, never toggle: a stale notice must not un-complete or skip a repeat twice.
                guard !t.completed, dueAtNotice == nil || dueAtNotice == "" || t.due == dueAtNotice else { return }
                store.toggle(task: t)
                store.snapshot.write()
            }
            if let store = await AppModel.shared.store { await store.flush() }
            return
        }
        await MainActor.run {
            if action == "SNOOZE" {
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = body
                c.sound = .default
                c.categoryIdentifier = category
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ReminderScheduler.snoozePrefix + UUID().uuidString, content: c, trigger: trigger))
            }
        }
    }
}
