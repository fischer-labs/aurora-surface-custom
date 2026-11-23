import SwiftUI
import RoostKit

/// The Roost mark drawn in SwiftUI: a roof over a family in a nest.
struct RoostLogo: View {
    var size: CGFloat = 96
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xEC7344), Color(hex: 0xC2441D)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { ctx, sz in
                let s = sz.width / 1024
                var roof = Path()
                roof.move(to: CGPoint(x: 214 * s, y: 500 * s))
                roof.addLine(to: CGPoint(x: 512 * s, y: 252 * s))
                roof.addLine(to: CGPoint(x: 810 * s, y: 500 * s))
                ctx.stroke(roof, with: .color(Color(hex: 0xFFF6EC)), style: StrokeStyle(lineWidth: 88 * s, lineCap: .round, lineJoin: .round))
                let cream = GraphicsContext.Shading.color(Color(hex: 0xFFF6EC))
                for (x, y, r) in [(414.0, 584.0, 60.0), (610.0, 584.0, 60.0), (512.0, 612.0, 44.0)] {
                    ctx.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)), with: cream)
                }
                var nest = Path()
                nest.move(to: CGPoint(x: 292 * s, y: 640 * s))
                nest.addLine(to: CGPoint(x: 732 * s, y: 640 * s))
                nest.addQuadCurve(to: CGPoint(x: 512 * s, y: 812 * s), control: CGPoint(x: 732 * s, y: 812 * s))
                nest.addQuadCurve(to: CGPoint(x: 292 * s, y: 640 * s), control: CGPoint(x: 292 * s, y: 812 * s))
                ctx.fill(nest, with: cream)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: 0xC2441D).opacity(0.25), radius: 16, y: 8)
        .accessibilityHidden(true)
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [Step] = []

    enum Step: Hashable { case create, join, signIn, local }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 40)
                    RoostLogo(size: 104)
                    VStack(spacing: 8) {
                        Text("Roost").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(Color.roostInk)
                        Text("Your family's calendar, lists and groceries —\nshared with exactly the right people.")
                            .font(.callout).foregroundStyle(Color.roostInk2).multilineTextAlignment(.center)
                    }
                    VStack(spacing: 12) {
                        bigButton("Start a new family", icon: "house.fill", prominent: true) { path.append(.create) }
                        bigButton("I have an invite code", icon: "envelope.open.fill") { path.append(.join) }
                        bigButton("Sign in", icon: "person.crop.circle") { path.append(.signIn) }
                    }
                    .padding(.top, 8)
                    Button("Try it on this phone only") { path.append(.local) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.roostInk2)
                    if let banner = app.banner {
                        Text(banner).font(.footnote).foregroundStyle(Color.danger).multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color.roostBG.ignoresSafeArea())
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .create: CreateFamilyFlow()
                case .join: JoinFlow()
                case .signIn: SignInView()
                case .local: LocalStartView()
                }
            }
        }
        .onAppear { if app.pendingInvite != nil { path = [.join] } }
        .onChange(of: app.pendingInvite?.code) { _, code in if code != nil { path = [.join] } }
    }

    private func bigButton(_ title: String, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24)
                Text(title).fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).opacity(0.6)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .foregroundStyle(prominent ? Color.white : Color.roostInk)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(prominent ? Color.ember : Color.roostSurface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.roostLine, lineWidth: prominent ? 0 : 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared pieces

struct ServerField: View {
    @Environment(AppModel.self) private var app
    @State private var checking = false
    @State private var status: String?
    @State private var ok = false

    var body: some View {
        @Bindable var app = app
        Section {
            TextField("family.example.com", text: $app.serverHost)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button {
                checking = true
                Task {
                    let err = await app.testServer(app.serverHost)
                    ok = err == nil
                    status = err ?? "Connected to Roost ✓"
                    checking = false
                }
            } label: {
                HStack { Text("Check connection"); Spacer(); if checking { ProgressView() } }
            }
            if let status { Text(status).font(.footnote).foregroundStyle(ok ? Color.green : Color.danger) }
        } header: {
            Text("Your Roost server")
        } footer: {
            Text("The address of the Roost server your family uses (set up once by a parent — see the deployment guide).")
        }
    }
}

struct ErrorRow: View {
    var message: String?
    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.danger)
        }
    }
}

func describe(_ error: Error) -> String { (error as? PBError)?.errorDescription ?? error.localizedDescription }

// MARK: - Create

