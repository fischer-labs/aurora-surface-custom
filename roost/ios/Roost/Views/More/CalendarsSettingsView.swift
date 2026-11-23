import SwiftUI
import UIKit
import RoostKit

struct CalendarsSettingsView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(DeviceCalendars.self) private var device
    @State private var editing: FamilyCalendar?
    @State private var newCalendar: FamilyCalendar?
    @State private var subscribing = false
    @State private var showFeed = false

    var body: some View {
        List {
            Section("Roost calendars") {
                ForEach(store.liveCalendars) { c in
                    Button { editing = c } label: {
                        HStack(spacing: 12) {
                            Dot(color: Palette.named(c.color).color, size: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).foregroundStyle(Color.roostInk)
                                Text(subtitle(c)).font(.caption).foregroundStyle(c.syncError.isEmpty ? Color.roostInk3 : Color.danger).lineLimit(1)
                            }
                            Spacer()
                            if !store.canEdit(c) { Image(systemName: c.kind == .subscription ? "link" : "eye").font(.caption).foregroundStyle(Color.roostInk3) }
                        }
                    }
                    .disabled(!store.canManage(c))
                }
                if store.isAdmin || store.myRole == .caregiver {
                    Button { newCalendar = FamilyCalendar(id: RecordID.make(), family: store.family.id, name: "", color: "teal", kind: store.isAdmin ? .family : .personal) } label: {
                        Label("New calendar", systemImage: "plus")
                    }
                }
                if store.isAdmin && !store.isLocal {
                    Button { subscribing = true } label: { Label("Subscribe to a calendar link", systemImage: "link.badge.plus") }
                }
            }

            if !store.isLocal {
                Section {
                    Button { showFeed = true } label: { Label("Add Roost to Google, Outlook or Apple Calendar", systemImage: "arrow.up.forward.app") }
                } footer: {
                    Text("Your personal feed shows everything you're allowed to see, and updates automatically.")
                }
            }

            Section {
                if device.hasAccess {
                    ForEach(device.grouped) { g in
                        DisclosureGroup(g.source) {
                            ForEach(g.calendars, id: \.calendarIdentifier) { c in
                                Toggle(isOn: Binding(get: { device.enabled.contains(c.calendarIdentifier) },
                                                     set: { on in if on { device.enabled.insert(c.calendarIdentifier) } else { device.enabled.remove(c.calendarIdentifier) } })) {
                                    Label { Text(c.title) } icon: { Dot(color: Color(cgColor: c.cgColor)) }
                                }
                            }
                        }
                    }
                } else {
                    Button { Task { await device.requestAccess() } } label: {
                        Label("Connect Outlook, Gmail & iCloud on this iPhone", systemImage: "iphone.and.arrow.forward")
                    }
                }
            } header: {
                Text("Phone calendars")
            } footer: {
                Text("Add accounts in iOS Settings → Apps → Calendar → Calendar Accounts. Their events show alongside the family calendar; they aren't uploaded to Roost.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle("Calendars")
        .sheet(item: $editing) { c in CalendarEditor(calendar: c, isNew: false) }
        .sheet(item: $newCalendar) { c in CalendarEditor(calendar: c, isNew: true) }
        .sheet(isPresented: $subscribing) { SubscribeSheet() }
        .sheet(isPresented: $showFeed) { FeedSheet() }
    }

    private func subtitle(_ c: FamilyCalendar) -> String {
        switch c.kind {
        case .family: return "Shared family calendar"
        case .personal: return "Personal · \(store.member(c.owner)?.name ?? "")"
        case .subscription:
            if !c.syncError.isEmpty { return "⚠︎ " + c.syncError }
            return c.lastSyncedAt.map { "Subscribed · updated \($0.formatted(.relative(presentation: .named)))" } ?? "Subscribed · waiting for first sync"
        }
    }
}

struct CalendarEditor: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var calendar: FamilyCalendar
    var isNew: Bool
    @State private var confirmDelete = false
    @State private var refreshing = false
    @State private var refreshMsg: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $calendar.name)
                    if isNew && store.isAdmin {
                        Picker("Type", selection: $calendar.kind) {
                            Text("Shared family calendar").tag(FamilyCalendar.Kind.family)
                            Text("Personal calendar").tag(FamilyCalendar.Kind.personal)
                        }
                    }
                    ColorRow(selection: $calendar.color)
                }
                if calendar.kind == .subscription {
                    Section("Source") {
                        Text(calendar.sourceUrl).font(.caption.monospaced()).foregroundStyle(Color.roostInk2).lineLimit(3)
                        Button {
                            Task { refreshing = true; refreshMsg = await store.refresh(subscription: calendar) ?? "Updated."; refreshing = false }
                        } label: { HStack { Text("Refresh now"); Spacer(); if refreshing { ProgressView() } } }
                        if let refreshMsg { Text(refreshMsg).font(.footnote).foregroundStyle(Color.roostInk2) }
                    }
                } else {
                    Section("Default reminder for new events") {
                        ReminderPicker(selection: $calendar.defaultReminders, allDay: false)
                    }
                }
                if !store.isLocal {
                    Section {
                        SharingEditor(sharing: $calendar.sharing, resource: "calendar", subkind: calendar.kind.rawValue, ownerId: calendar.owner)
                    } header: {
                        Text("Who can see it")
                    } footer: {
                        Text("“Busy only” shows time blocks without details — handy for a nanny who needs to know when parents are unavailable.")
                    }
                }
                if !isNew {
                    Section { Button("Delete calendar", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(isNew ? "New calendar" : calendar.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isNew && calendar.kind == .personal && calendar.owner.isEmpty { calendar.owner = store.me?.id ?? "" }
                        store.save(calendar: calendar)
                        dismiss()
                    }
                    .bold().disabled(calendar.name.isEmpty)
                }
            }
            .confirmationDialog("Delete “\(calendar.name)” and all its events?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { var c = calendar; c.deleted = true; store.save(calendar: c); dismiss() }
            }
        }
    }
}

