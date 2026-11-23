import Foundation
import RoostKit

/// PocketBase realtime over Server-Sent Events, with automatic reconnect.
/// Protocol: GET /api/realtime → "PB_CONNECT" {clientId} → POST /api/realtime
/// {clientId, subscriptions} → events named after the topic with {action, record}.
final class RealtimeClient: @unchecked Sendable {
    let baseURL: URL
    let token: () -> String?
    let topics: [String]
    private var task: Task<Void, Never>?

    init(baseURL: URL, token: @escaping () -> String?, topics: [String]) {
        self.baseURL = baseURL
        self.token = token
        self.topics = topics
    }

    func start(onMessage: @escaping @MainActor (String, String, JSON) -> Void, onReconnect: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task.detached { [weak self] in
            var delay: UInt64 = 2
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.connect(onMessage: onMessage, onConnected: {
                        if !first { await onReconnect() }
                        first = false
                        delay = 2
                    })
                } catch {
                    // fall through to retry
                }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 60)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func connect(onMessage: @escaping @MainActor (String, String, JSON) -> Void, onConnected: @escaping () async -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/realtime"))
        req.timeoutInterval = 60 * 60
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        var line = [UInt8]()
        var event = ""
        var data = ""
        for try await byte in bytes {
            if Task.isCancelled { return }
            if byte != UInt8(ascii: "\n") { line.append(byte); continue }
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                // Dispatch one SSE event.
                if event == "PB_CONNECT" {
                    let j = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? JSON ?? [:]
                    try await subscribe(clientId: j.s("clientId"))
                    await onConnected()
                } else if !event.isEmpty, let j = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? JSON {
                    let action = j.s("action")
                    let record = j["record"] as? JSON ?? [:]
                    let topic = event
                    await MainActor.run { onMessage(topic, action, record) }
                }
                event = ""
                data = ""
            } else if text.hasPrefix("event:") {
                event = text.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("data:") {
                data += (data.isEmpty ? "" : "\n") + text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func subscribe(clientId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/realtime"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = token() { req.setValue(t, forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["clientId": clientId, "subscriptions": topics])
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { throw URLError(.userAuthenticationRequired) }
    }
}