struct CreateFamilyFlow: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var familyName = ""
    @State private var timezone = TimeZone.current.identifier
    @State private var busy = false
    @State private var error: String?
    @State private var accountDone = false
    @State private var setupCode = ""

    var body: some View {
        Form {
            if !accountDone {
                ServerField()
                Section("You") {
                    TextField("Your name", text: $name).textContentType(.givenName)
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    SecureField("Password (8+ characters)", text: $password).textContentType(.newPassword)
                }
                Section {
                    TextField("Setup code (first account only)", text: $setupCode)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } footer: {
                    Text("A brand-new server asks for the code printed in its log. Leave this empty if your family already uses Roost on this server.")
                }
            }
            Section {
                TextField("e.g. The Riveras", text: $familyName)
                Picker("Time zone", selection: $timezone) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
            } header: {
                Text("Your family")
            } footer: {
                Text("You'll be the owner. Invite your partner, nanny and grandparents next — each gets their own level of access.")
            }
            ErrorRow(message: error)
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text("Create family").bold() }; Spacer() }
                }
                .disabled(busy || familyName.isEmpty || (!accountDone && (name.isEmpty || email.isEmpty || password.count < 8)))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle("New family")
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if !accountDone {
                try await app.createAccount(name: name, email: email, password: password,
                                            inviteCode: setupCode.trimmingCharacters(in: .whitespaces).isEmpty ? nil : setupCode)
                accountDone = true
            }
            try await app.createFamily(name: familyName, timezone: timezone)
        } catch {
            self.error = describe(error)
        }
    }
}

// MARK: - Join

struct JoinFlow: View {
    @Environment(AppModel.self) private var app
    @State private var code = ""
    @State private var preview: (family: String, role: Role, name: String)?
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var haveAccount = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            ServerField()
            Section {
                TextField("K7QM-2XPD", text: $code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.system(.title3, design: .monospaced))
                    .onChange(of: code) { _, _ in preview = nil }
                Button("Look up invite") { Task { await lookUp() } }.disabled(code.count < 8)
            } header: {
                Text("Invite code")
            } footer: {
                Text("Ask a parent in the family to send you an invite from Roost → Family → Invite.")
            }
            if let p = preview {
                Section {
                    HStack(spacing: 12) {
                        RoostLogo(size: 44)
                        VStack(alignment: .leading) {
                            Text("Join \(p.family)").font(.rounded(.headline))
                            Text("as \(p.role.label)").font(.subheadline).foregroundStyle(Color.roostInk2)
                        }
                    }
                    Text(p.role.blurb).font(.footnote).foregroundStyle(Color.roostInk2)
                }
                Section {
                    Toggle("I already have a Roost account", isOn: $haveAccount)
                    if !haveAccount { TextField("Your name", text: $name).textContentType(.givenName) }
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    SecureField(haveAccount ? "Password" : "Choose a password (8+)", text: $password).textContentType(haveAccount ? .password : .newPassword)
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Join family").bold() }; Spacer() }
                    }
                    .disabled(busy || email.isEmpty || password.count < 8 || (!haveAccount && name.isEmpty))
                }
            }
            ErrorRow(message: error)
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle("Join a family")
        .onAppear {
            if let inv = app.pendingInvite {
                code = inv.code
                Task { await lookUp() }
            }
        }
    }

    private func lookUp() async {
        error = nil
        guard let url = app.baseURL else { error = "Enter your server address first."; return }
        do {
            let p = try await PocketBaseClient(baseURL: url).invitePreview(code: code)
            preview = p
            if name.isEmpty { name = p.name }
        } catch {
            self.error = describe(error)
        }
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if haveAccount {
                try await app.signInOnly(email: email, password: password)
            } else {
                try await app.createAccount(name: name, email: email, password: password, inviteCode: code)
            }
            try await app.join(code: code, name: haveAccount ? nil : name)
            app.pendingInvite = nil
        } catch {
            self.error = describe(error)
        }
    }
}

// MARK: - Sign in

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            ServerField()
            Section("Account") {
                TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                SecureField("Password", text: $password).textContentType(.password)
            }
            ErrorRow(message: error)
            Section {
                Button {
                    Task {
                        busy = true; error = nil
                        do { try await app.signIn(email: email, password: password) } catch { self.error = describe(error) }
                        busy = false
                    }
                } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text("Sign in").bold() }; Spacer() }
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle("Sign in")
    }
}

// MARK: - Local only

struct LocalStartView: View {
    @Environment(AppModel.self) private var app
    @State private var familyName = ""
    @State private var yourName = ""

    var body: some View {
        Form {
            Section {
                TextField("Family name", text: $familyName)
                TextField("Your name", text: $yourName)
            } footer: {
                Text("Everything stays on this iPhone. Calendar overlays, reminders and the grocery brain all work. Sharing with family needs a Roost server.")
            }
            Section {
                Button {
                    app.startLocal(familyName: familyName.isEmpty ? "My Family" : familyName, yourName: yourName)
                } label: {
                    HStack { Spacer(); Text("Start").bold(); Spacer() }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle("On this phone")
    }
}