struct SubscribeSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var color = "cyan"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Lincoln Elementary)", text: $name)
                    TextField("webcal:// or https:// link", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ColorRow(selection: $color)
                }
                Section("Where to find the link") {
                    help("Google Calendar", "On a computer: Settings → (your calendar) → Integrate calendar → Secret address in iCal format.")
                    help("Outlook.com / Microsoft 365", "Settings → Calendar → Shared calendars → Publish a calendar → copy the ICS link.")
                    help("iCloud", "Calendar app → (i) next to a calendar → Public Calendar → Share Link.")
                    help("School & sports", "Look for “Subscribe”, “iCal” or “Add to calendar” on the school, TeamSnap or league site.")
                }
            }
            .navigationTitle("Subscribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Subscribe") {
                        var c = FamilyCalendar(id: RecordID.make(), family: store.family.id, name: name, color: color, kind: .subscription)
                        c.sourceUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.save(calendar: c)
                        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); _ = await store.refresh(subscription: c) }
                        dismiss()
                    }
                    .bold().disabled(name.isEmpty || url.count < 10)
                }
            }
        }
    }

    private func help(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(Color.roostInk2)
        }
    }
}

struct FeedSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var feed: Feed?
    @State private var error: String?

    private var httpsURL: URL? { feed.flatMap { f in store.remote?.feedURL(token: f.token) } }
    private var webcalURL: URL? {
        guard let u = httpsURL, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "webcal"
        return c.url
    }

    var body: some View {
        NavigationStack {
            List {
                if let https = httpsURL, let webcal = webcalURL {
                    Section {
                        Link(destination: webcal) { Label("Add to Apple Calendar", systemImage: "apple.logo") }
                        Link(destination: URL(string: "https://calendar.google.com/calendar/r?cid=" + enc(webcal.absoluteString))!) {
                            Label("Add to Google Calendar", systemImage: "g.circle")
                        }
                        Link(destination: URL(string: "https://outlook.live.com/calendar/0/addfromweb?url=" + enc(https.absoluteString) + "&name=" + enc(store.family.name))!) {
                            Label("Add to Outlook.com", systemImage: "envelope")
                        }
                        Link(destination: URL(string: "https://outlook.office.com/calendar/0/addfromweb?url=" + enc(https.absoluteString) + "&name=" + enc(store.family.name))!) {
                            Label("Add to Outlook (work / Microsoft 365)", systemImage: "briefcase")
                        }
                    }
                    Section {
                        Text(https.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                        Button { UIPasteboard.general.string = https.absoluteString } label: { Label("Copy link", systemImage: "doc.on.doc") }
                    } footer: {
                        Text("Keep this link private — anyone with it can read your feed. Google refreshes every few hours; Outlook can take up to a day.")
                    }
                } else if let error {
                    Text(error).foregroundStyle(Color.danger)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Your Roost feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do { feed = try await store.ensureFeed() } catch { self.error = describe(error) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
}
