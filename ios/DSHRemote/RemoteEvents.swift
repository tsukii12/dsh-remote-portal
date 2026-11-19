import Foundation
import Combine

struct PendingInteraction: Identifiable, Equatable {
    let id: String
    let clientID: String
    let agentID: String
    let kind: String
    let request: JSON
}

@MainActor
final class RemoteEvents: ObservableObject {
    @Published private(set) var clientID: String?
    @Published private(set) var pending: [PendingInteraction] = []
    @Published private(set) var error: String?
    private let api: RPCServing
    private var task: Task<Void, Never>?
    private var listeners: [UUID: (JSON) -> Void] = [:]
    init(api: RPCServing) { self.api = api }
    func observe(_ handler: @escaping (JSON) -> Void) -> UUID { let id = UUID(); listeners[id] = handler; return id }
    func removeObserver(_ id: UUID) { listeners.removeValue(forKey: id) }
    func apply(_ frame: JSON) {
        switch frame["type"].text {
        case "ready": clientID = frame["clientId"].string; pending = []
        case "connection-reset": clientID = nil; pending = []
        case "cancel": pending.removeAll { $0.id == frame["eventId"].text }
        case "waterfall":
            guard let clientID, ["approval/request", "user-questions/request"].contains(frame["event"].text) else { break }
            let item = PendingInteraction(id: frame["eventId"].text, clientID: clientID, agentID: frame["agentId"].text, kind: frame["event"].text, request: frame["request"])
            pending.removeAll { $0.id == item.id }; pending.append(item)
        default: break
        }
        for handler in Array(listeners.values) { handler(frame) }
    }
    func start() {
        guard task == nil else { return }
        let stream = api.stream("$events", args: [:])
        task = Task { [weak self] in
            do { for try await frame in stream { if Task.isCancelled { break }; self?.apply(frame) } }
            catch { self?.apply(["type": "connection-reset"]); self?.error = error.localizedDescription }
        }
    }
    func stop() { task?.cancel(); task = nil; apply(["type": "connection-reset"]) }
    func answerApproval(_ id: String, allow: Bool) async throws { try await answer(id, value: .string(allow ? "allowed-once" : "rejected")) }
    func answerQuestions(_ id: String, answers: [JSON]) async throws { try await answer(id, value: ["answers": .array(answers)]) }
    private func answer(_ id: String, value: JSON) async throws {
        guard let item = pending.first(where: { $0.id == id }), let clientID, item.clientID == clientID else { throw APIError.disconnected }
        _ = try await api.rpc("$events/result", args: ["clientId": .string(clientID), "eventId": .string(id), "outcome": ["kind": "result", "value": value]])
        pending.removeAll { $0.id == id && $0.clientID == clientID }
    }
    deinit { task?.cancel() }
}

@MainActor
final class NativeConnection: ObservableObject {
    let api: PortalAPI
    let sidebar: SidebarStore
    let events: RemoteEvents
    private var observer: UUID?
    @Published private(set) var error: String?
    init(api: PortalAPI) { self.api = api; sidebar = SidebarStore(api: api); events = RemoteEvents(api: api) }
    func start() async throws {
        try await sidebar.refresh()
        sidebar.start()
        if observer == nil {
            observer = events.observe { [weak self] frame in
                self?.sidebar.applyEvent(frame)
                if frame["type"] == "ready" {
                    Task { [weak self] in do { try await self?.sidebar.refresh() } catch { self?.error = error.localizedDescription } }
                }
            }
        }
        events.start()
    }
    func stop() { sidebar.stop(); events.stop(); if let observer { events.removeObserver(observer) }; observer = nil; api.mux.close() }
    func chat(_ sessionID: String) -> ChatStore { ChatStore(sessionID: sessionID, api: api, events: events) }
}
