import SwiftUI
import UIKit
import UserNotifications
import RoostKit

enum MoreRoute: Hashable { case cards, people, calendars, settings }

struct MoreScreen: View {
    @Environment(FamilyStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            RoostLogo(size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.family.name).font(.rounded(.title2, weight: .bold))
                                Text("You're \(store.myRole == .relative ? "family" : store.myRole.label.lowercased())\(store.isLocal ? " · on this phone" : "")")
                                    .font(.subheadline).foregroundStyle(Color.roostInk2)
                            }
                        }
                        AvatarStack(members: store.sortedMembers, size: 34, max: 8)
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    row(.cards, "Care info", "heart.text.square.fill", Palette.red.color, detail: "\(store.liveCards.count)")
                    row(.people, "People & roles", "person.2.fill", Palette.blue.color, detail: "\(store.members.count)")
                    row(.calendars, "Calendars & connections", "calendar.badge.clock", Palette.violet.color, detail: nil)
                    row(.settings, "Settings", "gearshape.fill", Color.roostInk3, detail: nil)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.roostBG)
            .navigationTitle("Family")
            .navigationDestination(for: MoreRoute.self) { r in
                switch r {
                case .cards: InfoCardsView()
                case .people: MembersView()
                case .calendars: CalendarsSettingsView()
                case .settings: SettingsView()
                }
            }
            .navigationDestination(for: InfoCard.self) { InfoCardDetail(card: $0) }
        }
    }

    private func row(_ r: MoreRoute, _ title: String, _ icon: String, _ color: Color, detail: String?) -> some View {
        NavigationLink(value: r) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(.white).frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(color))
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(Color.roostInk3) }
            }
        }
    }
}

// MARK: - Care info

struct InfoCardsView: View {
    @Environment(FamilyStore.self) private var store
    @State private var newCard: InfoCard?

    var body: some View {
        List {
            if store.liveCards.isEmpty {
                EmptyState(systemImage: "heart.text.square", title: "No care info yet", message: "Emergency contacts, allergies, routines and Wi-Fi for sitters and grandparents.")
                    .listRowBackground(Color.clear)
            }
            ForEach(store.liveCards) { c in
                NavigationLink(value: c) {
                    HStack(spacing: 12) {
                        CardIcon(card: c)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.body.weight(.semibold))
                            let preview = InfoCardDetail.preview(c)
                            Text(preview.isEmpty ? (store.isAdmin ? "Tap to fill in" : "Nothing here yet") : preview)
                                .font(.caption).foregroundStyle(preview.isEmpty ? Color.roostInk3 : Color.roostInk2).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if c.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.roostInk3) }
                    }
                }
                .swipeActions(edge: .leading) {
                    if let url = InfoCardDetail.telURL(c) {
                        Button { UIApplication.shared.open(url) } label: { Label("Call", systemImage: "phone.fill") }.tint(.green)
                    }
                }
                .listRowBackground(Color.roostSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle("Care info")
        .toolbar {
            if store.isAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newCard = InfoCard(id: RecordID.make(), family: store.family.id, title: "") } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(item: $newCard) { c in InfoCardEditor(card: c, isNew: true) }
    }
}

struct InfoCardDetail: View {
    @Environment(FamilyStore.self) private var store
    var card: InfoCard
    @State private var editing = false

    /// Card body for previews: drops unfilled "Label:" lines; phone numbers don't break at hyphens.
    static func preview(_ c: InfoCard) -> String {
        c.body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"(\d)-(?=\d)"#, with: "$1\u{2011}", options: .regularExpression)
    }

    static func telURL(_ c: InfoCard) -> URL? {
        let digits = c.phone.filter { "0123456789+".contains($0) }
        return digits.isEmpty ? nil : URL(string: "tel:" + digits)
    }

    static func icon(for c: InfoCard) -> String {
        if !c.icon.isEmpty && UIImage(systemName: c.icon) != nil { return c.icon }
        switch c.kind {
        case "contact": return "phone.fill"
        case "medical": return "cross.case.fill"
        case "school": return "graduationcap.fill"
        case "routine": return "clock.fill"
        case "home": return "house.fill"
        default: return "note.text"
        }
    }

    private var current: InfoCard { store.infoCards.first { $0.id == card.id } ?? card }

