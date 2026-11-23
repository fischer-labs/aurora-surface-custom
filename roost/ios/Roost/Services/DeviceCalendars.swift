import Foundation
import EventKit
import Observation
import RoostKit

/// The phone's own calendars (Outlook/Exchange, Gmail, iCloud…) via EventKit.
/// Shown as an overlay in every calendar view; family events can be copied in.
@MainActor
@Observable
final class DeviceCalendars {
    static let shared = DeviceCalendars()

    let eventStore = EKEventStore()
    var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    var calendars: [EKCalendar] = []
    var enabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabled), forKey: "deviceCalendars.enabled") }
    }
    /// Bumped when the device calendar database changes so views refresh.
    var revision = 0

    init() {
        enabled = Set(UserDefaults.standard.stringArray(forKey: "deviceCalendars.enabled") ?? [])
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        if hasAccess { reload() }
    }

    var hasAccess: Bool { status == .fullAccess }

    func requestAccess() async {
        do {
            _ = try await eventStore.requestFullAccessToEvents()
        } catch {}
        status = EKEventStore.authorizationStatus(for: .event)
        if hasAccess {
            reload()
            if enabled.isEmpty { enabled = Set(calendars.map(\.calendarIdentifier)) }
        }
    }

    func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { calendars = []; return }
        calendars = eventStore.calendars(for: .event).sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
        revision += 1
    }

    struct Group: Identifiable {
        var source: String
        var calendars: [EKCalendar]
        var id: String { source }
    }

    var grouped: [Group] {
        Dictionary(grouping: calendars, by: { $0.source.title }).map { Group(source: $0.key, calendars: $0.value) }.sorted { $0.source < $1.source }
    }

    var writableCalendars: [EKCalendar] { calendars.filter(\.allowsContentModifications) }

    func events(from: Date, to: Date) -> [EKEvent] {
        guard hasAccess else { return [] }
        let cals = calendars.filter { enabled.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [] }
        let pred = eventStore.predicateForEvents(withStart: from, end: to, calendars: cals)
        return eventStore.events(matching: pred)
    }

    /// Copies a Roost event (all occurrences) into a device calendar.
    func copy(_ e: CalendarEvent, to calendar: EKCalendar) throws {
        let ek = EKEvent(eventStore: eventStore)
        ek.calendar = calendar
        ek.title = e.title
        ek.startDate = e.start
        ek.endDate = e.end
        ek.isAllDay = e.allDay
        ek.timeZone = e.allDay ? nil : e.timeZone
        ek.location = e.location.isEmpty ? nil : e.location
        ek.notes = e.notes.isEmpty ? nil : e.notes
        ek.url = URL(string: e.url)
        ek.alarms = e.reminders.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
        if let rule = RRule(e.rrule), let ekRule = DeviceCalendars.ekRule(rule) { ek.recurrenceRules = [ekRule] }
        try eventStore.save(ek, span: .futureEvents, commit: true)
    }

    static func ekRule(_ r: RRule) -> EKRecurrenceRule? {
        let freq: EKRecurrenceFrequency
        switch r.freq {
        case .daily: freq = .daily
        case .weekly: freq = .weekly
        case .monthly: freq = .monthly
        case .yearly: freq = .yearly
        }
        let days: [EKRecurrenceDayOfWeek]? = r.byDay.isEmpty ? nil : r.byDay.compactMap { wd in
            guard let w = EKWeekday(rawValue: wd.weekday + 1) else { return nil }
            return wd.ordinal.map { EKRecurrenceDayOfWeek(w, weekNumber: $0) } ?? EKRecurrenceDayOfWeek(w)
        }
        var end: EKRecurrenceEnd?
        if let c = r.count { end = EKRecurrenceEnd(occurrenceCount: c) }
        if let u = r.until {
            switch u {
            case .date(let d): end = EKRecurrenceEnd(end: LocalDateTime(d, 23, 59).toDate(in: .current))
            case .local(let l): end = EKRecurrenceEnd(end: l.toDate(in: .current))
            case .utc(let date): end = EKRecurrenceEnd(end: date)
            }
        }
        return EKRecurrenceRule(recurrenceWith: freq, interval: r.interval, daysOfTheWeek: days,
                                daysOfTheMonth: r.byMonthDay.isEmpty ? nil : r.byMonthDay.map { NSNumber(value: $0) },
                                monthsOfTheYear: r.byMonth.isEmpty ? nil : r.byMonth.map { NSNumber(value: $0) },
                                weeksOfTheYear: nil, daysOfTheYear: nil,
                                setPositions: r.bySetPos.isEmpty ? nil : r.bySetPos.map { NSNumber(value: $0) }, end: end)
    }
}
