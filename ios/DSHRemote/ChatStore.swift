import Foundation
import Combine

struct TranscriptBlock: Equatable {
    var kind: String
    var text = ""
    var callID = ""
    var name = ""
    var arguments = ""
    var result: JSON?
    var attachment: JSON = .null
    var raw: JSON = .null
    init(_ value: JSON) {
        kind = value["type"].text; text = value["text"].text
        callID = value["id"].text; name = value["name"].text
        arguments = value["arguments"].string ?? (value["arguments"] == .null ? "" : value["arguments"].formatted)
        attachment = value["attachment"]
        raw = value
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.callID == rhs.callID && lhs.name == rhs.name && lhs.arguments == rhs.arguments && lhs.result == rhs.result && lhs.attachment == rhs.attachment && (["text", "reasoning", "tool-call", "image", "file"].contains(lhs.kind) || lhs.raw == rhs.raw)
    }
}

struct TranscriptItem: Identifiable, Equatable {
    let id: String
    var role: String
    var blocks: [TranscriptBlock]
    var seq: Int?
    var requestID: String?
    var optimistic = false
    var deliveryError: String?
    var inProgress = false
    var turn: Int?
    var step: Int?
    var text: String { blocks.filter { $0.kind == "text" || role == "notice" }.map(\.text).joined() }
}

enum CompactStream {
    static func expand(_ records: [JSON]) -> [JSON] {
        records.flatMap { record -> [JSON] in
            switch record["type"].text {
            case "chunk": return [record["chunk"]]
            case "text-chunks", "reasoning-chunks":
                return record["texts"].array.map { ["type": record["type"] == "text-chunks" ? "text-delta" : "reasoning-delta", "index": record["index"], "text": $0] }
            case "tool-call-chunks":
                return record["args"].array.enumerated().map { index, argument in
                    var chunk: JSON = ["type": "tool-call-delta", "index": record["index"], "id": record["id"], "argumentsDelta": argument]
                    if index == 0 { chunk["name"] = record["name"] }
                    return chunk
                }
            default: return []
            }
        }
    }
    static func apply(_ chunk: JSON, to blocks: inout [TranscriptBlock]) {
        guard let index = chunk["index"].int, index >= 0, index < 4096 else { return }
        while blocks.count <= index { blocks.append(TranscriptBlock(["type": "unknown"])) }
        switch chunk["type"].text {
        case "block-start": blocks[index] = TranscriptBlock(["type": chunk["blockType"]])
        case "text-delta", "reasoning-delta":
            blocks[index].kind = chunk["type"] == "text-delta" ? "text" : "reasoning"
            blocks[index].text += chunk["text"].text
        case "tool-call-delta":
            blocks[index].kind = "tool-call"
            if let id = chunk["id"].string { blocks[index].callID = id }
            if let name = chunk["name"].string { blocks[index].name = name }
            blocks[index].arguments += chunk["argumentsDelta"].text
        case "block-end": blocks[index] = TranscriptBlock(chunk["block"])
        default: break
        }
    }
}

@MainActor
final class ChatStore: ObservableObject {
    let sessionID: String
    @Published private(set) var transcript: [TranscriptItem] = []
    @Published private(set) var inProgress: TranscriptItem?
    @Published private(set) var running = false
    @Published private(set) var hasMore = false
    @Published private(set) var loaded = false
    @Published private(set) var catalog: JSON = [:]
    @Published private(set) var selectedModel: JSON = [:]
    @Published private(set) var projections: JSON = [:]
    @Published private(set) var turnUsage: [Int: JSON] = [:]
    @Published private(set) var queue: [JSON] = []
    @Published private(set) var permissionCatalog: JSON = [:]
    @Published private(set) var presetCatalog: JSON = [:]
    @Published private(set) var commands: [JSON] = []
    @Published private(set) var commandNotice: String?
    @Published private(set) var exportedFile: URL?
    @Published private(set) var error: String?
    let api: RPCServing
    private weak var events: RemoteEvents?
    private var observer: UUID?
    private var followTask: Task<Void, Never>?
    private var controlTasks: [Task<Void, Never>] = []
    private var projectionCursor = -1
    private var history: [Int: JSON] = [:]
    private var optimistic: [TranscriptItem] = []
    private var snapshotCursor: Int?
    private var attemptID: String?
    private var revision = -1
    private var nextIndex = 0
    private var pendingCommitSeq: Int?
    private var startupTask: Task<Void, Never>?
    private var startupID: UUID?
    private var recoveryTask: Task<Void, Never>?
    private var stateRevision = 0
    let isDraft: Bool
    private let transcriptAddress: JSON?
    init(sessionID: String, api: RPCServing, events: RemoteEvents? = nil, isDraft: Bool = false, address: JSON? = nil) {
        self.sessionID = sessionID; self.api = api; self.events = events; self.isDraft = isDraft; transcriptAddress = address
        if isDraft { projections["agentPreset"] = "standard" }
    }
    private var address: JSON { transcriptAddress ?? ["kind": "session", "sessionId": .string(sessionID)] }

