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
    var messageID: String?
    var turnOutcome: String?
    var interrupted = false
    var steering = false
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
        while blocks.count <= index { blocks.append(TranscriptBlock(["type": ""])) }
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

enum ChatTranscriptProjection {
    static func bounded(_ text: String) -> String {
        text.count > 20_000 ? String(text.prefix(20_000)) + L("\nTruncated (\(text.count) characters)", "\n已截断（共 \(text.count) 个字符）") : text
    }
    static func contextBody(_ block: TranscriptBlock) -> (form: String?, rows: [JSON]) {
        let source = block.raw["source"]
        let content = block.raw["content"].array
        let form = source["form"].text
        if !content.isEmpty, content.allSatisfy({ ["tool-addition", "tool-removal"].contains($0["type"].text) }) {
            return ("tools", content.map { ["label": .string($0["type"] == "tool-addition" ? L("Added", "已添加") : L("Removed", "已移除")), "text": $0["toolName"]] })
        }
        var model: [JSON] = []
        for content in content {
            if content["type"] == "text", let last = model.indices.last, model[last]["kind"] == "text" {
                model[last]["text"] = .string(model[last]["text"].text + content["text"].text)
            } else { model.append(["kind": content["type"] == "text" ? "text" : "json", "text": content["type"] == "text" ? content["text"] : .string(content.formatted)]) }
        }
        switch form {
        case "snapshot":
            let sections = source["sections"].array
            if !sections.isEmpty, sections.allSatisfy({ !$0["name"].text.isEmpty && $0["text"].string != nil }) {
                return (form, [["text": .string(L("This snapshot supersedes earlier snapshots.", "此快照取代先前的快照。"))]] + sections.map { ["label": $0["name"], "text": $0["text"]] })
            }
        case "catalog":
            if case .array(let entries) = source["entries"], entries.allSatisfy({ !$0["name"].text.isEmpty && $0["description"].string != nil }) {
                var rows: [JSON] = source["update"] == true ? [["text": .string(L("Catalog replaced", "目录已替换"))]] : []
                rows += entries.prefix(200).map { ["label": $0["name"], "text": $0["description"]] }
                if entries.count > 200 { rows.append(["text": .string(L("\(entries.count - 200) more entries", "另有 \(entries.count - 200) 项"))]) }
                return (form, rows + model.filter { $0["kind"] == "json" })
            }
        case "instructions":
            let changes = source["changes"].array
            if !changes.isEmpty, changes.allSatisfy({ !$0["path"].text.isEmpty && ["set", "replace", "remove"].contains($0["action"].text) }) {
                var seen = Set<String>()
                let rows: [JSON] = changes.filter { seen.insert($0["path"].text).inserted }.map { change in
                    let action = change["action"].text
                    let label = action == "remove" ? L("Removed", "已移除") : source["baseline"] == true ? L("Loaded", "已加载") : action == "set" ? L("Added", "已添加") : L("Updated", "已更新")
                    return ["label": change["path"], "text": .string(label), "digest": change["digest"]]
                }
                return (form, rows + model)
            }
        case "notice":
            if !source["summary"].text.isEmpty { return (form, model) }
        case "relay":
            if !source["senderSessionId"].text.isEmpty { return (form, [["label": .string(L("From session", "来自会话")), "text": source["senderSessionId"]]] + model) }
        case "recall":
            let references = source["references"].array
            if !references.isEmpty, references.allSatisfy({ !$0["label"].text.isEmpty && $0["retainedMessages"].int != nil && $0["omittedMessages"].int != nil && ($0["truncated"] == true || $0["truncated"] == false) }) {
                let rows: [JSON] = references.map { reference in
                    let retained = reference["retainedMessages"].int ?? 0
                    let omitted = reference["omittedMessages"].int ?? 0
                    return ["label": reference["label"], "text": .string(L("\(retained) retained · \(omitted) omitted", "保留 \(retained) 条 · 省略 \(omitted) 条") + (reference["truncated"] == true ? L(" · Truncated", " · 已截断") : ""))]
                }
                return (form, rows + model)
            }
        default: break
        }
        return (nil, model + source.object.keys.filter { $0 != "kind" }.sorted().map { ["label": .string($0), "text": .string(source[$0].string ?? source[$0].formatted)] })
    }
    static func visible(_ block: TranscriptBlock) -> Bool {
        guard !block.kind.isEmpty else { return false }
        if ["text", "reasoning"].contains(block.kind) { return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return block.kind != "tool-call" || !block.callID.isEmpty || !block.name.isEmpty || !block.arguments.isEmpty
    }
    static func producer(_ source: JSON) -> String {
        switch source["kind"].text {
        case "session-reference":
            let labels = source["references"].array.compactMap { $0["label"].string }
            return labels.isEmpty ? source["kind"].text : labels.joined(separator: ", ")
        case "agent-instructions":
            let paths = source["changes"].array.compactMap { $0["path"].string }
            return paths.isEmpty ? source["kind"].text : paths.joined(separator: ", ")
        case "skill-invocation": return source["name"].string ?? source["kind"].text
        default: return source["kind"].text
        }
    }
    static func project(_ events: [JSON]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var turn: Int?
        var step: Int?
        var outcomes: [Int: String] = [:]
        var inboxes: [String: [JSON]] = [:]
        var claims: [String: Set<String>] = [:]
        var claimSequences: [String: Int] = [:]
        var turnStartSeq = -1
        var steering = Set<String>()
        var commands: [String: JSON] = [:]
        var summaries: [String: JSON] = [:]
        var retries: [String: Int] = [:]
        var results: [JSON] = []
        let representedCalls = Set(events.filter { $0["type"] == "assistant/message" && ($0["surfaceOp"] == "append" || $0["surfaceOp"] == .null) }.flatMap { $0["data"]["message"]["content"].array }.filter { $0["type"] == "tool-call" }.compactMap { $0["id"].string })
        for event in events {
            if event["type"] == "command/done" { commands[event["data"]["commandId"].text] = event["data"] }
            if event["type"] == "compaction/summary" { summaries[event["data"]["compactionId"].text] = event["data"] }
        }
        for event in events {
            let type = event["type"].text
            let data = event["data"]
            let seq = event["seq"].int ?? 0
            if type == "turn/start" { turn = data["turn"].int; step = nil; turnStartSeq = seq; continue }
            if type == "step/start" { turn = data["turn"].int; step = data["step"].int; continue }
            if type == "agent/inbox/spliced" {
                let target = data["target"].text
                var pending = inboxes[target] ?? []
                let start = min(max(0, data["start"].int ?? 0), pending.count)
                let end = min(pending.count, start + max(0, data["removedCount"].int ?? 0))
                if end > start, data["outcome"] != "canceled" {
                    claims[target] = Set(pending[start..<end].map { $0["id"].text })
                    claimSequences[target] = seq
                    if target == "next-step" { steering = claims[target] ?? [] }
                }
                for message in data["inserted"].array { claims[target]?.remove(message["id"].text); steering.remove(message["id"].text) }
                pending.replaceSubrange(start..<end, with: data["inserted"].array)
                inboxes[target] = pending
                continue
            }
            var role = "notice"
            var blocks: [TranscriptBlock] = []
            var message: JSON = .null
            let itemTurn = data["turn"].int ?? turn
            let itemStep = data["step"].int ?? step
            switch type {
            case "user/message", "developer/message":
                message = type == "user/message" ? data : data["message"]
                if event["surfaceOp"] != .null && event["surfaceOp"] != "append" {
                    guard type == "user/message", message["source"]["kind"] == "compact-checkpoint" else { continue }
                    let source = message["source"]
                    let summary = summaries[source["compactionId"].text]?["summary"].array ?? []
                    let metadata = summaries[source["compactionId"].text] ?? .null
                    blocks = [TranscriptBlock(["type": "compaction", "text": .string(summary.filter { $0["type"] == "text" }.map { $0["text"].text }.joined()), "shadowedItemCount": metadata["shadowedSeqs"] == .null ? .null : .int(metadata["shadowedSeqs"].array.count), "shadowedTokenCount": metadata["shadowedTokenCount"]])]
                    if let commandID = source["sourceCommandId"].string, let index = items.firstIndex(where: { $0.id == "command:" + commandID }) {
                        items[index].blocks = blocks; items[index].role = "notice"; continue
                    }
                } else if type == "user/message", message["source"]["kind"] == "user" || message["source"]["kind"] == .null {
                    role = "user"; blocks = message["content"].array.map(TranscriptBlock.init)
                } else {
                    role = "context"
                    let id = message["id"].text
                    let claimed = claims["next-turn"]?.contains(id) == true
                    let idleSteer = step == 1 && (claimSequences["next-step"] ?? -1) > turnStartSeq && (claimSequences["next-turn"] ?? -1) < turnStartSeq && claims["next-step"]?.contains(id) == true && !events.contains { $0["type"] == "user/message" && $0["data"]["source"]["kind"] == "user" && claims["next-step"]?.contains($0["data"]["id"].text) == true }
                    if claimed || idleSteer || (message["source"]["kind"] == "retry" && message["content"].array.isEmpty) { role = "trigger" }
                    blocks = [TranscriptBlock(["type": "context", "source": message["source"], "content": message["content"], "text": .string(message["content"].array.map { $0["text"].text }.joined()), "producer": .string(producer(message["source"])), "trigger": .bool(role == "trigger")])]
                }
            case "assistant/message":
                if event["surfaceOp"] != .null && event["surfaceOp"] != "append" { continue }
                role = "assistant"; message = data["message"]
                blocks = message["content"].array.map(TranscriptBlock.init)
                blocks = blocks.filter(visible)
                guard !blocks.isEmpty else { continue }
            case "tool/call":
                guard !representedCalls.contains(data["callId"].text) else { continue }
                role = "tool"
                blocks = [TranscriptBlock(["type": "tool-call", "id": data["callId"], "name": data["name"], "arguments": data["arguments"]])]
            case "tool/result":
                if event["surfaceOp"] == "append" || event["surfaceOp"] == .null { results.append(event) }
                continue
            case "command/run":
                if data["name"] == "goal" {
                    let args = String(data["args"].text.reversed().drop(while: \.isWhitespace).reversed())
                    items.append(TranscriptItem(id: "command-input:" + data["commandId"].text, role: "command-input", blocks: [TranscriptBlock(["type": "text", "text": .string("/goal" + args)])], seq: seq, turn: itemTurn, step: itemStep))
                }
                let outcome = commands[data["commandId"].text] ?? .null
                if data["name"] == "permission" { continue }
                if data["name"] == "team", ["on", "off"].contains(data["args"].text.trimmingCharacters(in: .whitespacesAndNewlines)), outcome["kind"] != "error" { continue }
                role = "command"
                blocks = [TranscriptBlock(["type": "command", "name": data["name"], "arguments": data["args"], "text": outcome["text"], "outcome": outcome["kind"]])]
            case "command/done":
                guard !events.contains(where: { $0["type"] == "command/run" && $0["data"]["commandId"] == data["commandId"] }) else { continue }
                role = "command"
                blocks = [TranscriptBlock(["type": "command", "text": data["text"], "outcome": data["kind"]])]
            case "turn/end":
                let reason = data["reason"]
                if let endedTurn = data["turn"].int { outcomes[endedTurn] = reason["kind"].text }
                turn = nil; step = nil
                var text: String?
                if reason["kind"] == "error" { text = reason["error"]["code"] == "AUTH" ? L("Authentication failed.", "身份认证失败。") : reason["error"]["message"].string }
                if reason["kind"] == "interrupted" { text = L("The DSH process exited before this turn finished.", "DSH 进程在此轮完成前退出。") }
                if reason["kind"] == "aborted", reason["reason"]["kind"] == "hook", reason["reason"]["reason"] == "deepseek-account/signed-out" { text = L("Stopped because you signed out of DeepSeek.", "已停止，因为您已退出 DeepSeek。") }
                if reason["kind"] == "max-tokens" { text = L("Maximum output tokens reached.", "已达到最大输出令牌数。") }
                guard let text else { continue }
                blocks = [TranscriptBlock(["type": "system-notice", "text": .string(text)])]
            case "llm/retry":
                guard !data["retryId"].text.isEmpty else { continue }
                let failure = data["error"]
                let text = failure["code"] == "AUTH" ? "" : failure["message"].text
                blocks = [TranscriptBlock(["type": "model-retry", "text": .string(text), "retry": data["retry"]])]
                if let index = retries[data["retryId"].text] { items[index].blocks = blocks; continue }
                retries[data["retryId"].text] = items.count
            case "llm/retry-started":
                if let index = retries[data["retryId"].text] { items[index].blocks[0].raw["started"] = true }
                continue
            default:
                continue
            }
            let id = type == "command/run" ? "command:" + data["commandId"].text : "seq:\(seq)"
            items.append(TranscriptItem(id: id, role: role, blocks: blocks, seq: seq, requestID: message["source"]["rpcId"].string, turn: itemTurn, step: itemStep, messageID: message["id"].string, interrupted: data["interrupted"].boolean || type == "assistant/attempt", steering: role == "user" && steering.contains(message["id"].text)))
        }
        for result in results {
            let message = result["data"]["message"]
            let call = message["toolCallId"].text
            if let item = items.lastIndex(where: { $0.blocks.contains { $0.kind == "tool-call" && $0.callID == call } }), let block = items[item].blocks.firstIndex(where: { $0.callID == call && $0.kind == "tool-call" }) {
                items[item].blocks[block].result = result["data"]
            } else {
                items.append(TranscriptItem(id: "result:\(result["seq"].int ?? 0)", role: "notice", blocks: [TranscriptBlock(["type": "unknown-surface", "text": .string(message.formatted)])], seq: result["seq"].int, turn: result["data"]["turn"].int))
            }
        }
        for index in items.indices { if let turn = items[index].turn { items[index].turnOutcome = outcomes[turn] } }
        return items.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }
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
    private var commandNoticeID: String?
    var visibleCommandNotice: String? {
        guard let commandNoticeID else { return commandNotice }
        return history.values.contains { $0["type"] == "command/done" && $0["data"]["commandId"].text == commandNoticeID } ? nil : commandNotice
    }
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
    private var pendingQueue: [JSON] = []
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
        if startupTask != nil && error != nil { stop() }
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
    func waitForHistory() async throws {
        for _ in 0..<200 {
            try Task.checkCancellation()
            if loaded { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw PortalError.message(L("The conversation stream could not connect. Try again.", "对话流连接失败，请重试。"))
    }
    func applyState(_ state: JSON) {
        guard state["running"] == true || state["running"] == false else { return }
        stateRevision += 1
        running = state["running"].boolean
        pendingQueue = state["queue"].array.filter(Self.isUserInput)
        rebuild()
    }
    private static func isUserInput(_ message: JSON) -> Bool {
        let kind = message["source"]["kind"]
        return message["placement"] != "context" && (kind == .null || kind == "user") && (message["role"] == .null || message["role"] == "user")
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
        let item = TranscriptItem(id: "request:" + requestID, role: "user", blocks: content.map(TranscriptBlock.init), requestID: requestID, optimistic: true)
        if let index = optimistic.firstIndex(where: { $0.requestID == requestID }) { optimistic[index] = item }
        else { optimistic.append(item) }
        rebuild()
    }
    private func rebuild() {
        let events = history.sorted(by: { $0.key < $1.key }).map(\.value)
        turnUsage = TurnUsage.byTurn(events)
        let committed = events.filter { $0["type"] == "user/message" && ($0["surfaceOp"] == "append" || $0["surfaceOp"] == .null) }
        let committedRequests = Set(committed.compactMap { $0["data"]["source"]["rpcId"].string })
        let committedIDs = Set(committed.compactMap { $0["data"]["id"].string })
        optimistic.removeAll { $0.requestID.map(committedRequests.contains) ?? false }
        queue = pendingQueue.filter {
            !committedIDs.contains($0["id"].text) && !committedRequests.contains(($0["rpcId"].string ?? $0["source"]["rpcId"].text))
        }
        let steering = queue.filter { $0["placement"] == "steering" }
        queue.removeAll { $0["placement"] == "steering" }
        let pendingRequests = Set((queue + steering).compactMap { $0["rpcId"].string ?? $0["source"]["rpcId"].string })
        let pendingSteering = steering.map { message -> TranscriptItem in
            let request = message["rpcId"].string ?? message["source"]["rpcId"].string
            var item = optimistic.first { $0.requestID != nil && $0.requestID == request } ?? TranscriptItem(id: "steering:" + message["id"].text, role: "user", blocks: message["content"].array.map(TranscriptBlock.init), requestID: request, messageID: message["id"].string)
            item.steering = true
            return item
        }
        transcript = ChatTranscriptProjection.project(events) + pendingSteering + optimistic.filter { !pendingRequests.contains($0.requestID ?? "") }
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
        async let permissions = api.rpc("permissionPresets/catalog", args: [:])
        async let presets = api.rpc("agentPresets/list", args: [:])
        if isDraft {
            (permissionCatalog, presetCatalog) = try await (permissions, presets)
            if projections["permissions"]["currentValue"] == .null { projections["permissions"]["currentValue"] = permissionCatalog["defaultPreset"] }
            return
        }
        async let commandList = api.rpc("commands/list", args: ["agentId": .string(sessionID)])
        async let snapshot = api.rpc("session/projections", args: ["request": ["sessionId": .string(sessionID)]])
        let values = try await (permissions, presets, commandList, snapshot)
        permissionCatalog = values.0; presetCatalog = values.1; commands = values.2.array
        applyProjections(values.3)
    }
    func refreshProjections() async throws {
        applyProjections(try await api.rpc("session/projections", args: ["request": ["sessionId": .string(sessionID)]]))
    }
    @discardableResult
    func executeCommand(_ line: String, attachments: [JSON] = [], showNotice: Bool = true) async throws -> JSON {
        if isDraft, line == "/plan" || line == "/plan off" {
            projections["plan"]["active"] = .bool(line == "/plan")
            return ["result": ["kind": "text", "text": ""]]
        }
        commandNotice = nil; commandNoticeID = nil; exportedFile = nil
        let response = try await api.rpc("commands/execute", args: ["agentId": .string(sessionID), "line": .string(line), "submittedAttachments": .array(attachments)])
        guard response["result"]["kind"].string != nil else { throw PortalError.message(L("Unknown command. Choose a suggestion or send ordinary text.", "未知命令，请选择建议或发送普通文本。")) }
        let result = response["result"]
        if result["kind"] == "error" { throw PortalError.message(result["text"].string ?? L("Command failed.", "命令执行失败。")) }
        commandNoticeID = response["commandId"].string
        commandNotice = showNotice && line.split(whereSeparator: \.isWhitespace).first != "/permission" ? result["text"].string.map(ChatLabels.notice) : nil
        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "/export" { exportedFile = try await api.exportSession(sessionID) }
        try await refreshProjections()
        return response
    }
    func selectPermission(_ preset: String) async throws {
        if isDraft { projections["permissions"]["currentValue"] = .string(preset); return }
        try await executeCommand("/permission " + preset, showNotice: false)
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
    func adopt(_ store: ChatStore) {
        if chat !== store { chat?.stop(); chat = store }
        chat?.activate()
    }
    func stop() { chat?.stop() }
}