    var body: some View {
        let c = current
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    CardIcon(card: c, size: 48)
                    Text(c.title).font(.rounded(.title2, weight: .bold))
                    if let m = store.member(c.aboutMember) { Label(m.name, systemImage: "person.fill").font(.subheadline).foregroundStyle(Color.roostInk2) }
                }
                .padding(.vertical, 4)
            }
            if let url = InfoCardDetail.telURL(c) {
                Section {
                    Link(destination: url) {
                        Label("Call \(c.phone)", systemImage: "phone.fill").font(.body.weight(.semibold)).frame(minHeight: 44)
                    }
                }
            }
            if !c.address.isEmpty {
                Section {
                    Button {
                        let q = c.address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let u = URL(string: "http://maps.apple.com/?q=\(q)") { UIApplication.shared.open(u) }
                    } label: { Label(c.address, systemImage: "mappin.and.ellipse") }
                }
            }
            if !c.body.isEmpty {
                Section { Text(c.body).textSelection(.enabled).font(.body) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.canEdit(c) { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } } }
        }
        .sheet(isPresented: $editing) { InfoCardEditor(card: c, isNew: false) }
    }
}

struct InfoCardEditor: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var card: InfoCard
    var isNew: Bool
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (e.g. Pediatrician)", text: $card.title)
                    Picker("Kind", selection: $card.kind) {
                        Text("Contact").tag("contact"); Text("Medical").tag("medical"); Text("School").tag("school")
                        Text("Routine").tag("routine"); Text("Home").tag("home"); Text("Note").tag("note")
                    }
                    Picker("About", selection: $card.aboutMember) {
                        Text("Everyone").tag("")
                        ForEach(store.sortedMembers) { m in Text(m.name).tag(m.id) }
                    }
                    Toggle("Pin to Today", isOn: $card.pinned)
                }
                Section {
                    TextField("Phone", text: $card.phone).keyboardType(.phonePad)
                    TextField("Address", text: $card.address)
                    TextField("Details", text: $card.body, axis: .vertical).lineLimit(4...16)
                }
                if !store.isLocal {
                    Section("Who can see this") {
                        SharingEditor(sharing: $card.sharing, resource: "info", subkind: "card", ownerId: card.owner)
                    }
                }
                if !isNew {
                    Section { Button("Delete", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(isNew ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.save(card: card); dismiss() }.bold().disabled(card.title.isEmpty) }
            }
            .confirmationDialog("Delete this card?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { var c = card; c.deleted = true; store.save(card: c); dismiss() }
            }
        }
    }
}

// MARK: - Sharing

/// Per-role levels with per-person overrides (DESIGN §3.2).
struct SharingEditor: View {
    @Environment(FamilyStore.self) private var store
    @Binding var sharing: Sharing?
    var resource: String
    var subkind: String
    var ownerId: String

    private var levels: [AccessLevel] { resource == "calendar" ? AccessLevel.allCases : [.none, .view, .edit] }

    var body: some View {
        ForEach(Role.allCases) { role in
            let def = Access.defaultLevel(resource: resource, subkind: subkind, role: role)
            Picker(selection: Binding(
                get: { sharing?.roles?[role.rawValue].flatMap(AccessLevel.init(rawValue:)) ?? def },
                set: { v in
                    var s = sharing ?? Sharing()
                    var r = s.roles ?? [:]
                    r[role.rawValue] = v == def ? nil : v.rawValue
                    s.roles = r.isEmpty ? nil : r
                    sharing = s
                })) {
                ForEach(levels, id: \.self) { l in Text(l.label).tag(l) }
            } label: {
                VStack(alignment: .leading) {
                    Text(role == .relative ? "Family (grandparents…)" : role.label + "s")
                    Text(store.members.filter { $0.role == role }.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(Color.roostInk3)
                }
            }
        }
        DisclosureGroup("Exceptions for specific people") {
            ForEach(store.sortedMembers.filter { $0.id != ownerId }) { m in
                Picker(selection: Binding(
                    get: { sharing?.people?[m.id] ?? "" },
                    set: { v in
                        var s = sharing ?? Sharing()
                        var p = s.people ?? [:]
                        p[m.id] = v.isEmpty ? nil : v
                        s.people = p.isEmpty ? nil : p
                        sharing = s
                    })) {
                    Text("Role default").tag("")
                    ForEach(levels, id: \.self) { l in Text(l.label).tag(l.rawValue) }
                } label: {
                    HStack { Avatar(member: m, size: 24); Text(m.name) }
                }
            }
        }
    }
}

// MARK: - People

struct MembersView: View {
    @Environment(FamilyStore.self) private var store
    @State private var inviting = false
    @State private var editing: Member?
    @State private var newProfile: Member?