    func activate() {
        guard !isDraft else { return }
        guard startupTask == nil else { return }
        let id = UUID(); startupID = id; error = nil
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.startupID == id { self.startupTask = nil } }
            do {
                try await self.start()
                try Task.checkCancellation()
            } catch {
                if !Task.isCancelled { self.stop(); self.error = error.localizedDescription }
                return
            }
            do { try await self.loadModels() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            guard !Task.isCancelled else { return }
            do { try await self.loadControls() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    func start() async throws {
        if followTask != nil { try await reconcile(loadHistory: false); return }
        if let events {
            observer = events.observe { [weak self] frame in self?.applyStatusEvent(frame) }
        }
        followTask = observe("session/follow", args: ["request": ["address": address, "assistantStream": true, "maxMessages": 50]])
        for endpoint in ["session/control", "session/observeState"] {
            controlTasks.append(observe(endpoint, args: endpoint == "session/control" ? [:] : ["request": ["sessionId": .string(sessionID)]]))
        }
        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if self.running || !self.optimistic.isEmpty || !self.loaded { try await self.reconcile() }
                } catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
            }
        }
        do { try await reconcile(loadHistory: false) }
        catch {
            try Task.checkCancellation()
            self.error = error.localizedDescription
        }
    }
    private func observe(_ endpoint: String, args: JSON) -> Task<Void, Never> {
        let api = api
        let frames = api.stream(endpoint, args: args)
        return Task { [weak self] in
            var stream = frames
            while !Task.isCancelled {
                do {
                    for try await frame in stream {
                        guard !Task.isCancelled else { return }
                        if endpoint == "session/follow" { self?.apply(frame) }
                        else if endpoint == "session/control" { self?.applyControl(frame) }
                        else if frame["type"] != "connection-reset" { self?.applyState(frame) }
                    }
                } catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                stream = api.stream(endpoint, args: args)
            }
        }
    }
    func reconcile(loadHistory: Bool = true) async throws {
        let version = stateRevision
        let state = try await api.rpc("session/state", args: ["request": ["sessionId": .string(sessionID)]])
        guard !Task.isCancelled else { return }
        if version == stateRevision { applyState(state) }
        if loadHistory && (!loaded || (!running && (!optimistic.isEmpty || inProgress != nil))) {
            let page = try await api.rpc("session/events", args: ["request": ["address": address, "maxMessages": 50]])
            if !loaded, !Task.isCancelled, page["records"] != .null {
                var snapshot = page; snapshot["type"] = "snapshot"
                apply(snapshot)
            } else if !Task.isCancelled {
                for record in page["records"].array { apply(record) }
                if !running { inProgress = nil; attemptID = nil; pendingCommitSeq = nil }
            }
        }
    }
    func stop() {
        startupID = nil; startupTask?.cancel(); startupTask = nil
        followTask?.cancel(); followTask = nil
        controlTasks.forEach { $0.cancel() }; controlTasks = []
        recoveryTask?.cancel(); recoveryTask = nil
        if let observer { events?.removeObserver(observer) }; observer = nil
    }
    func applyState(_ state: JSON) {
        guard state["running"] == true || state["running"] == false else { return }
        stateRevision += 1
        running = state["running"].boolean
        queue = state["queue"].array
        rebuild()
    }
    func applyControl(_ frame: JSON) {
        if frame["type"] == "connection-reset" { projectionCursor = -1; return }
        if frame["type"] == "baseline" {
            let snapshot = frame["value"]["projections"][sessionID]
            if snapshot != .null { applyProjections(snapshot) }
        } else if frame["type"] == "projection", frame["sessionId"].text == sessionID {
            guard let seq = frame["seq"].int, seq >= projectionCursor else { return }
            projectionCursor = seq
            var values = projections
            for change in frame["changes"].array { values[change["key"].text] = change["val"] }
            projections = values; selectedModel = values["modelSelection"]
        }
    }
    func applyProjections(_ snapshot: JSON) {
        let cursor = snapshot["asOfSeq"].int ?? -1
        guard cursor >= projectionCursor else { return }
        projectionCursor = cursor
        projections = snapshot["values"]; selectedModel = projections["modelSelection"]
    }
    func applyStatusEvent(_ frame: JSON) {
        if frame["type"] == "ready" {
            Task { [weak self] in
                guard let self else { return }
                do { try await self.reconcile() }
                catch { self.error = error.localizedDescription }
            }
        }
        let args = frame["args"].array
        if frame["type"] == "emit", frame["event"] == "api-session/status", args.count > 1, args[0].text == sessionID { stateRevision += 1; running = args[1].boolean }
    }
    func apply(_ frame: JSON) {
        switch frame["type"].text {
        case "connection-reset":
            inProgress = nil; attemptID = nil; revision = -1; pendingCommitSeq = nil; loaded = false
        case "snapshot":
            history = [:]
            snapshotCursor = frame["cursor"].int
            hasMore = frame["hasMore"].boolean
            applyProjections(frame["projections"])
            for record in frame["records"].array { if let seq = record["event"]["seq"].int { history[seq] = record["event"] } }
            inProgress = nil; attemptID = nil; pendingCommitSeq = nil
            let baseline = frame["assistantStream"]
            revision = baseline["revision"].int ?? -1
            if baseline["activeAttempt"] != .null {
                let attempt = baseline["activeAttempt"]
                begin(attempt)
                nextIndex = attempt["nextIndex"].int ?? 0
                var blocks: [TranscriptBlock] = []
                for chunk in CompactStream.expand(attempt["stream"].array) { CompactStream.apply(chunk, to: &blocks) }
                inProgress?.blocks = blocks
            }
            loaded = true; rebuild()
        case "event":
            let event = frame["event"]
            if let seq = event["seq"].int {
                history[seq] = event
                if seq == pendingCommitSeq || (event["type"] == "assistant/message" && event["data"]["turn"].int == inProgress?.turn && event["data"]["step"].int == inProgress?.step) { inProgress = nil; pendingCommitSeq = nil }
                rebuild()
            }
        case "assistant-stream": applyAssistant(frame["frame"])
        default: break
        }
    }
    private func begin(_ frame: JSON) {
        attemptID = frame["attemptId"].text; nextIndex = 0; pendingCommitSeq = nil
        inProgress = TranscriptItem(id: "attempt:" + frame["attemptId"].text, role: "assistant", blocks: [], inProgress: true, turn: frame["turn"].int, step: frame["step"].int)
    }
    private func applyAssistant(_ frame: JSON) {
        guard let newRevision = frame["revision"].int, newRevision > revision else { return }
        revision = newRevision
        switch frame["type"].text {
        case "start": begin(frame)
        case "chunk":
            guard frame["attemptId"].text == attemptID, let index = frame["index"].int, index >= nextIndex else { return }
            nextIndex = index + 1
            var blocks = inProgress?.blocks ?? []
            CompactStream.apply(frame["chunk"], to: &blocks)
            inProgress?.blocks = blocks
        case "end":
            guard frame["attemptId"].text == attemptID else { return }
            if frame["outcome"]["kind"] == "abandoned" { inProgress = nil; attemptID = nil }
            else if let seq = frame["outcome"]["seq"].int {
                pendingCommitSeq = seq
                if history[seq] != nil || frame["outcome"]["eventType"] == "assistant/attempt" { inProgress = nil; pendingCommitSeq = nil }
            }
            Task { [weak self] in try? await self?.reconcile() }
        default: break
        }
    }
    func addOptimistic(text: String, requestID: String, attachments: [JSON] = []) {
        let content: [JSON] = (text.isEmpty ? [] : [["type": "text", "text": .string(text)]]) + attachments
        optimistic.append(TranscriptItem(id: "request:" + requestID, role: "user", blocks: content.map(TranscriptBlock.init), requestID: requestID, optimistic: true))
        rebuild()
    }
    private func rebuild() {
        turnUsage = TurnUsage.byTurn(history.sorted(by: { $0.key < $1.key }).map(\.value))
        var surface: [JSON] = []
        for event in history.sorted(by: { $0.key < $1.key }).map(\.value) {
            if ["step/start", "step/end", "turn/start", "request/header", "request/context", "session/title", "session/title-llm-request", "job/registered", "job/settled", "agent/inbox/spliced", "workspace/changes"].contains(event["type"].text) { continue }
            if event["type"] == "turn/end", event["data"]["reason"]["kind"] == "completed" { continue }
            let op = event["surfaceOp"]
            if op["op"] == "replace", let start = surface.firstIndex(where: { $0["seq"] == op["startSeq"] }), let end = surface.firstIndex(where: { $0["seq"] == op["endSeq"] }), start <= end {
                surface.replaceSubrange(start...end, with: [event])
            } else { surface.append(event) }
        }
        let committedRequests = Set(history.values.filter { $0["type"] == "user/message" }.compactMap { $0["data"]["source"]["rpcId"].string })
        optimistic.removeAll { $0.requestID.map(committedRequests.contains) ?? false }
        var items: [TranscriptItem] = []
        var results: [JSON] = []
        let representedCalls = Set(surface.flatMap { $0["data"]["message"]["content"].array }.filter { $0["type"] == "tool-call" }.compactMap { $0["id"].string })
        for event in surface {
            let type = event["type"].text
            let data = event["data"]
            if type == "tool/result" { results.append(event); continue }
            if type == "tool/call", representedCalls.contains(data["callId"].text) { continue }
            let message = type == "user/message" ? data : data["message"]
            var blocks = message["content"].array.map(TranscriptBlock.init)
            if blocks.isEmpty && ["assistant/message", "assistant/attempt"].contains(type) {
                for chunk in CompactStream.expand(data["stream"].array) { CompactStream.apply(chunk, to: &blocks) }
            }
            if type == "tool/call" { blocks = [TranscriptBlock(["type": "tool-call", "id": data["callId"], "name": data["name"], "arguments": data["arguments"]])] }
            let role: String
            if type == "user/message", message["source"]["kind"] == .null || message["source"]["kind"] == "user" { role = "user" }
            else if ["assistant/message", "assistant/attempt", "tool/call"].contains(type) { role = "assistant" }
            else { role = "notice" }
            if role == "notice" {
                blocks = [TranscriptBlock(["type": .string(type), "text": .string(blocks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")), "event": event])]
            }
            items.append(TranscriptItem(id: "seq:\(event["seq"].int ?? 0)", role: role, blocks: blocks, seq: event["seq"].int, requestID: message["source"]["rpcId"].string, turn: data["turn"].int, step: data["step"].int))
        }
        for result in results {
            let message = result["data"]["message"]
            let call = message["toolCallId"].text
            if let item = items.lastIndex(where: { $0.blocks.contains { $0.kind == "tool-call" && $0.callID == call } }), let block = items[item].blocks.firstIndex(where: { $0.callID == call && $0.kind == "tool-call" }) {
                items[item].blocks[block].result = result["data"]
            } else {
                items.append(TranscriptItem(id: "result:\(result["seq"].int ?? 0)", role: "tool", blocks: message["content"].array.map(TranscriptBlock.init), seq: result["seq"].int))
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: surface.enumerated().compactMap { index, event in event["seq"].int.map { ($0, index) } })
        let queuedRequests = Set(queue.compactMap { $0["rpcId"].string })
        transcript = items.sorted { (positions[$0.seq ?? -1] ?? 0) < (positions[$1.seq ?? -1] ?? 0) } + optimistic.filter { !queuedRequests.contains($0.requestID ?? "") }
    }
    @discardableResult
    func send(_ text: String, steer: Bool = false, attachments: [DraftAttachment] = [], requestID: String? = nil) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { throw PortalError.message(L("Enter a message.", "请输入消息。")) }
        guard attachments.allSatisfy(\.ready) else { throw PortalError.message(L("Wait for all uploads to finish or remove failed attachments.", "请等待所有上传完成，或移除失败的附件。")) }
        try validateImageInput(attachments)
        let id = requestID ?? UUID().uuidString
        addOptimistic(text: text, requestID: id, attachments: attachments.map(\.reference))
        do {
            let content: [JSON] = (text.isEmpty ? [] : [["type": "text", "text": .string(text)]]) + attachments.map(\.content)
            _ = try await api.rpc("session/prompt", args: ["request": ["sessionId": .string(sessionID), "requestId": .string(id), "mode": steer && running ? "steer" : "queue", "content": .array(content), "clientTimeZone": .string(TimeZone.current.identifier)]])
            return id
        } catch {
            if let index = optimistic.firstIndex(where: { $0.requestID == id }) { optimistic[index].deliveryError = error.localizedDescription }
            rebuild(); throw error
        }
    }
    func usage(for item: TranscriptItem) -> JSON? {
        guard item.role == "assistant", let turn = item.turn,
              transcript.last(where: { $0.role == "assistant" && $0.turn == turn })?.id == item.id else { return nil }
        return turnUsage[turn]
    }
    func cancel() async throws { _ = try await api.rpc("session/cancel", args: ["request": ["sessionId": .string(sessionID)]]) }
    func loadModels() async throws { catalog = try await api.rpc("session/modelCatalog", args: [:]) }
    var currentModel: JSON {
        for key in ["selected", "next", "lastUsed"] where selectedModel[key]["model"].string != nil { return selectedModel[key] }
        return catalog["default"]
    }
    var modelDefinition: JSON {
        catalog["groups"].array.first { $0["id"] == currentModel["provider"] }?["models"].array.first { $0["id"] == currentModel["model"] } ?? [:]
    }
    var imageInputError: String? {
        let modalities = modelDefinition["inputModalities"]
        guard modalities != .null, !modalities.array.contains("image") else { return nil }
        return L("This model does not accept images. Choose an image-capable model or remove the images.", "当前模型不支持图片。请选择支持图片的模型或移除图片。")
    }
    func validateImageInput(_ attachments: [DraftAttachment]) throws {
        if attachments.contains(where: { $0.mediaType != nil }), let error = imageInputError { throw PortalError.message(error) }
    }
    var modelName: String { modelDefinition["name"].string ?? currentModel["model"].string ?? L("Choose model", "选择模型") }
    var effortName: String {
        guard let effort = currentModel["reasoningEffort"].string else { return L("Default", "默认") }
        return modelDefinition["reasoning"]["efforts"].array.first { $0["id"].text == effort }?["name"].string ?? effort
    }
    var sessionStarted: Bool { projections["sessionListMetadata"]["blank"] == false || transcript.contains { $0.role == "user" } || running }
    var planEnabled: Bool { projections["plan"]["pending"].boolean ? !projections["plan"]["active"].boolean : projections["plan"]["active"].boolean }
    var supportsPlan: Bool { isDraft || commands.contains { $0["name"] == "plan" } }
    func selectModel(provider: String, model: String, reasoningEffort: String? = nil, useDefaultEffort: Bool = false) async throws {
        var request: JSON = ["sessionId": .string(sessionID), "provider": .string(provider), "model": .string(model)]
        let sameRoute = currentModel["provider"].text == provider && currentModel["model"].text == model
        let definition = catalog["groups"].array.first { $0["id"].text == provider }?["models"].array.first { $0["id"].text == model } ?? [:]
        let effort = useDefaultEffort ? nil : reasoningEffort ?? (sameRoute ? currentModel["reasoningEffort"].string : definition["reasoning"]["defaultEffort"].string)
        if let effort { request["reasoningEffort"] = .string(effort) }
        if isDraft { selectedModel = ["selected": request]; return }
        selectedModel = try await api.rpc("session/selectModel", args: ["request": request])
    }
    func loadControls() async throws {
        permissionCatalog = try await api.rpc("permissionPresets/catalog", args: [:])
        presetCatalog = try await api.rpc("agentPresets/list", args: [:])
        if isDraft {
            if projections["permissions"]["currentValue"] == .null { projections["permissions"]["currentValue"] = permissionCatalog["defaultPreset"] }
            return
        }
        commands = try await api.rpc("commands/list", args: ["agentId": .string(sessionID)]).array
        try await refreshProjections()
    }
    func refreshProjections() async throws {
        applyProjections(try await api.rpc("session/projections", args: ["request": ["sessionId": .string(sessionID)]]))
    }
    @discardableResult
    func executeCommand(_ line: String, attachments: [JSON] = []) async throws -> JSON {
        if isDraft, line == "/plan" || line == "/plan off" {
            projections["plan"]["active"] = .bool(line == "/plan")
            return ["result": ["kind": "text", "text": ""]]
        }
        commandNotice = nil; exportedFile = nil
        let response = try await api.rpc("commands/execute", args: ["agentId": .string(sessionID), "line": .string(line), "submittedAttachments": .array(attachments)])
        guard response["result"]["kind"].string != nil else { throw PortalError.message(L("Unknown command. Choose a suggestion or send ordinary text.", "未知命令，请选择建议或发送普通文本。")) }
        let result = response["result"]
        if result["kind"] == "error" { throw PortalError.message(result["text"].string ?? L("Command failed.", "命令执行失败。")) }
        commandNotice = result["text"].string
        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "/export" { exportedFile = try await api.exportSession(sessionID) }
        try await refreshProjections()
        return response
    }
    func selectPermission(_ preset: String) async throws {
        if isDraft { projections["permissions"]["currentValue"] = .string(preset); return }
        try await executeCommand("/permission " + preset)
    }
    func selectPreset(_ preset: String) async throws {
        if isDraft { projections["agentPreset"] = .string(preset); return }
        guard !sessionStarted else { throw PortalError.message(L("Choose a preset before the first message.", "请在发送第一条消息前选择预设。")) }
        _ = try await api.rpc("agentPresets/select", args: ["agentId": .string(sessionID), "agentPreset": .string(preset)])
        commands = []
        try await loadControls()
    }
    func updateQueue(_ id: String, kind: String, text: String? = nil) async throws {
        var action: JSON = ["kind": .string(kind)]
        if kind == "edit" {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PortalError.message(L("Enter a message.", "请输入消息。")) }
            action["content"] = [["type": "text", "text": .string(text)]]
        }
        let rpcID = queue.first { $0["id"].text == id }?["rpcId"].string
        _ = try await api.rpc("session/updateQueue", args: ["request": ["sessionId": .string(sessionID), "itemId": .string(id), "action": action]])
        if let rpcID { optimistic.removeAll { $0.requestID == rpcID } }
        applyState(try await api.rpc("session/state", args: ["request": ["sessionId": .string(sessionID)]]))
    }
    func loadOlder() async throws {
        guard hasMore, let before = history.keys.min(), let through = snapshotCursor else { return }
        let page = try await api.rpc("session/events", args: ["request": ["address": address, "beforeSeq": .int(before), "throughSeq": .int(through), "maxMessages": 50]])
        for record in page["records"].array { if let seq = record["event"]["seq"].int { history[seq] = record["event"] } }
        hasMore = page["hasMore"].boolean; rebuild()
    }
    deinit { startupTask?.cancel(); followTask?.cancel(); recoveryTask?.cancel(); controlTasks.forEach { $0.cancel() } }
}

@MainActor
final class ChatSelection: ObservableObject {
    @Published private(set) var chat: ChatStore?
    private let makeChat: (String) -> ChatStore
    init(makeChat: @escaping (String) -> ChatStore) { self.makeChat = makeChat }
    func select(_ sessionID: String?) {
        guard let sessionID else { chat?.stop(); chat = nil; return }
        if chat?.sessionID != sessionID { chat?.stop(); chat = makeChat(sessionID) }
        chat?.activate()
    }
    func resume() { chat?.activate() }
    func stop() { chat?.stop() }
}
