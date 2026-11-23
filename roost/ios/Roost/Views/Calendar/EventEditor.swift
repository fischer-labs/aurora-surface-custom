import SwiftUI
import RoostKit

/// Repeat presets offered in the editor.
enum RepeatPreset: String, CaseIterable, Identifiable {
    case none, daily, weekdays, weekly, biweekly, monthlyDate, monthlyWeekday, yearly, custom
    var id: String { rawValue }

    func label(for start: Date) -> String {
        let wd = start.formatted(.dateTime.weekday(.wide))
        switch self {
        case .none: return "Never"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday (Mon–Fri)"
        case .weekly: return "Every week on \(wd)"
        case .biweekly: return "Every 2 weeks on \(wd)"
        case .monthlyDate: return "Monthly on day \(Calendar.current.component(.day, from: start))"
        case .monthlyWeekday:
            let n = RepeatPreset.weekOrdinal(start)
            return "Monthly on the \(n == -1 ? "last" : ["", "1st", "2nd", "3rd", "4th"][n]) \(wd)"
        case .yearly: return "Every year on \(start.formatted(.dateTime.month(.wide).day()))"
        case .custom: return "Custom"
        }
    }

    static func weekOrdinal(_ d: Date) -> Int {
        let day = Calendar.current.component(.day, from: d)
        let range = Calendar.current.range(of: .day, in: .month, for: d)?.count ?? 30
        return day + 7 > range ? -1 : (day - 1) / 7 + 1
    }

    func rrule(for start: Date) -> String {
        let code = RRule.dayCodes[Calendar.current.component(.weekday, from: start) - 1]
        switch self {
        case .none, .custom: return ""
        case .daily: return "FREQ=DAILY"
        case .weekdays: return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly: return "FREQ=WEEKLY;BYDAY=\(code)"
        case .biweekly: return "FREQ=WEEKLY;INTERVAL=2;BYDAY=\(code)"
        case .monthlyDate: return "FREQ=MONTHLY"
        case .monthlyWeekday: return "FREQ=MONTHLY;BYDAY=\(RepeatPreset.weekOrdinal(start))\(code)"
        case .yearly: return "FREQ=YEARLY"
        }
    }

    static func detect(_ rrule: String, start: Date) -> RepeatPreset {
        guard !rrule.isEmpty else { return .none }
        let base = rrule.components(separatedBy: ";").filter { !$0.hasPrefix("UNTIL") && !$0.hasPrefix("COUNT") }.joined(separator: ";")
        return allCases.first { $0 != .none && $0 != .custom && $0.rrule(for: start) == base } ?? .custom
    }
}

struct ReminderOption: Identifiable, Hashable {
    var minutes: Int
    var id: Int { minutes }
    static let timed: [Int] = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080]
    static let allDay: [Int] = [-540, 900, 2340, 9540]
}

