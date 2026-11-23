import SwiftUI
import RoostKit

enum CalendarMode: String, CaseIterable, Identifiable {
    case day, threeDay, week, month, agenda, year, people
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "Day"
        case .threeDay: return "3 Days"
        case .week: return "Week"
        case .month: return "Month"
        case .agenda: return "Agenda"
        case .year: return "Year"
        case .people: return "People"
        }
    }
    var icon: String {
        switch self {
        case .day: return "1.square"
        case .threeDay: return "3.square"
        case .week: return "7.square"
        case .month: return "calendar"
        case .agenda: return "list.bullet.rectangle"
        case .year: return "square.grid.3x3"
        case .people: return "person.2.crop.square.stack"
        }
    }
}

struct CalendarScreen: View {
    @Environment(FamilyStore.self) private var store
    @Environment(CalendarPrefs.self) private var prefs
    @Environment(DeviceCalendars.self) private var device
    @AppStorage("cal.mode") private var mode: CalendarMode = .month
    @State private var anchor = Calendar.current.startOfDay(for: Date())
    @State private var showFilters = false
    @State private var newEvent: CalendarEvent?
    @State private var showQuickAdd = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
            }
            .background(Color.roostBG.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CalItem.self) { ItemDetailRouter(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("View", selection: $mode) {
                            ForEach(CalendarMode.allCases) { m in Label(m.label, systemImage: m.icon).tag(m) }
                        }
                    } label: {
                        Label(mode.label, systemImage: mode.icon).labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Today") { withAnimation { anchor = Calendar.current.startOfDay(for: Date()) } }
                    Button { showFilters = true } label: {
                        Image(systemName: prefs.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter")
                    Menu {
                        Button { showQuickAdd = true } label: { Label("Quick add", systemImage: "text.cursor") }
                        Button { newEvent = defaultNewEvent(at: nil) } label: { Label("New event", systemImage: "calendar.badge.plus") }
                    } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    .disabled(store.editableCalendars.isEmpty)
                }
            }
            .sheet(isPresented: $showFilters) { CalendarFilterSheet() }
            .sheet(item: $newEvent) { e in EventEditor(event: e, isNew: true) }
            .sheet(isPresented: $showQuickAdd) { QuickAddSheet(mode: .event) }
        }
    }

    private var title: String {
        switch mode {
        case .year: return anchor.formatted(.dateTime.year())
        case .day, .people: return anchor.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        default: return anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .month: MonthView(anchor: $anchor, onNew: { newEvent = defaultNewEvent(at: $0) })
        case .agenda: AgendaView(anchor: $anchor)
        case .year: YearView(anchor: $anchor, onPickMonth: { anchor = $0; mode = .month })
        case .day: TimeGridView(anchor: $anchor, days: 1, onNew: { newEvent = defaultNewEvent(at: $0) })
        case .threeDay: TimeGridView(anchor: $anchor, days: 3, onNew: { newEvent = defaultNewEvent(at: $0) })
        case .week: TimeGridView(anchor: $anchor, days: 7, onNew: { newEvent = defaultNewEvent(at: $0) })
        case .people: TimeGridView(anchor: $anchor, days: 1, byPeople: true, onNew: { newEvent = defaultNewEvent(at: $0) })
        }
    }

    private func defaultNewEvent(at date: Date?) -> CalendarEvent? {
        guard !store.editableCalendars.isEmpty else { return nil }
        let cal = Calendar.current
        var start: Date
        if let date {
            start = date
        } else {
            let base = cal.isDateInToday(anchor) ? Date() : cal.date(bySettingHour: 9, minute: 0, second: 0, of: anchor)!
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: base)
            start = cal.date(from: comps)!.addingTimeInterval(cal.isDateInToday(anchor) ? 3600 : 0)
        }
        return store.newEvent(start: start)
    }
}

// MARK: - Month