    var body: some View {
        List {
            Section {
                ForEach(store.sortedMembers) { m in
                    Button { editing = m } label: {
                        HStack(spacing: 12) {
                            Avatar(member: m, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(m.name).font(.body.weight(.semibold)).foregroundStyle(Color.roostInk)
                                    if m.user == store.userId { Text("You").font(.caption2.weight(.bold)).foregroundStyle(Color.ember) }
                                }
                                Text(m.hasLogin ? m.role.label : "\(m.role.label) · no login").font(.caption).foregroundStyle(Color.roostInk2)
                            }
                            Spacer()
                        }
                    }
                }
            } footer: {
                Text("Kids can be profiles without a login — you can still assign events and to-dos to them.")
            }
            if !store.invites.isEmpty && store.isAdmin {
                Section("Pending invites") {
                    ForEach(store.invites.filter { $0.usedBy.isEmpty }) { inv in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(inv.name.isEmpty ? inv.role.label : inv.name)
                                Text("\(inv.role.label) · \(inv.code)").font(.caption.monospaced()).foregroundStyle(Color.roostInk2)
                            }
                            Spacer()
                            ShareLink(item: InviteSheet.message(inv, store: store)) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle("People & roles")
        .toolbar {
            if store.isAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !store.isLocal { Button { inviting = true } label: { Label("Invite someone", systemImage: "envelope") } }
                        Button { newProfile = Member(id: RecordID.make(), family: store.family.id, name: "", role: .kid, color: Palette.allCases.randomElement()!.rawValue) } label: {
                            Label("Add a profile (no login)", systemImage: "person.badge.plus")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $inviting) { InviteSheet() }
        .sheet(item: $editing) { m in MemberEditor(member: m, isNew: false) }
        .sheet(item: $newProfile) { m in MemberEditor(member: m, isNew: true) }
    }
}

struct MemberEditor: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var member: Member
    var isNew: Bool
    @State private var confirmRemove = false
    @State private var inviteFor: Member?

    private var isMe: Bool { member.user == store.userId }
    private var canEditBasics: Bool { store.isAdmin || isMe }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); Avatar(member: member, size: 72); Spacer() }.listRowBackground(Color.clear)
                    TextField("Name", text: $member.name)
                    TextField("Emoji (optional)", text: $member.emoji)
                    ColorRow(selection: $member.color)
                }
                .disabled(!canEditBasics)
                if store.isAdmin && !isMe {
                    Section {
                        Picker("Role", selection: $member.role) {
                            ForEach(Role.allCases.filter { $0 != .owner || store.myRole == .owner }) { r in Text(r.label).tag(r) }
                        }
                    } footer: { Text(member.role.blurb) }
                }
                if isMe {
                    Section {
                        Toggle("Remind me about every family event", isOn: $member.notifyAll)
                    } footer: {
                        Text("Otherwise you're reminded about events you're part of or driving, and to-dos assigned to you.")
                    }
                }
                if !isNew && store.isAdmin && !member.hasLogin && !store.isLocal {
                    Section { Button("Invite \(member.name) to log in") { inviteFor = member } }
                }
                if !isNew && store.isAdmin && !isMe {
                    Section { Button("Remove from family", role: .destructive) { confirmRemove = true } }
                }
            }
            .navigationTitle(isNew ? "New profile" : member.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if canEditBasics {
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { store.save(member: member); dismiss() }.bold().disabled(member.name.isEmpty) }
                }
            }
            .confirmationDialog("Remove \(member.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { store.remove(member: member); dismiss() }
            } message: { Text("They'll lose access to everything in this family.") }
            .sheet(item: $inviteFor) { m in InviteSheet(profile: m) }
        }
    }
}

