import Foundation
import Combine

struct PendingInteraction: Identifiable, Equatable {
    let id: String
    let clientID: String
    let agentID: String
    let kind: String
    let request: JSON
}

struct InteractionRouting {
    private(set) var presentedID: String?
    private(set) var deferred: Set<String> = []
    static func sessionID(_ item: PendingInteraction, knownSessionIDs: Set<String>) -> String? {
        let id = item.agentID
        return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && knownSessionIDs.contains(id) ? id : nil
    }
    static func forSession(_ pending: [PendingInteraction], sessionID: String?) -> [PendingInteraction] {
        guard let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return pending.filter { $0.agentID == sessionID }
    }
    static func label(_ pending: [PendingInteraction], languages: [String] = Locale.preferredLanguages) -> String {
        let count = pending.count
        if pending.allSatisfy({ $0.kind == "approval/request" }) {
            return L("\(count) pending approval\(count == 1 ? "" : "s")", "\(count) 个待处理授权", languages: languages)
        }
        if pending.allSatisfy({ $0.kind == "user-questions/request" }) {
            return L("\(count) pending question\(count == 1 ? "" : "s")", "\(count) 个待回答问题", languages: languages)
        }
        return L("\(count) pending request\(count == 1 ? "" : "s")", "\(count) 个待处理请求", languages: languages)
    }
    mutating func reconcile(_ pending: [PendingInteraction], openSessionID: String?) {
        deferred.formIntersection(Set(pending.map(\.id)))
        guard !pending.contains(where: { $0.id == presentedID }) else { return }
        presentedID = Self.forSession(pending, sessionID: openSessionID).first { !deferred.contains($0.id) }?.id
    }
    mutating func dismiss() {
        if let presentedID { deferred.insert(presentedID) }
        presentedID = nil
    }
    mutating func review(_ item: PendingInteraction) { presentedID = item.id }
}

@MainActor
final class RemoteEvents: ObservableObject {
    @Published private(set) var clientID: String?
    @Published private(set) var pending: [PendingInteraction] = []
    @Published private(set) var error: String?
    private let api: RPCServing
    private var task: Task<Void, Never>?
    private var listeners: [UUID: (JSON) -> Void] = [:]
    private var resolved: Set<String> = []
    init(api: RPCServing) { self.api = api }
    func observe(_ handler: @escaping (JSON) -> Void) -> UUID { let id = UUID(); listeners[id] = handler; return id }
    func removeObserver(_ id: UUID) { listeners.removeValue(forKey: id) }
    func apply(_ frame: JSON) {
        switch frame["type"].text {
        case "ready": clientID = frame["clientId"].string; pending = []
        case "connection-reset": clientID = nil; pending = []
        case "cancel":
            resolved.insert(frame["eventId"].text)
            pending.removeAll { $0.id == frame["eventId"].text }
        case "waterfall":
            guard let clientID, !resolved.contains(frame["eventId"].text), ["approval/request", "user-questions/request"].contains(frame["event"].text) else { break }
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
        resolved.insert(id)
        pending.removeAll { $0.id == id }
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
