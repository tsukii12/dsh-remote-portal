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
    var blank: Bool
    var topLevel: Bool
    var parentID: String?
    init(_ json: JSON) {
        id = json["sessionId"].text
        projections = json["projections"]["values"]
        title = projections["title"].string ?? L("New conversation", "新对话")
        running = json["running"].boolean
        updatedAt = json["updatedAt"]
        blank = json["blank"] == true
        topLevel = json["parentSessionId"].string == nil && json["origin"] != "subagent"
        parentID = json["parentSessionId"].string
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
    @Published var searchText = "" { didSet { if oldValue != searchText { searchResults = [] } } }
    @Published var archivedOnly = false
    @Published private(set) var searchResults: [JSON] = []
    private let api: RPCServing
    private var tasks: [Task<Void, Never>] = []
    private var createdIDs = Set<String>()
    init(api: RPCServing) { self.api = api }
    var groups: [SessionGroup] {
        guard loaded else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let foundIDs = Set(searchResults.compactMap { $0["sessionId"].string })
        let visible = sessions.values.filter {
            $0.topLevel && archivedIDs.contains($0.id) == archivedOnly && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || foundIDs.contains($0.id))
        }
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
            let baseline = frame["value"] == .null ? frame : frame["value"]
            for (id, value) in baseline["projections"].object { updateProjections(id, values: value["values"]) }
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
    func stop() { tasks.forEach { $0.cancel() }; tasks = []; loaded = false }
    func createSession(workspaceID: String? = nil, cwd: String? = nil) async throws -> String {
        var request: JSON = ["agentPreset": "standard"]
        if let workspaceID { request["workspaceId"] = .string(workspaceID) }
        else if let cwd { request["cwd"] = .string(cwd) }
        let value = try await api.rpc("session/create", args: ["request": request])
        if let id = value["sessionId"].string { createdIDs.insert(id) }
        try await refresh()
        return value["sessionId"].text
    }
    func abandonEmptyCreated(_ id: String) async throws {
        guard createdIDs.remove(id) != nil else { return }
        do { try await archiveEmpty(ids: [id]) }
        catch { createdIDs.insert(id); throw error }
    }
    func cleanEmptySessions() async throws {
        try await refresh()
        try await archiveEmpty(ids: sessions.values.filter { $0.topLevel && $0.blank && !$0.running && !archivedIDs.contains($0.id) }.map(\.id))
    }
    private func archiveEmpty(ids: [String]) async throws {
        try await refresh()
        for id in ids {
            guard let row = sessions[id], row.topLevel, row.blank, !row.running, !archivedIDs.contains(id) else { continue }
            let state = try await api.rpc("session/state", args: ["request": ["sessionId": .string(id)]])
            guard state["running"] == false, state["queue"].array.isEmpty, state["pendingInput"].array.isEmpty else { continue }
            try await archive(id)
        }
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
    func search(_ query: String) async throws {
        searchResults = []
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let value = try await api.rpc("session/search", args: ["request": ["query": .string(query)]])
        guard searchText == query else { return }
        searchResults = value["items"].array
    }
    func clearSearchResults() { searchResults = [] }
    func unarchive(_ id: String) async throws {
        let value = try await api.rpc("workspace/unarchiveSession", args: ["request": ["sessionId": .string(id)]])
        archivedIDs = value["archivedSessionIds"].array.map(\.text)
    }
    func createWorkspace(path: String) async throws {
        let value = try await api.rpc("workspace/create", args: ["request": ["path": .string(path)]])
        applyWorkspace(["type": "upsert", "workspace": value["workspace"]])
    }
    func renameWorkspace(_ id: String, title: String) async throws {
        let value = try await api.rpc("workspace/rename", args: ["request": ["workspaceId": .string(id), "title": .string(title)]])
        applyWorkspace(["type": "upsert", "workspace": value["workspace"]])
    }
    func deleteWorkspace(_ id: String) async throws {
        _ = try await api.rpc("workspace/delete", args: ["request": ["workspaceId": .string(id)]])
        workspaces.removeAll { $0.id == id }
    }
    func folders(path: String = "") async throws -> JSON {
        try await api.portal("fs", query: path.isEmpty ? [] : [URLQueryItem(name: "path", value: path)], body: nil)["listing"]
    }
    func makeFolder(parent: String, name: String) async throws -> JSON {
        try await api.portal("fs/mkdir", query: [], body: ["parent": .string(parent), "name": .string(name)])["created"]
    }
    deinit { tasks.forEach { $0.cancel() } }
}