struct InviteSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var profile: Member? = nil
    @State private var role: Role = .caregiver
    @State private var name = ""
    @State private var invite: Invite?
    @State private var busy = false
    @State private var error: String?

    static func message(_ inv: Invite, store: FamilyStore) -> String {
        let server = UserDefaults.standard.string(forKey: "serverHost") ?? ""
        var link = "roost://join?code=\(inv.code)"
        if !server.isEmpty { link += "&server=\(server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? server)" }
        return """
        You're invited to \(store.family.name) on Roost (as \(inv.role.label.lowercased())).

        1. Install Roost (TestFlight link from us).
        2. Tap “I have an invite code” and enter: \(inv.code)
        Server: \(server)

        Or open this link on your iPhone: \(link)
        """
    }

    var body: some View {
        NavigationStack {
            Form {
                if let inv = invite {
                    Section {
                        VStack(spacing: 10) {
                            Text("Invite code").font(.caption.weight(.bold)).foregroundStyle(Color.roostInk3)
                            Text(inv.code).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(Color.ember)
                                .textSelection(.enabled)
                            Text("Valid for 7 days, works once.").font(.footnote).foregroundStyle(Color.roostInk2)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        ShareLink(item: InviteSheet.message(inv, store: store)) { Label("Send invite", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.string = inv.code } label: { Label("Copy code", systemImage: "doc.on.doc") }
                    }
                } else {
                    Section {
                        TextField("Their name", text: $name).disabled(profile != nil)
                        Picker("Role", selection: $role) {
                            ForEach(Role.allCases.filter { $0 != .owner || store.myRole == .owner }) { r in Text(r.label).tag(r) }
                        }
                    } footer: { Text(role.blurb + " You can fine-tune exactly what they see per calendar and list.") }
                    ErrorRow(message: error)
                    Section {
                        Button {
                            Task {
                                busy = true; error = nil
                                do { invite = try await store.createInvite(role: role, name: name, membership: profile?.id) }
                                catch { self.error = describe(error) }
                                busy = false
                            }
                        } label: { HStack { Spacer(); if busy { ProgressView() } else { Text("Create invite").bold() }; Spacer() } }
                        .disabled(busy)
                    }
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                if let profile { name = profile.name; role = profile.role == .owner ? .parent : profile.role }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section("Reminders") {
                HStack {
                    Text("Notifications")
                    Spacer()
                    switch notifStatus {
                    case .authorized, .provisional, .ephemeral: Text("On").foregroundStyle(Color.green)
                    case .denied: Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    default: Button("Turn on") { Task { _ = await ReminderScheduler.shared.requestPermission(); await refresh() } }
                    }
                }
                if let me = store.me {
                    Toggle("Remind me about every family event", isOn: Binding(get: { me.notifyAll }, set: { v in var m = me; m.notifyAll = v; store.save(member: m) }))
                }
                Text("Reminders are scheduled on this iPhone for the next two weeks and refresh whenever Roost syncs.")
                    .font(.footnote).foregroundStyle(Color.roostInk3)
            }
            if !store.rejected.isEmpty {
                Section {
                    ForEach(store.rejected) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.what).font(.subheadline.weight(.semibold))
                            Text(r.message).font(.caption).foregroundStyle(Color.roostInk2)
                        }
                    }
                    Button("OK") { store.dismissRejected() }
                } header: {
                    Text("Not saved")
                } footer: {
                    Text("The server didn't accept these changes (usually a permission your role doesn't have). Everything else synced.")
                }
            }
            Section("Account") {
                if let u = app.user { LabeledContent("Signed in as", value: u.name.isEmpty ? u.email : u.name) }
                if !store.isLocal { LabeledContent("Server", value: app.serverHost) }
                if let last = store.lastSync { LabeledContent("Last synced", value: last.formatted(date: .abbreviated, time: .shortened)) }
                if !store.outbox.isEmpty { LabeledContent("Waiting to sync", value: "\(store.outbox.count) change\(store.outbox.count == 1 ? "" : "s")") }
                if !store.isLocal { Button("Sync now") { Task { await store.syncNow() } } }
                Button(store.isLocal ? "Erase and start over" : "Sign out", role: .destructive) { confirmSignOut = true }
            }
            Section("About") {
                LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0")
                LabeledContent("Grocery dictionary", value: "\(GroceryTaxonomy.bundled.termCount) items")
                Text("Roost is private to your family. Data lives on your own server and this phone.").font(.footnote).foregroundStyle(Color.roostInk3)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle("Settings")
        .task { await refresh() }
        .confirmationDialog(store.isLocal ? "Erase everything on this phone?" : "Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(store.isLocal ? "Erase" : "Sign out", role: .destructive) { app.signOut() }
        }
    }

    private func refresh() async {
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Neutral icon badge — ember is reserved for actions, today and selection.
struct CardIcon: View {
    var card: InfoCard
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: InfoCardDetail.icon(for: card))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Color.roostInk2)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.roostSurface2))
            .accessibilityHidden(true)
    }
}