struct EventEditor: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var event: CalendarEvent
    var isNew: Bool
    /// Set when editing one occurrence of a recurring series.
    var occurrence: Occurrence? = nil
    var onSaved: (() -> Void)? = nil

    @State private var preset: RepeatPreset = .none
    @State private var repeatEnd: Date? = nil
    @State private var askScope = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $event.title).font(.title3.weight(.semibold))
                    TextField("Location", text: $event.location)
                }
                Section {
                    Toggle("All day", isOn: Binding(get: { event.allDay }, set: setAllDay))
                    DatePicker("Starts", selection: Binding(get: { event.start }, set: setStart),
                               displayedComponents: event.allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $event.end, in: event.start..., displayedComponents: event.allDay ? [.date] : [.date, .hourAndMinute])
                    Picker("Repeat", selection: $preset) {
                        ForEach(RepeatPreset.allCases.filter { $0 != .custom || preset == .custom }) { p in Text(p.label(for: event.start)).tag(p) }
                    }
                    if preset != .none {
                        Toggle("End repeat", isOn: Binding(get: { repeatEnd != nil }, set: { repeatEnd = $0 ? Calendar.current.date(byAdding: .month, value: 3, to: event.start) : nil }))
                        if let end = repeatEnd {
                            DatePicker("Last date", selection: Binding(get: { end }, set: { repeatEnd = $0 }), in: event.start..., displayedComponents: .date)
                        }
                    }
                }
                Section("Calendar") {
                    Picker("Calendar", selection: $event.calendar) {
                        ForEach(store.editableCalendars) { c in
                            Label { Text(c.name) } icon: { Dot(color: Palette.named(c.color).color) }.tag(c.id)
                        }
                    }
                    Toggle(isOn: $event.isPrivate) {
                        VStack(alignment: .leading) {
                            Text("Private")
                            Text("Others see “Busy” unless they can edit this calendar.").font(.caption).foregroundStyle(Color.roostInk3)
                        }
                    }
                }
                Section("Who's involved") {
                    MemberPicker(selection: $event.members)
                    Picker("Who's driving", selection: $event.driver) {
                        Text("Nobody").tag("")
                        ForEach(store.sortedMembers) { m in Text(m.name).tag(m.id) }
                    }
                }
                Section("Reminders") {
                    ReminderPicker(selection: $event.reminders, allDay: event.allDay)
                }
                Section("Details") {
                    TextField("Link (Zoom, tickets…)", text: $event.url).keyboardType(.URL).textInputAutocapitalization(.never)
                    TextField("Notes", text: $event.notes, axis: .vertical).lineLimit(3...10)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.roostBG)
            .navigationTitle(isNew ? "New event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { occurrence != nil ? (askScope = true) : save(scope: .all) }
                        .bold().disabled(event.title.trimmingCharacters(in: .whitespaces).isEmpty || event.calendar.isEmpty)
                }
            }
            .confirmationDialog("This is a repeating event.", isPresented: $askScope, titleVisibility: .visible) {
                Button("Save for this event only") { save(scope: .one) }
                Button("Save for future events") { save(scope: .following) }
                Button("Save for all events") { save(scope: .all) }
            }
            .onAppear {
                preset = RepeatPreset.detect(event.rrule, start: event.start)
                if let r = RRule(event.rrule), case .date(let d)? = r.until { repeatEnd = LocalDateTime(d).toDate(in: .current) }
                if event.calendar.isEmpty { event.calendar = store.editableCalendars.first?.id ?? "" }
            }
        }
    }

    enum Scope { case one, following, all }

    private func setAllDay(_ on: Bool) {
        let cal = Calendar.current
        event.allDay = on
        if on {
            event.start = cal.startOfDay(for: event.start)
            event.end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(event.end.addingTimeInterval(-1), event.start)))!
            event.reminders = event.reminders.isEmpty ? [] : [900]
        } else {
            let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: event.start)!
            event.start = start
            event.end = start.addingTimeInterval(3600)
            event.reminders = event.reminders.isEmpty ? [] : [30]
        }
    }

    private func setStart(_ d: Date) {
        let dur = event.end.timeIntervalSince(event.start)
        event.start = d
        event.end = d.addingTimeInterval(max(dur, event.allDay ? 86400 : 0))
    }

    private func composedRRule() -> String {
        var base = preset == .custom ? event.rrule : preset.rrule(for: event.start)
        guard !base.isEmpty, var r = RRule(base) else { return "" }
        // Keep "N times" unless an end date was chosen instead.
        r.count = repeatEnd == nil ? RRule(event.rrule)?.count : nil
        r.until = repeatEnd.map { .date(LocalDateTime($0, in: .current).date) }
        base = r.string
        return base
    }

    private func save(scope: Scope) {
        var e = event
        e.title = e.title.trimmingCharacters(in: .whitespaces)
        e.rrule = composedRRule()
        if e.allDay {
            let cal = Calendar.current
            e.start = cal.startOfDay(for: e.start)
            let endDay = cal.startOfDay(for: e.end)
            e.end = endDay > e.start ? endDay : cal.date(byAdding: .day, value: 1, to: e.start)!
            // Midnight was built in this device's zone, so the date must be read in it too.
            e.tz = TimeZone.current.identifier
        }
        if e.end < e.start { e.end = e.start.addingTimeInterval(3600) }
        if let o = occurrence {
            switch scope {
            case .one: store.saveOccurrenceEdit(original: o, edited: e)
            case .following: store.saveFollowingEdit(original: o, edited: e)
            case .all: store.saveSeriesEdit(original: o, edited: e)
            }
        } else {
            store.save(event: e)
        }
        if !e.reminders.isEmpty { Task { _ = await ReminderScheduler.shared.requestPermission() } }
        onSaved?()
        dismiss()
    }
}

/// Multi-select of family members as tappable avatars.
struct MemberPicker: View {
    @Environment(FamilyStore.self) private var store
    @Binding var selection: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(store.sortedMembers) { m in
                    let on = selection.contains(m.id)
                    Button {
                        if on { selection.removeAll { $0 == m.id } } else { selection.append(m.id) }
                    } label: {
                        VStack(spacing: 4) {
                            Avatar(member: m, size: 40)
                                .overlay(Circle().stroke(on ? Palette.named(m.color).color : .clear, lineWidth: 3).padding(-4))
                                .opacity(on ? 1 : 0.45)
                            Text(m.name.split(separator: " ").first.map(String.init) ?? m.name)
                                .font(.caption2.weight(on ? .bold : .regular)).foregroundStyle(Color.roostInk)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }
}

struct ReminderPicker: View {
    @Binding var selection: [Int]
    var allDay: Bool

    var body: some View {
        let options = allDay ? ReminderOption.allDay : ReminderOption.timed
        ForEach(options, id: \.self) { m in
            Button {
                if selection.contains(m) { selection.removeAll { $0 == m } } else { selection.append(m); selection.sort() }
            } label: {
                HStack {
                    Text(Fmt.reminder(m, allDay: allDay)).foregroundStyle(Color.roostInk)
                    Spacer()
                    if selection.contains(m) { Image(systemName: "checkmark").foregroundStyle(Color.ember).bold() }
                }
            }
        }
    }
}
