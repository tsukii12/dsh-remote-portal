import Foundation

@MainActor
final class PortalMux {
    private struct Subscription {
        let endpoint: String
        let args: JSON
        let continuation: AsyncThrowingStream<JSON, Error>.Continuation
    }
    private weak var api: PortalAPI?
    private var subscriptions: [String: Subscription] = [:]
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var opened = Set<String>()
    private var runnerID = UUID()
    init(api: PortalAPI) { self.api = api }

    func open(_ endpoint: String, args: JSON) -> AsyncThrowingStream<JSON, Error> {
        let id = UUID().uuidString
        return AsyncThrowingStream { continuation in
            subscriptions[id] = Subscription(endpoint: endpoint, args: args, continuation: continuation)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.unsubscribe(id) } }
            if receiver == nil {
                let token = UUID(); runnerID = token
                receiver = Task { [weak self] in await self?.run(token) }
            }
            else if socket != nil { Task { try? await self.sendOpen(id) } }
        }
    }
    private func unsubscribe(_ id: String) {
        guard subscriptions.removeValue(forKey: id) != nil else { return }
        opened.remove(id)
        Task { try? await send(["type": "cancel", "streamId": .string(id)]) }
        if subscriptions.isEmpty { receiver?.cancel(); receiver = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
    }
    func close() {
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; opened.removeAll()
        let existing = subscriptions; subscriptions.removeAll()
        for subscription in existing.values { subscription.continuation.finish(throwing: APIError.sessionExpired) }
    }
    func sendItem(_ value: JSON, streamId: String) async throws { try await send(["type": "item", "streamId": .string(streamId), "value": value]) }
    func endInput(streamId: String) async throws { try await send(["type": "end", "streamId": .string(streamId)]) }
    func reconnect() { socket?.cancel(with: .goingAway, reason: nil) }
    private func send(_ frame: JSON) async throws {
        guard let socket else { throw APIError.disconnected }
        let data = try JSONEncoder().encode(frame)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func sendOpen(_ id: String) async throws {
        guard let subscription = subscriptions[id], opened.insert(id).inserted else { return }
        try await send(["type": "open", "streamId": .string(id), "endpoint": .string(subscription.endpoint), "payload": ["args": subscription.args]])
    }
    private func run(_ token: UUID) async {
        defer {
            if runnerID == token {
                receiver = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil
                let remaining = subscriptions; subscriptions.removeAll()
                for subscription in remaining.values { subscription.continuation.finish(throwing: APIError.disconnected) }
            }
        }
        var failures = 0
        while !Task.isCancelled && !subscriptions.isEmpty {
            guard var request = api?.request("api/remote.mux"), let client = api?.client, let base = api?.base else { break }
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.scheme = url.scheme == "https" ? "wss" : "ws"
            request.url = url.url
            let task = client.session.webSocketTask(with: request)
            socket = task; opened.removeAll()
            // URLSessionWebSocketTask handles incoming protocol pings with pongs.
            task.resume()
            do {
                for id in Array(subscriptions.keys) { try await sendOpen(id) }
                while !Task.isCancelled {
                    let message = try await task.receive()
                    if let http = task.response as? HTTPURLResponse { try client.cookies.ingest(http, base: base) }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    let frame = try JSONDecoder().decode(JSON.self, from: data)
                    failures = 0
                    let id = frame["streamId"].text
                    guard let subscription = subscriptions[id] else { continue }
                    switch frame["type"].text {
                    case "item": subscription.continuation.yield(frame["value"])
                    case "end": subscriptions.removeValue(forKey: id); subscription.continuation.finish()
                    case "error":
                        subscriptions.removeValue(forKey: id)
                        subscription.continuation.finish(throwing: APIError.remote(frame["error"]["code"].text, frame["error"]["message"].text))
                    default: break
                    }
                    if subscriptions.isEmpty { break }
                }
            } catch {
                for subscription in subscriptions.values { subscription.continuation.yield(["type": "connection-reset"]) }
                if let http = task.response as? HTTPURLResponse {
                    try? client.cookies.ingest(http, base: base)
                    if http.statusCode == 401 { api?.expire(); return }
                }
            }
            task.cancel(with: .goingAway, reason: nil)
            if socket === task { socket = nil }
            guard !Task.isCancelled && !subscriptions.isEmpty else { break }
            failures += 1
            do { try await Task.sleep(nanoseconds: UInt64(min(30, pow(2, Double(min(failures - 1, 5))))) * 1_000_000_000) }
            catch { break }
        }
    }
}
