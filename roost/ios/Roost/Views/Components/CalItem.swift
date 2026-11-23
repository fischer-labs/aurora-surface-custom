import SwiftUI
import EventKit
import RoostKit

/// Anything that shows on the calendar: a Roost occurrence, a phone-calendar
/// event (Outlook/Gmail/iCloud via EventKit) or a to-do with a due date.
struct CalItem: Identifiable, Hashable {
    enum Source: Hashable {
        case roost(Occurrence)
        case device(id: String, calendar: String)
        case task(TaskItem)
    }

    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var color: Color
    var source: Source
    var memberIds: [String]
    var isBusy: Bool = false
    var location: String = ""
    var driverId: String = ""
    /// Palette name for Roost items ("" for phone-calendar events, which bring their own color).
    var colorName: String = ""

    /// Solid fill and the text color that reads on it (AA): darker person colors, dark text on amber/lime.
    var fill: Color { colorName.isEmpty ? color : Palette.named(colorName).fill }
    var onFill: Color { colorName.isEmpty ? .white : Palette.named(colorName).onColor }

    var occurrence: Occurrence? { if case .roost(let o) = source { return o } else { return nil } }
    var task: TaskItem? { if case .task(let t) = source { return t } else { return nil } }
    var isDevice: Bool { if case .device = source { return true } else { return false } }

    static func == (a: CalItem, b: CalItem) -> Bool { a.id == b.id && a.start == b.start && a.title == b.title && a.end == b.end }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(start) }

    /// Builds every item overlapping [from, to) honoring the user's filters.
    @MainActor
    static func build(store: FamilyStore, prefs: CalendarPrefs, device: DeviceCalendars, from: Date, to: Date) -> [CalItem] {
        var out: [CalItem] = []
        for o in store.occurrences(from: from, to: to, hiddenCalendars: prefs.hiddenCalendars, people: prefs.people, includeBusy: prefs.showBusy) {
            let e = o.event
            var title = e.title
            if e.isBusyBlock {
                let who = store.members(e.members).map(\.name).joined(separator: ", ")
                title = who.isEmpty ? "Busy" : "\(who) busy"
            }
            let name = store.colorName(for: e, byPerson: prefs.colorByPerson)
            out.append(CalItem(id: o.id, title: title, start: o.start, end: o.end, allDay: e.allDay,
                               color: Palette.named(name).color,
                               source: .roost(o), memberIds: e.members, isBusy: e.isBusyBlock, location: e.location, driverId: e.driver, colorName: name))
        }
        if prefs.showDevice && prefs.people.isEmpty {
            for ek in device.events(from: from, to: to) {
                out.append(CalItem(id: "dev|" + (ek.calendarItemIdentifier) + "|\(ek.startDate.timeIntervalSince1970)",
                                   title: ek.title ?? "(No title)", start: ek.startDate, end: ek.endDate, allDay: ek.isAllDay,
                                   color: Color(cgColor: ek.calendar.cgColor), source: .device(id: ek.calendarItemIdentifier, calendar: ek.calendar.title),
                                   memberIds: [], location: ek.location ?? ""))
            }
        }
        if prefs.showTasks {
            let cal = Calendar.current
            let liveLists = store.liveListIds
            let familyTZ = TimeZone(identifier: store.family.timezone) ?? .current
            for t in store.tasks where !t.deleted && !t.completed && liveLists.contains(t.list) {
                guard let d = t.dueLocal else { continue }
                if !prefs.people.isEmpty && !t.assignees.contains(where: { prefs.people.contains($0) }) { continue }
                // Due times are in the family's time zone; due dates are floating.
                let start = d.toDate(in: t.dueHasTime ? familyTZ : .current)
                let dayStart = cal.startOfDay(for: start)
                guard start < to && (t.dueHasTime ? start : dayStart.addingTimeInterval(86400)) > from else { continue }
                let name = t.assignees.first.flatMap(store.member)?.color ?? "brown"
                out.append(CalItem(id: "task|" + t.id, title: t.title, start: t.dueHasTime ? start : dayStart,
                                   end: t.dueHasTime ? start.addingTimeInterval(1800) : dayStart.addingTimeInterval(86400),
                                   allDay: !t.dueHasTime, color: Palette.named(name).color, source: .task(t), memberIds: t.assignees, colorName: name))
            }
        }
        return out.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            return a.start == b.start ? a.title < b.title : a.start < b.start
        }
    }
}

/// A compact row used by Today and Agenda.
struct CalItemRow: View {
    @Environment(FamilyStore.self) private var store
    var item: CalItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                if item.allDay {
                    Text("all day").font(.caption.weight(.semibold)).foregroundStyle(Color.roostInk3)
                } else {
                    Text(Fmt.time(item.start)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.roostInk)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if item.task == nil {
                        Text(Fmt.time(item.end)).font(.caption.monospacedDigit()).foregroundStyle(Color.roostInk3)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            .frame(width: 70, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2).fill(item.isBusy ? Color.roostInk3 : item.color).frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let t = item.task {
                        Button { store.toggle(task: t) } label: {
                            Image(systemName: "circle").font(.title3).foregroundStyle(Color.roostInk3)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, -12).padding(.leading, -10).padding(.trailing, -8)
                        .accessibilityLabel("Mark \(t.title) done")
                    }
                    Text(item.title).font(.body.weight(.semibold)).foregroundStyle(item.isBusy ? Color.roostInk3 : Color.roostInk).lineLimit(2)
                    if item.occurrence?.event.rrule.isEmpty == false {
                        Image(systemName: "repeat").font(.caption2).foregroundStyle(Color.roostInk3)
                    }
                }
                HStack(spacing: 8) {
                    if !item.location.isEmpty {
                        Label(item.location, systemImage: "mappin").font(.caption).foregroundStyle(Color.roostInk2).lineLimit(1)
                    }
                    if let d = store.member(item.driverId) {
                        Chip(text: d.name, systemImage: "car.fill", tint: Palette.named(d.color).color)
                    }
                    if case .device(_, let cal) = item.source {
                        Label(cal, systemImage: "iphone").font(.caption).foregroundStyle(Color.roostInk3).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            AvatarStack(members: store.members(item.memberIds), size: 24, max: 3)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