struct MonthView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(CalendarPrefs.self) private var prefs
    @Environment(DeviceCalendars.self) private var device
    @Binding var anchor: Date
    var onNew: (Date) -> Void

    private var cal: Calendar { Calendar.current }

    private var gridDays: [Date] {
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: anchor))!
        let wd = cal.component(.weekday, from: monthStart)
        let lead = (wd - cal.firstWeekday + 7) % 7
        let first = cal.date(byAdding: .day, value: -lead, to: monthStart)!
        return (0..<42).map { cal.date(byAdding: .day, value: $0, to: first)! }
    }

    var body: some View {
        let days = gridDays
        let items = CalItem.build(store: store, prefs: prefs, device: device, from: days.first!, to: cal.date(byAdding: .day, value: 1, to: days.last!)!)
        let byDay = Dictionary(grouping: items.flatMap { item in dayKeys(item).map { ($0, item) } }, by: { $0.0 }).mapValues { $0.map(\.1) }
        VStack(spacing: 0) {
            weekdayHeader
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { d in
                    DayCell(date: d, items: byDay[key(d)] ?? [], inMonth: cal.isDate(d, equalTo: anchor, toGranularity: .month),
                            selected: cal.isDate(d, inSameDayAs: anchor))
                        .onTapGesture { withAnimation(.snappy) { anchor = d } }
                        .onTapGesture(count: 2) { onNew(cal.date(bySettingHour: 9, minute: 0, second: 0, of: d)!) }
                }
            }
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                withAnimation(.snappy) { anchor = cal.date(byAdding: .month, value: v.translation.width < 0 ? 1 : -1, to: anchor)! }
            })
            Divider()
            dayAgenda(byDay[key(anchor)] ?? [])
        }
    }

    private var weekdayHeader: some View {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                Text(s).font(.caption2.weight(.bold)).foregroundStyle(Color.roostInk3).frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    private func key(_ d: Date) -> String { LocalDateTime(d, in: .current).date.description }

    private func dayKeys(_ item: CalItem) -> [String] {
        var keys: [String] = []
        var d = cal.startOfDay(for: item.start)
        let end = item.allDay ? item.end.addingTimeInterval(-1) : max(item.start, item.end.addingTimeInterval(-1))
        while d <= end && keys.count < 42 {
            keys.append(key(d))
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return keys.isEmpty ? [key(item.start)] : keys
    }

    private func dayAgenda(_ items: [CalItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.dayTitle(anchor)).font(.rounded(.headline)).foregroundStyle(Color.roostInk).padding(.vertical, 10)
                if items.isEmpty {
                    Button { onNew(cal.date(bySettingHour: 9, minute: 0, second: 0, of: anchor)!) } label: {
                        Label("Nothing planned — add an event", systemImage: "plus").font(.subheadline)
                    }
                    .disabled(store.editableCalendars.isEmpty)
                    .padding(.vertical, 8)
                } else {
                    ForEach(items) { item in
                        NavigationLink(value: item) { CalItemRow(item: item) }.buttonStyle(.plain)
                        Divider().padding(.leading, 78)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct DayCell: View {
    var date: Date
    var items: [CalItem]
    var inMonth: Bool
    var selected: Bool

    var body: some View {
        let isToday = Calendar.current.isDateInToday(date)
        VStack(spacing: 3) {
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 13, weight: isToday || selected ? .bold : .medium, design: .rounded))
                .foregroundStyle(isToday ? Color.white : (inMonth ? Color.roostInk : Color.roostInk3))
                .frame(width: 24, height: 24)
                .background(Circle().fill(isToday ? Color.ember : (selected ? Color.emberSoft : Color.clear)))
            VStack(spacing: 2) {
                ForEach(items.prefix(3)) { item in
                    Text(item.title)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(item.isBusy ? Color.roostInk2 : (item.allDay ? Color.white : Color.roostInk))
                        .background(RoundedRectangle(cornerRadius: 3).fill(item.allDay ? item.color : item.color.opacity(item.isBusy ? 0.12 : 0.2)))
                }
                if items.count > 3 {
                    Text("+\(items.count - 3)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.roostInk3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4).padding(.horizontal, 1)
        .frame(height: 76)
        .frame(maxWidth: .infinity)
        .background(selected ? Color.emberSoft.opacity(0.35) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Color.roostLine).frame(height: 0.5) }
        .contentShape(Rectangle())
        .opacity(inMonth ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted)), \(items.count) events")
    }
}

// MARK: - Agenda

struct AgendaView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(CalendarPrefs.self) private var prefs
    @Environment(DeviceCalendars.self) private var device
    @Binding var anchor: Date
    @State private var daysAhead = 60

    var body: some View {
        let cal = Calendar.current
        let from = cal.startOfDay(for: anchor)
        let to = cal.date(byAdding: .day, value: daysAhead, to: from)!
        let items = CalItem.build(store: store, prefs: prefs, device: device, from: from, to: to)
        let grouped = Dictionary(grouping: items) { max(cal.startOfDay(for: $0.start), from) }
        let days = grouped.keys.sorted()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if days.isEmpty {
                    EmptyState(systemImage: "calendar", title: "Wide open", message: "Nothing in the next \(daysAhead) days.")
                }
                ForEach(days, id: \.self) { day in
                    Section {
                        ForEach(grouped[day] ?? []) { item in
                            NavigationLink(value: item) { CalItemRow(item: item) }.buttonStyle(.plain)
                            Divider().padding(.leading, 78)
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(day.formatted(.dateTime.day())).font(.system(.title2, design: .rounded).weight(.bold))
                                .foregroundStyle(cal.isDateInToday(day) ? Color.ember : Color.roostInk)
                            Text(Fmt.dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.roostInk2)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .background(Color.roostBG)
                    }
                }
                Button("Show more") { daysAhead += 60 }.padding(.vertical, 20).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Year

struct YearView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(CalendarPrefs.self) private var prefs
    @Environment(DeviceCalendars.self) private var device
    @Binding var anchor: Date
    var onPickMonth: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let yearStart = cal.date(from: cal.dateComponents([.year], from: anchor))!
        let yearEnd = cal.date(byAdding: .year, value: 1, to: yearStart)!
        let counts = Dictionary(grouping: CalItem.build(store: store, prefs: prefs, device: device, from: yearStart, to: yearEnd),
                                by: { cal.startOfDay(for: $0.start) }).mapValues(\.count)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                ForEach(0..<12, id: \.self) { m in
                    let month = cal.date(byAdding: .month, value: m, to: yearStart)!
                    MiniMonth(month: month, counts: counts).onTapGesture { onPickMonth(month) }
                }
            }
            .padding(16)
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                anchor = cal.date(byAdding: .year, value: v.translation.width < 0 ? 1 : -1, to: anchor)!
            })
        }
    }
}

struct MiniMonth: View {
    var month: Date
    var counts: [Date: Int]

    var body: some View {
        let cal = Calendar.current
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let n = cal.range(of: .day, in: .month, for: month)!.count
        VStack(alignment: .leading, spacing: 4) {
            Text(month.formatted(.dateTime.month(.wide))).font(.caption.weight(.bold))
                .foregroundStyle(cal.isDate(month, equalTo: Date(), toGranularity: .month) ? Color.ember : Color.roostInk)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                ForEach(0..<(lead + n), id: \.self) { i in
                    if i < lead {
                        Color.clear.frame(height: 12)
                    } else {
                        let d = cal.date(byAdding: .day, value: i - lead, to: month)!
                        let c = counts[d] ?? 0
                        Text("\(i - lead + 1)")
                            .font(.system(size: 7, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 12)
                            .foregroundStyle(c > 2 ? Color.white : Color.roostInk2)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color.ember.opacity(c == 0 ? 0 : min(0.2 + Double(c) * 0.18, 0.95))))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(cal.isDateInToday(d) ? Color.ember : .clear, lineWidth: 1))
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.roostSurface))
        .contentShape(Rectangle())
    }
}

