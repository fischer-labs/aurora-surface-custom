import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PBError: Error, LocalizedError, Sendable {
    public var status: Int
    public var message: String
    public var fieldErrors: [String: String]
    public var errorDescription: String? {
        if let first = fieldErrors.first { return "\(message) (\(first.key): \(first.value))" }
        return message
    }
    public init(status: Int, message: String, fieldErrors: [String: String] = [:]) {
        self.status = status; self.message = message; self.fieldErrors = fieldErrors
    }
    public var isOffline: Bool { status == 0 }
    public var isAuth: Bool { status == 401 }
}

/// Minimal async PocketBase REST client (no third-party SDK).
public final class PocketBaseClient: @unchecked Sendable {
    public var baseURL: URL
    public var token: String?
    let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    @discardableResult
    public func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSON? = nil) async throws -> Any {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withCheckedThrowingContinuation { cont in
                session.dataTask(with: req) { d, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r!)) }
                }.resume()
            }
        } catch {
            throw PBError(status: 0, message: "Can't reach your Roost server. Changes are saved and will sync.", fieldErrors: [:])
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj: Any = data.isEmpty ? [:] as JSON : ((try? JSONSerialization.jsonObject(with: data)) ?? [:] as JSON)
        guard (200..<300).contains(status) else {
            let j = obj as? JSON ?? [:]
            var fields: [String: String] = [:]
            for (k, v) in (j["data"] as? JSON) ?? [:] { fields[k] = (v as? JSON)?.s("message") ?? "\(v)" }
            let msg = j.s("message").isEmpty ? "Request failed (\(status))." : j.s("message")
            throw PBError(status: status, message: msg, fieldErrors: fields)
        }
        return obj
    }

    // MARK: Auth

    public func authWithPassword(email: String, password: String) async throws -> (token: String, user: UserProfile) {
        let r = try await send("POST", "api/collections/users/auth-with-password", body: ["identity": email, "password": password]) as! JSON
        token = r.s("token")
        return (r.s("token"), UserProfile(json: r["record"] as? JSON ?? [:]))
    }

    public func signUp(email: String, password: String, name: String, inviteCode: String?) async throws {
        var body: JSON = ["email": email, "password": password, "passwordConfirm": password, "name": name]
        if let inviteCode, !inviteCode.isEmpty { body["inviteCode"] = inviteCode }
        try await send("POST", "api/collections/users/records", body: body)
    }

    public func authRefresh() async throws -> UserProfile {
        let r = try await send("POST", "api/collections/users/auth-refresh") as! JSON
        token = r.s("token")
        return UserProfile(json: r["record"] as? JSON ?? [:])
    }

    // MARK: Records

    public func list(_ collection: String, filter: String? = nil, sort: String? = nil) async throws -> [JSON] {
        var page = 1
        var out: [JSON] = []
        while true {
            var q = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "perPage", value: "500"), URLQueryItem(name: "skipTotal", value: "1")]
            if let filter { q.append(URLQueryItem(name: "filter", value: filter)) }
            if let sort { q.append(URLQueryItem(name: "sort", value: sort)) }
            let r = try await send("GET", "api/collections/\(collection)/records", query: q) as! JSON
            let items = r["items"] as? [JSON] ?? []
            out += items
            if items.count < 500 { break }
            page += 1
        }
        return out
    }

    public func create(_ collection: String, _ body: JSON) async throws -> JSON {
        try await send("POST", "api/collections/\(collection)/records", body: body) as! JSON
    }

    public func update(_ collection: String, id: String, _ body: JSON) async throws -> JSON {
        try await send("PATCH", "api/collections/\(collection)/records/\(id)", body: body) as! JSON
    }

    public func delete(_ collection: String, id: String) async throws {
        try await send("DELETE", "api/collections/\(collection)/records/\(id)")
    }

    // MARK: Roost routes

    public func invitePreview(code: String) async throws -> (family: String, role: Role, name: String) {
        let r = try await send("GET", "api/roost/invites/\(code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code)") as! JSON
        return (r.s("family"), Role(rawValue: r.s("role")) ?? .relative, r.s("name"))
    }

    public func join(code: String, name: String?) async throws -> (family: String, membership: String) {
        var body: JSON = ["code": code]
        if let name { body["name"] = name }
        let r = try await send("POST", "api/roost/join", body: body) as! JSON
        return (r.s("family"), r.s("membership"))
    }

    public func busy(family: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        let iso = ISO8601DateFormatter()
        let r = try await send("GET", "api/roost/busy", query: [
            URLQueryItem(name: "family", value: family), URLQueryItem(name: "from", value: iso.string(from: from)), URLQueryItem(name: "to", value: iso.string(from: to)),
        ]) as! JSON
        return (r["items"] as? [JSON] ?? []).map { j in
            var e = CalendarEvent(json: j)
            e.isBusyBlock = true
            return e
        }
    }

    public func refreshSubscription(calendar: String) async throws -> (ok: Bool, error: String) {
        let r = try await send("POST", "api/roost/calendars/\(calendar)/refresh") as! JSON
        return (r.b("ok"), r.s("error"))
    }

    public func categorize(family: String, items: [String]) async throws -> [String: String] {
        let r = try await send("POST", "api/roost/categorize", body: ["family": family, "items": items]) as! JSON
        return r["categories"] as? [String: String] ?? [:]
    }

    public func feedURL(token: String) -> URL { baseURL.appendingPathComponent("api/roost/ics/\(token).ics") }

    /// Pocketbase filter literal escaping.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
}
