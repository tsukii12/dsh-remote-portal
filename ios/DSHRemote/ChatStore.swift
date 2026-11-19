import Foundation
import Combine

struct TranscriptBlock: Equatable {
    var kind: String
    var text = ""
    var callID = ""
    var name = ""
    var arguments = ""
    var result: JSON?
    init(_ value: JSON) {
        kind = value["type"].text; text = value["text"].text
        callID = value["id"].text; name = value["name"].text; arguments = value["arguments"].text
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
    var text: String { blocks.filter { $0.kind == "text" }.map(\.text).joined() }
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
    @Published private(set) var error: String?
    private let api: RPCServing
    private weak var events: RemoteEvents?
    private var observer: UUID?
    private var followTask: Task<Void, Never>?
    private var history: [Int: JSON] = [:]
    private var optimistic: [TranscriptItem] = []
    private var snapshotCursor: Int?
    private var attemptID: String?
    private var revision = -1
    private var nextIndex = 0
    private var pendingCommitSeq: Int?
    init(sessionID: String, api: RPCServing, events: RemoteEvents? = nil) { self.sessionID = sessionID; self.api = api; self.events = events }
    private var address: JSON { ["kind": "session", "sessionId": .string(sessionID)] }

    func start() async throws {
        guard followTask == nil else { return }
        if let events {
            observer = events.observe { [weak self] frame in self?.applyStatusEvent(frame) }
        }
        let stream = api.stream("session/follow", args: ["request": ["address": address, "assistantStream": true, "maxMessages": 50]])
        followTask = Task { [weak self] in
            do { for try await frame in stream { if Task.isCancelled { break }; self?.apply(frame) } }
            catch { self?.error = error.localizedDescription }
        }
        applyState(try await api.rpc("session/state", args: ["request": ["sessionId": .string(sessionID)]]))
    }
    func stop() {
        followTask?.cancel(); followTask = nil
        if let observer { events?.removeObserver(observer) }; observer = nil
    }
    func applyState(_ state: JSON) { running = state["running"].boolean }
    func applyStatusEvent(_ frame: JSON) {
        if frame["type"] == "ready" {
            Task { [weak self] in
                guard let self else { return }
                do { self.applyState(try await self.api.rpc("session/state", args: ["request": ["sessionId": .string(self.sessionID)]])) }
                catch { self.error = error.localizedDescription }
            }
        }
        let args = frame["args"].array
        if frame["type"] == "emit", frame["event"] == "api-session/status", args.count > 1, args[0].text == sessionID { running = args[1].boolean }
    }
    func apply(_ frame: JSON) {
        switch frame["type"].text {
        case "connection-reset":
            inProgress = nil; attemptID = nil; revision = -1; pendingCommitSeq = nil; loaded = false
        case "snapshot":
            history = [:]
            snapshotCursor = frame["cursor"].int
            hasMore = frame["hasMore"].boolean
            selectedModel = frame["projections"]["values"]["modelSelection"]
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
        default: break
        }
    }
    func addOptimistic(text: String, requestID: String) {
        optimistic.append(TranscriptItem(id: "request:" + requestID, role: "user", blocks: [TranscriptBlock(["type": "text", "text": .string(text)])], requestID: requestID, optimistic: true))
        rebuild()
    }
    private func rebuild() {
        var surface: [JSON] = []
        for event in history.sorted(by: { $0.key < $1.key }).map(\.value) {
            guard ["user/message", "assistant/message", "tool/result"].contains(event["type"].text) else { continue }
            let op = event["surfaceOp"]
            if op["op"] == "replace", let start = surface.firstIndex(where: { $0["seq"] == op["startSeq"] }), let end = surface.firstIndex(where: { $0["seq"] == op["endSeq"] }), start <= end {
                surface.replaceSubrange(start...end, with: [event])
            } else { surface.append(event) }
        }
        let committedRequests = Set(history.values.filter { $0["type"] == "user/message" }.compactMap { $0["data"]["source"]["rpcId"].string })
        optimistic.removeAll { $0.requestID.map(committedRequests.contains) ?? false }
        var items: [TranscriptItem] = []
        var results: [JSON] = []
        for event in surface {
            let type = event["type"].text
            let data = event["data"]
            if type == "tool/result" { results.append(event); continue }
            let message = type == "user/message" ? data : data["message"]
            if type == "user/message", let source = message["source"]["kind"].string, source != "user" { continue }
            var blocks = message["content"].array.map(TranscriptBlock.init)
            if blocks.isEmpty && type == "assistant/message" {
                for chunk in CompactStream.expand(data["stream"].array) { CompactStream.apply(chunk, to: &blocks) }
            }
            items.append(TranscriptItem(id: message["id"].string ?? "seq:\(event["seq"].int ?? 0)", role: type == "user/message" ? "user" : "assistant", blocks: blocks, seq: event["seq"].int, requestID: message["source"]["rpcId"].string, turn: data["turn"].int, step: data["step"].int))
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
        transcript = items.sorted { (positions[$0.seq ?? -1] ?? 0) < (positions[$1.seq ?? -1] ?? 0) } + optimistic
    }
    @discardableResult
    func send(_ text: String, steer: Bool = false) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PortalError.message("Enter a message") }
        let id = UUID().uuidString
        addOptimistic(text: text, requestID: id)
        do {
            _ = try await api.rpc("session/prompt", args: ["request": ["sessionId": .string(sessionID), "requestId": .string(id), "mode": steer && running ? "steer" : "queue", "content": [["type": "text", "text": .string(text)]], "clientTimeZone": .string(TimeZone.current.identifier)]])
            return id
        } catch {
            if let index = optimistic.firstIndex(where: { $0.requestID == id }) { optimistic[index].deliveryError = error.localizedDescription }
            rebuild(); throw error
        }
    }
    func cancel() async throws { _ = try await api.rpc("session/cancel", args: ["request": ["sessionId": .string(sessionID)]]) }
    func loadModels() async throws { catalog = try await api.rpc("session/modelCatalog", args: [:]) }
    func selectModel(provider: String, model: String, reasoningEffort: String? = nil) async throws {
        var request: JSON = ["sessionId": .string(sessionID), "provider": .string(provider), "model": .string(model)]
        if let reasoningEffort { request["reasoningEffort"] = .string(reasoningEffort) }
        selectedModel = try await api.rpc("session/selectModel", args: ["request": request])
    }
    func loadOlder() async throws {
        guard hasMore, let before = history.keys.min(), let through = snapshotCursor else { return }
        let page = try await api.rpc("session/events", args: ["request": ["address": address, "beforeSeq": .int(before), "throughSeq": .int(through), "maxMessages": 50]])
        for record in page["records"].array { if let seq = record["event"]["seq"].int { history[seq] = record["event"] } }
        hasMore = page["hasMore"].boolean; rebuild()
    }
    deinit { followTask?.cancel() }
}