// MARK: - Filters

struct CalendarFilterSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(CalendarPrefs.self) private var prefs
    @Environment(DeviceCalendars.self) private var device
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var prefs = prefs
        NavigationStack {
            List {
                Section("People") {
                    ForEach(store.sortedMembers) { m in
                        let on = prefs.people.isEmpty || prefs.people.contains(m.id)
                        Button {
                            if prefs.people.isEmpty { prefs.people = Set(store.members.map(\.id)).subtracting([m.id]) }
                            else if prefs.people.contains(m.id) { prefs.people.remove(m.id) } else { prefs.people.insert(m.id) }
                            if prefs.people.count == store.members.count { prefs.people = [] }
                        } label: {
                            HStack { Avatar(member: m, size: 26); Text(m.name).foregroundStyle(Color.roostInk); Spacer(); if on { Image(systemName: "checkmark").foregroundStyle(Color.ember) } }
                        }
                    }
                }
                Section("Roost calendars") {
                    ForEach(store.liveCalendars) { c in
                        Toggle(isOn: Binding(get: { !prefs.hiddenCalendars.contains(c.id) },
                                             set: { on in if on { prefs.hiddenCalendars.remove(c.id) } else { prefs.hiddenCalendars.insert(c.id) } })) {
                            Label { Text(c.name) } icon: { Dot(color: Palette.named(c.color).color) }
                        }
                    }
                    Toggle("Show busy times", isOn: $prefs.showBusy)
                    Toggle("Show to-dos with due dates", isOn: $prefs.showTasks)
                    Toggle("Color by person", isOn: $prefs.colorByPerson)
                }
                Section {
                    if device.hasAccess {
                        Toggle("Show phone calendars", isOn: $prefs.showDevice)
                        if prefs.showDevice {
                            ForEach(device.grouped) { group in
                                ForEach(group.calendars, id: \.calendarIdentifier) { c in
                                    Toggle(isOn: Binding(get: { device.enabled.contains(c.calendarIdentifier) },
                                                         set: { on in if on { device.enabled.insert(c.calendarIdentifier) } else { device.enabled.remove(c.calendarIdentifier) } })) {
                                        Label { VStack(alignment: .leading) { Text(c.title); Text(group.source).font(.caption).foregroundStyle(Color.roostInk3) } }
                                        icon: { Dot(color: Color(cgColor: c.cgColor)) }
                                    }
                                }
                            }
                        }
                    } else {
                        Button { Task { await device.requestAccess() } } label: {
                            Label("Show my Outlook, Gmail & iCloud calendars", systemImage: "calendar.badge.plus")
                        }
                    }
                } header: {
                    Text("On this iPhone")
                } footer: {
                    Text("Calendars from accounts in Settings → Calendar → Accounts appear here. They stay on your phone and aren't shared with the family.")
                }
            }
            .navigationTitle("Show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
