import Foundation
import Combine

struct WorkspaceRow: Identifiable, Equatable {
    let id: String
    var title: String
    var path: String
    var sessionIDs: [String]
    init(_ json: JSON) { id = json["workspaceId"].text; title = json["title"].text; path = json["path"].text; sessionIDs = json["sessionIds"].array.map(\.text) }
}

struct SessionRow: Identifiable, Equatable {
    let id: String
    var title: String
    var running: Bool
    var updatedAt: JSON
    var projections: JSON
    init(_ json: JSON) {
        id = json["sessionId"].text
        projections = json["projections"]["values"]
        title = projections["title"].string ?? L("New conversation", "新对话")
        running = json["running"].boolean
        updatedAt = json["updatedAt"]
    }
}

struct SessionGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let sessions: [SessionRow]
}

@MainActor
final class SidebarStore: ObservableObject {
    @Published private(set) var workspaces: [WorkspaceRow] = []
    @Published private(set) var sessions: [String: SessionRow] = [:]
    @Published private(set) var archivedIDs: [String] = []
    @Published private(set) var pinnedIDs: [String] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    private let api: RPCServing
    private var tasks: [Task<Void, Never>] = []
    init(api: RPCServing) { self.api = api }
    var groups: [SessionGroup] {
        let visible = sessions.values.filter { !archivedIDs.contains($0.id) }
        let pinned = pinnedIDs.compactMap { id in visible.first { $0.id == id } }
        let assigned = Set(workspaces.flatMap(\.sessionIDs) + pinnedIDs)
        return [SessionGroup(id: "pinned", title: L("Pinned", "置顶"), sessions: pinned)] + workspaces.map { workspace in
            SessionGroup(id: workspace.id, title: workspace.title, sessions: workspace.sessionIDs.compactMap { id in visible.first { $0.id == id && !pinnedIDs.contains(id) } })
        } + [SessionGroup(id: "ungrouped", title: L("Ungrouped", "未分组"), sessions: visible.filter { !assigned.contains($0.id) }.sorted { ($0.updatedAt.int ?? 0) > ($1.updatedAt.int ?? 0) })]
    }
    func applyWorkspace(_ frame: JSON) {
        switch frame["type"].text {
        case "connection-reset": loaded = false
        case "baseline", "replace":
            let value = frame["value"]
            workspaces = value["items"].array.map(WorkspaceRow.init)
            archivedIDs = value["archivedSessionIds"].array.map(\.text)
            pinnedIDs = value["pinnedSessionIds"].array.map(\.text)
            loaded = true
        case "upsert":
            let row = WorkspaceRow(frame["workspace"])
            if let index = workspaces.firstIndex(where: { $0.id == row.id }) { workspaces[index] = row } else { workspaces.append(row) }
        case "remove": workspaces.removeAll { $0.id == frame["workspaceId"].text }
        case "order":
            let ids = frame["workspaceIds"].array.map(\.text)
            workspaces = ids.compactMap { id in workspaces.first { $0.id == id } } + workspaces.filter { !ids.contains($0.id) }
        case "archived": archivedIDs = frame["archivedSessionIds"].array.map(\.text)
        case "pinned": pinnedIDs = frame["pinnedSessionIds"].array.map(\.text)
        default: break
        }
    }
    func applySessions(_ value: JSON) { sessions = Dictionary(value["items"].array.map { let row = SessionRow($0); return (row.id, row) }, uniquingKeysWith: { _, new in new }) }
    func applyEvent(_ frame: JSON) {
        guard frame["type"] == "emit" else { return }
        let args = frame["args"].array
        guard let first = args.first else { return }
        switch frame["event"].text {
        case "api-session/added": let row = SessionRow(first); sessions[row.id] = row
        case "api-session/removed": sessions.removeValue(forKey: first.text)
        case "api-session/status": if args.count > 1 { sessions[first.text]?.running = args[1].boolean }
        case "api-session/activity": if args.count > 1 { sessions[first.text]?.updatedAt = args[1] }
        case "api-session/error": if args.count > 1 { error = args[1].string }
        default: break
        }
    }
    func applyControl(_ frame: JSON) {
        if frame["type"] == "baseline" {
            for (id, value) in frame["projections"].object { updateProjections(id, values: value["values"]) }
        } else if frame["type"] == "projection" {
            let id = frame["sessionId"].text
            var values = sessions[id]?.projections ?? [:]
            for change in frame["changes"].array { values[change["key"].text] = change["val"] }
            updateProjections(id, values: values)
        }
    }
    private func updateProjections(_ id: String, values: JSON) {
        guard var row = sessions[id] else { return }
        row.projections = values
        row.title = values["title"].string ?? L("New conversation", "新对话")
        sessions[id] = row
    }
    func refresh() async throws { applySessions(try await api.rpc("session/list", args: ["_request": [:]])) }
    func start() {
        guard tasks.isEmpty else { return }
        for endpoint in ["workspace/follow", "session/control"] {
            let stream = api.stream(endpoint, args: [:])
            tasks.append(Task { [weak self] in
                do {
                    for try await frame in stream {
                        guard !Task.isCancelled else { break }
                        if endpoint == "workspace/follow" { self?.applyWorkspace(frame) } else { self?.applyControl(frame) }
                    }
                } catch { self?.error = error.localizedDescription }
            })
        }
    }
    func stop() { tasks.forEach { $0.cancel() }; tasks = [] }
    func createSession(workspaceID: String? = nil, cwd: String? = nil) async throws -> String {
        var request: JSON = ["agentPreset": "standard"]
        if let workspaceID { request["workspaceId"] = .string(workspaceID) }
        else if let cwd { request["cwd"] = .string(cwd) }
        let value = try await api.rpc("session/create", args: ["request": request])
        try await refresh()
        return value["sessionId"].text
    }
    func rename(_ id: String, title: String) async throws {
        let value = try await api.rpc("session/rename", args: ["request": ["sessionId": .string(id), "title": .string(title)]])
        sessions[id]?.title = value["title"].text
    }
    func archive(_ id: String) async throws {
        let value = try await api.rpc("workspace/archiveSession", args: ["request": ["sessionId": .string(id)]])
        archivedIDs = value["archivedSessionIds"].array.map(\.text)
    }
    func pin(_ id: String, pinned: Bool) async throws {
        let value = try await api.rpc(pinned ? "workspace/pinSession" : "workspace/unpinSession", args: ["request": ["sessionId": .string(id)]])
        pinnedIDs = value["pinnedSessionIds"].array.map(\.text)
    }
    deinit { tasks.forEach { $0.cancel() } }
}
