import SwiftUI
import UIKit
import EventKit
import EventKitUI
import MapKit
import RoostKit

struct EventDetailView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(DeviceCalendars.self) private var device
    @Environment(\.dismiss) private var dismiss
    var occurrence: Occurrence
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var copyMessage: String?

    private var event: CalendarEvent { store.events.first { $0.id == occurrence.event.id } ?? occurrence.event }
    private var isRecurring: Bool { !event.rrule.isEmpty }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Dot(color: Palette.named(store.colorName(for: event)).color, size: 12)
                        Text(store.calendar(event.calendar)?.name ?? "Calendar").font(.subheadline.weight(.semibold)).foregroundStyle(Color.roostInk2)
                        if event.isPrivate { Chip(text: "Private", systemImage: "lock.fill") }
                        if event.isReadOnlyImport { Chip(text: "Subscribed", systemImage: "link") }
                    }
                    Text(event.isBusyBlock ? "Busy" : event.title).font(.system(.title, design: .rounded).weight(.bold)).foregroundStyle(Color.roostInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(occurrence.start.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                        Text(Fmt.range(occurrence)).foregroundStyle(Color.roostInk2)
                        if let r = Fmt.recurrence(event.rrule) { Label(r, systemImage: "repeat").font(.subheadline).foregroundStyle(Color.roostInk2) }
                    }
                    .font(.body.weight(.medium))
                }
                .padding(.vertical, 6)
            }

            let people = store.members(event.members)
            if !people.isEmpty || !event.driver.isEmpty {
                Section("Who") {
                    ForEach(people) { m in
                        HStack { Avatar(member: m, size: 30); Text(m.name) }
                    }
                    if let d = store.member(event.driver) {
                        HStack { Image(systemName: "car.fill").foregroundStyle(Palette.named(d.color).color).frame(width: 30); Text("\(d.name) is driving") }
                    }
                }
            }

            if !event.location.isEmpty || !event.url.isEmpty {
                Section("Where") {
                    if !event.location.isEmpty {
                        Button { openMaps(event.location) } label: { Label(event.location, systemImage: "mappin.and.ellipse") }
                    }
                    if let u = URL(string: event.url), !event.url.isEmpty {
                        Link(destination: u) { Label(u.host ?? event.url, systemImage: "link") }
                    }
                }
            }

            if !event.notes.isEmpty {
                Section("Notes") { Text(event.notes).textSelection(.enabled) }
            }

            if !event.reminders.isEmpty {
                Section("Reminders") {
                    ForEach(event.reminders, id: \.self) { m in Label(Fmt.reminder(m, allDay: event.allDay), systemImage: "bell") }
                }
            }

            if !event.isBusyBlock {
                Section {
                    if device.hasAccess && !device.writableCalendars.isEmpty {
                        Menu {
                            ForEach(device.writableCalendars, id: \.calendarIdentifier) { c in
                                Button("\(c.title) (\(c.source.title))") { copy(to: c) }
                            }
                        } label: { Label("Copy to my calendar…", systemImage: "calendar.badge.plus") }
                    } else {
                        Button { Task { await device.requestAccess() } } label: { Label("Connect my phone's calendars", systemImage: "calendar.badge.plus") }
                    }
                    if let msg = copyMessage { Text(msg).font(.footnote).foregroundStyle(Color.roostInk2) }
                    ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }

            if store.canEdit(event) {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete event", systemImage: "trash") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.canEdit(event) {
                ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            EventEditor(event: event, isNew: false, occurrence: isRecurring ? occurrence : nil)
        }
        .confirmationDialog("Delete event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if isRecurring {
                Button("Delete this event only", role: .destructive) { store.deleteOccurrence(occurrence); dismiss() }
                Button("Delete this and following", role: .destructive) { store.endSeries(before: occurrence); dismiss() }
                Button("Delete all events", role: .destructive) { store.delete(event: event); dismiss() }
            } else {
                Button("Delete", role: .destructive) { store.delete(event: event); dismiss() }
            }
        }
    }

    private var shareText: String {
        var s = "\(event.title)\n\(occurrence.start.formatted(date: .complete, time: .omitted))\n\(Fmt.range(occurrence))"
        if !event.location.isEmpty { s += "\n\(event.location)" }
        if !event.notes.isEmpty { s += "\n\n\(event.notes)" }
        return s
    }

    private func copy(to c: EKCalendar) {
        do {
            try device.copy(event, to: c)
            copyMessage = "Added to \(c.title)."
        } catch {
            copyMessage = error.localizedDescription
        }
    }

    private func openMaps(_ address: String) {
        let q = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        if let url = URL(string: "http://maps.apple.com/?q=\(q)") { UIApplication.shared.open(url) }
    }
}

/// Shows/edits an Outlook/Gmail/iCloud event with Apple's own editor.
struct DeviceEventView: UIViewControllerRepresentable {
    var identifier: String

    func makeUIViewController(context: Context) -> UIViewController {
        let store = DeviceCalendars.shared.eventStore
        guard let ek = store.calendarItem(withIdentifier: identifier) as? EKEvent else {
            let vc = UIHostingController(rootView: EmptyState(systemImage: "calendar.badge.exclamationmark", title: "Event not found", message: "It may have been deleted on another device."))
            return vc
        }
        let vc = EKEventViewController()
        vc.event = ek
        vc.allowsEditing = true
        vc.allowsCalendarPreview = true
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
