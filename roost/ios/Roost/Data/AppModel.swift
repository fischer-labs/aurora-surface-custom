import Foundation
import Observation
import RoostKit

/// App-wide session state: which server, who is signed in, which family is open.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, onboarding, ready }

    /// One instance for the UI and for Siri/Shortcuts intents.
    static let shared = AppModel()

    var phase: Phase = .launching
    var store: FamilyStore?
    var user: UserProfile?
    var serverHost: String {
        didSet { UserDefaults.standard.set(serverHost, forKey: "serverHost") }
    }
    var localOnly: Bool {
        didSet { UserDefaults.standard.set(localOnly, forKey: "localOnly") }
    }
    /// Invite from a roost://join link, consumed by onboarding.
    var pendingInvite: (code: String, server: String?)?
    var banner: String?

    private(set) var client: PocketBaseClient?

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "RoostServerHost") as? String) ?? ""
        serverHost = UserDefaults.standard.string(forKey: "serverHost") ?? configured
        localOnly = UserDefaults.standard.bool(forKey: "localOnly")
    }

    var baseURL: URL? { AppModel.url(from: serverHost) }

    static func url(from host: String) -> URL? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        let withScheme = h.contains("://") ? h : "https://" + h
        return URL(string: withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme)
    }

    // MARK: Launch

    @ObservationIgnored private var bootTask: Task<Void, Never>?

    /// Safe to call more than once (the UI and an intent may both start the app).
    func bootstrap() async {
        if let t = bootTask { await t.value; return }
        let t = Task { await self.runBootstrap() }
        bootTask = t
        await t.value
    }

    private func runBootstrap() async {
        // `-RoostDemo 1` (launch argument): a realistic sample family, on device only.
        if UserDefaults.standard.bool(forKey: "RoostDemo") {
            store = FamilyStore(snapshot: LocalSeed.demo(), userId: LocalSeed.userId, remote: nil)
            phase = .ready
            return
        }
        if localOnly, let snap = Snapshot.load(familyId: LocalSeed.familyId) {
            store = FamilyStore(snapshot: snap, userId: LocalSeed.userId, remote: nil)
            phase = .ready
            return
        }
        guard let url = baseURL, let token = Keychain.get("token") else { phase = .onboarding; return }
        let pb = PocketBaseClient(baseURL: url, token: token)
        client = pb
        // Open the cached family immediately so the app works offline.
        if let famId = UserDefaults.standard.string(forKey: "familyId"), let uid = UserDefaults.standard.string(forKey: "userId"),
           let snap = Snapshot.load(familyId: famId) {
            user = UserProfile(json: ["id": uid, "name": UserDefaults.standard.string(forKey: "userName") ?? ""])
            store = FamilyStore(snapshot: snap, userId: uid, remote: pb)
            phase = .ready
            Task { await refreshSession() }
            return
        }
        await refreshSession()
    }

    /// Re-validates the token and (re)opens the family.
    func refreshSession() async {
        guard let pb = client else { phase = .onboarding; return }
        do {
            let profile = try await pb.authRefresh()
            Keychain.set("token", pb.token ?? "")
            user = profile
            remember(profile)
            if store == nil { try await openFirstFamily() }
            await store?.syncNow()
            store?.startRealtime()
        } catch let e as PBError where e.isAuth {
            signOut()
        } catch {
            if store == nil { phase = .onboarding; banner = (error as? PBError)?.message ?? error.localizedDescription }
        }
    }

    private func remember(_ u: UserProfile) {
        UserDefaults.standard.set(u.id, forKey: "userId")
        UserDefaults.standard.set(u.name, forKey: "userName")
    }

    private func openFirstFamily() async throws {
        guard let pb = client, let user else { return }
        let fams = try await pb.list("families", sort: "created")
        guard let first = fams.first else { phase = .onboarding; return }
        open(family: Family(json: first), pb: pb, userId: user.id)
    }

    private func open(family: Family, pb: PocketBaseClient, userId: String) {
        UserDefaults.standard.set(family.id, forKey: "familyId")
        let snap = Snapshot.load(familyId: family.id) ?? Snapshot(family: family)
        let s = FamilyStore(snapshot: snap, userId: userId, remote: pb)
        store = s
        phase = .ready
    }

    // MARK: Onboarding actions

    func testServer(_ host: String) async -> String? {
        guard let url = AppModel.url(from: host) else { return "Enter your server address." }
        do {
            let r = try await PocketBaseClient(baseURL: url).send("GET", "api/roost/config") as? JSON
            return r?.s("name") == "Roost" ? nil : "That server doesn't look like Roost."
        } catch {
            return (error as? PBError)?.message ?? error.localizedDescription
        }
    }

    /// Authenticates without opening a family (used before joining one).
    func signInOnly(email: String, password: String) async throws {
        guard let url = baseURL else { throw PBError(status: 0, message: "Set your server address first.", fieldErrors: [:]) }
        let pb = PocketBaseClient(baseURL: url)
        let (token, profile) = try await pb.authWithPassword(email: email, password: password)
        Keychain.set("token", token)
        client = pb
        user = profile
        remember(profile)
        localOnly = false
    }

    func signIn(email: String, password: String) async throws {
        try await signInOnly(email: email, password: password)
        try await openFirstFamily()
        if store == nil { throw PBError(status: 404, message: "This account isn't in a family yet. Use an invite code or start a new family.", fieldErrors: [:]) }
        if let store { await store.syncNow(); store.startRealtime() }
    }

    func createAccount(name: String, email: String, password: String, inviteCode: String?) async throws {
        guard let url = baseURL else { throw PBError(status: 0, message: "Set your server address first.", fieldErrors: [:]) }
        try await PocketBaseClient(baseURL: url).signUp(email: email, password: password, name: name, inviteCode: inviteCode)
        let pb = PocketBaseClient(baseURL: url)
        let (token, profile) = try await pb.authWithPassword(email: email, password: password)
        Keychain.set("token", token)
        client = pb
        user = profile
        remember(profile)
        localOnly = false
    }

    func createFamily(name: String, timezone: String) async throws {
        guard let pb = client, let user else { return }
        let fam = Family(json: try await pb.create("families", ["name": name, "timezone": timezone]))
        open(family: fam, pb: pb, userId: user.id)
        await store?.syncNow()
        store?.startRealtime()
    }

    func join(code: String, name: String?) async throws {
        guard let pb = client, let user else { return }
        let r = try await pb.join(code: code, name: name)
        let fam = Family(json: try await pb.send("GET", "api/collections/families/records/\(r.family)") as? JSON ?? [:])
        open(family: fam, pb: pb, userId: user.id)
        await store?.syncNow()
        store?.startRealtime()
    }

    func startLocal(familyName: String, yourName: String) {
        localOnly = true
        let snap = LocalSeed.snapshot(familyName: familyName, yourName: yourName)
        store = FamilyStore(snapshot: snap, userId: LocalSeed.userId, remote: nil)
        store?.saveSoon()
        phase = .ready
    }

    func signOut() {
        store?.stopRealtime()
        Keychain.delete("token")
        if let famId = UserDefaults.standard.string(forKey: "familyId") { Snapshot.delete(familyId: famId) }
        if localOnly { Snapshot.delete(familyId: LocalSeed.familyId) }
        UserDefaults.standard.removeObject(forKey: "familyId")
        UserDefaults.standard.removeObject(forKey: "userId")
        localOnly = false
        store = nil
        user = nil
        client = nil
        ReminderScheduler.shared.clearAll()
        phase = .onboarding
    }

    // MARK: Deep links: roost://join?code=K7QM-2XPD&server=https://family.example.com

    func handle(url: URL) {
        guard url.scheme == "roost", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if url.host == "join", let code = q["code"], !code.isEmpty {
            if let server = q["server"], !server.isEmpty, store == nil { serverHost = server }
            pendingInvite = (code, q["server"])
            if store != nil { banner = "You're already in a family. Sign out to join another." }
        }
    }
}
