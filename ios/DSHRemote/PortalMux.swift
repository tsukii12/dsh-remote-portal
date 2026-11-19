import Foundation

@MainActor
final class PortalMux {
    struct Event {
        let value: JSON
        let generation: UUID
    }
    @MainActor final class Channel {
        let id: String
        let frames: AsyncThrowingStream<Event, Error>
        private weak var mux: PortalMux?
        fileprivate init(id: String, frames: AsyncThrowingStream<Event, Error>, mux: PortalMux) {
            self.id = id; self.frames = frames; self.mux = mux
        }
        var generation: UUID? { mux?.connectionID }
        func send(_ value: JSON, generation: UUID) async throws {
            guard let mux, mux.connectionID == generation, mux.opened.contains(id), mux.subscriptions[id] != nil else { throw APIError.disconnected }
            try await mux.send(["type": "item", "streamId": .string(id), "value": value], generation: generation)
        }
        func end(generation: UUID) async throws {
            guard let mux, mux.connectionID == generation else { throw APIError.disconnected }
            try await mux.send(["type": "end", "streamId": .string(id)], generation: generation)
        }
        func cancel() { mux?.unsubscribe(id) }
    }
    private struct Subscription {
        let endpoint: String
        let args: JSON
        let yield: (JSON, UUID) -> Void
        let finish: (Error?) -> Void
    }
    private weak var api: PortalAPI?
    private var subscriptions: [String: Subscription] = [:]
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var opened = Set<String>()
    private var runnerID = UUID()
    private var connectionID = UUID()
    init(api: PortalAPI) { self.api = api }

    func open(_ endpoint: String, args: JSON) -> AsyncThrowingStream<JSON, Error> {
        let id = UUID().uuidString
        return AsyncThrowingStream { continuation in
            register(id, endpoint: endpoint, args: args, yield: { value, _ in continuation.yield(value) }, finish: { continuation.finish(throwing: $0) })
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.unsubscribe(id) } }
        }
    }
    func openDuplex(_ endpoint: String, args: JSON) -> Channel {
        let id = UUID().uuidString
        let frames = AsyncThrowingStream<Event, Error> { continuation in
            register(id, endpoint: endpoint, args: args, yield: { value, generation in continuation.yield(Event(value: value, generation: generation)) }, finish: { continuation.finish(throwing: $0) })
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.unsubscribe(id) } }
        }
        return Channel(id: id, frames: frames, mux: self)
    }
    private func register(_ id: String, endpoint: String, args: JSON, yield: @escaping (JSON, UUID) -> Void, finish: @escaping (Error?) -> Void) {
        subscriptions[id] = Subscription(endpoint: endpoint, args: args, yield: yield, finish: finish)
        if receiver == nil {
            let token = UUID(); runnerID = token
            receiver = Task { [weak self] in await self?.run(token) }
        } else if socket != nil { Task { try? await self.sendOpen(id) } }
    }
    private func unsubscribe(_ id: String) {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        subscription.finish(nil)
        opened.remove(id)
        Task { try? await send(["type": "cancel", "streamId": .string(id)]) }
        if subscriptions.isEmpty { receiver?.cancel(); receiver = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
    }
    func close() {
        connectionID = UUID()
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; opened.removeAll()
        let existing = subscriptions; subscriptions.removeAll()
        for subscription in existing.values { subscription.finish(APIError.sessionExpired) }
    }
    func sendItem(_ value: JSON, streamId: String) async throws { try await send(["type": "item", "streamId": .string(streamId), "value": value]) }
    func endInput(streamId: String) async throws { try await send(["type": "end", "streamId": .string(streamId)]) }
    func reconnect() { connectionID = UUID(); socket?.cancel(with: .goingAway, reason: nil) }
    private func send(_ frame: JSON, generation: UUID? = nil) async throws {
        guard generation == nil || generation == connectionID, let socket else { throw APIError.disconnected }
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
                for subscription in remaining.values { subscription.finish(APIError.disconnected) }
            }
        }
        var failures = 0
        while !Task.isCancelled && !subscriptions.isEmpty {
            guard var request = api?.request("api/remote.mux"), let client = api?.client, let base = api?.base else { break }
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.scheme = url.scheme == "https" ? "wss" : "ws"
            request.url = url.url
            let task = client.session.webSocketTask(with: request)
            connectionID = UUID()
            let generation = connectionID
            socket = task; opened.removeAll()
            // URLSessionWebSocketTask handles incoming protocol pings with pongs.
            task.resume()
            do {
                for id in Array(subscriptions.keys) { try await sendOpen(id) }
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard runnerID == token, !Task.isCancelled, socket === task else { return }
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
                    case "item": subscription.yield(frame["value"], generation)
                    case "end": subscriptions.removeValue(forKey: id); subscription.finish(nil)
                    case "error":
                        subscriptions.removeValue(forKey: id)
                        subscription.finish(APIError.remote(frame["error"]["code"].text, frame["error"]["message"].text))
                    default: break
                    }
                    if subscriptions.isEmpty { break }
                }
            } catch {
                guard runnerID == token, !Task.isCancelled else { return }
                connectionID = UUID()
                for subscription in subscriptions.values { subscription.yield(["type": "connection-reset"], connectionID) }
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
