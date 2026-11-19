import XCTest
import Combine
import SwiftUI
import UIKit
@testable import DSHRemote

@MainActor
private final class ChatStartupProbe: RPCServing {
    var calls: [String] = []
    var streams: [String] = []
    var ended: [String] = []
    var failure: Error?
    var records: [JSON] = [["event": ["seq": 1, "type": "user/message", "data": ["content": [["type": "text", "text": "Existing message"]]]]]]
    func rpc(_ method: String, args: JSON) async throws -> JSON {
        calls.append(method)
        if method == "session/state" { try await Task.sleep(nanoseconds: 500_000_000) }
        if let failure { throw failure }
        switch method {
        case "session/modelCatalog": return ["default": ["provider": "fake", "model": "one"], "groups": [["id": "fake", "models": [["id": "one", "name": "One"]]]]]
        case "session/projections": return ["asOfSeq": 1, "values": ["modelSelection": ["selected": ["provider": "fake", "model": "one"]]]]
        default: return [:]
        }
    }
    func stream(_ endpoint: String, args: JSON) -> AsyncThrowingStream<JSON, Error> {
        streams.append(endpoint)
        let records = records
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.ended.append(endpoint) } }
            if endpoint == "session/follow" {
                Task {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continuation.yield(["type": "snapshot", "records": .array(records)])
                }
            }
        }
    }
}

@MainActor
private final class ChatStartupRoute: ObservableObject {
    @Published var selection: String? { didSet { chats.select(selection) } }
    @Published var search = "Known chat"
    @Published var compactColumn: NavigationSplitViewColumn = .sidebar
    @Published var revision = 0
    var stores: [(ChatStore, ChatStartupProbe)] = []
    lazy var chats = ChatSelection { [unowned self] in self.chat($0) }
    func chat(_ id: String) -> ChatStore {
        let api = ChatStartupProbe()
        let chat = ChatStore(sessionID: id, api: api)
        stores.append((chat, api))
        return chat
    }
}

private struct ChatStartupHarness: View {
    @ObservedObject var route: ChatStartupRoute
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $route.compactColumn) {
            List { Text("Known chat") }.navigationTitle("Chats").searchable(text: $route.search)
        } detail: {
            if let chat = route.chats.chat {
                ChatView(chat: chat, title: "Known chat \(route.revision)").id(chat.sessionID)
            }
        }.navigationSplitViewStyle(.balanced)
            .onAppear { route.chats.resume() }
            .onDisappear { route.chats.stop() }
    }
}

@MainActor
final class StubAPI: RPCServing {
    var calls: [(String, JSON)] = []
    var response: JSON = [:]
    var failure: Error?
    func rpc(_ method: String, args: JSON) async throws -> JSON {
        calls.append((method, args))
        if let failure { throw failure }
        return response
    }
    func stream(_ endpoint: String, args: JSON) -> AsyncThrowingStream<JSON, Error> { AsyncThrowingStream { _ in } }
}

@MainActor
final class NativeStateTests: XCTestCase {
    func testSearchSelectionKeepsStartedChatAcrossParentUpdates() async throws {
        let route = ChatStartupRoute()
        route.selection = "A"; route.compactColumn = .detail
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ChatStartupHarness(route: route))
        window.makeKeyAndVisible()
        defer {
            route.stores.forEach { $0.0.stop() }
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        route.compactColumn = .sidebar
        try await Task.sleep(nanoseconds: 300_000_000)
        let search = try XCTUnwrap(controllers(window.rootViewController!).filter { $0.viewIfLoaded?.window != nil }.compactMap { $0.navigationItem.searchController }.last)
        search.isActive = true
        search.searchBar.searchTextField.becomeFirstResponder()
        try await Task.sleep(nanoseconds: 300_000_000)
        route.selection = "S"; route.compactColumn = .detail
        try await Task.sleep(nanoseconds: 10_000_000)
        route.search = ""; route.revision += 1
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let started = route.stores.filter { $0.0.sessionID == "S" && !$0.1.streams.isEmpty }
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(started.first?.0.loaded == true)
        XCTAssertEqual(started.first?.0.transcript.first?.text, "Existing message")
        XCTAssertEqual(started.first?.0.modelName, "One")
        XCTAssertEqual(started.first?.1.ended, [])
        XCTAssertEqual(started.first?.1.calls, ["session/state", "session/modelCatalog", "permissionPresets/catalog", "agentPresets/list", "commands/list", "session/projections"])
    }
    func testChatSelectionStartsOutsideCancelledNavigationAndKeepsOneStore() async throws {
        let api = ChatStartupProbe(); api.records = []
        var created = 0
        let selection = ChatSelection { id in created += 1; return ChatStore(sessionID: id, api: api) }
        selection.select(nil)
        XCTAssertNil(selection.chat); XCTAssertEqual(created, 0)
        let navigation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            selection.select("S"); selection.select("S")
        }
        await navigation.value
        let chat = try XCTUnwrap(selection.chat)
        defer { selection.stop() }
        let ready = expectation(description: "Empty session snapshot and all metadata loaded")
        let subscription = Publishers.CombineLatest(chat.$loaded, chat.$projections)
            .first { $0.0 && $0.1["modelSelection"]["selected"]["model"] == "one" }.sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(created, 1); XCTAssertTrue(chat.transcript.isEmpty); XCTAssertEqual(chat.modelName, "One")
        XCTAssertEqual(api.streams, ["session/follow", "session/control", "session/observeState"])
        XCTAssertNil(chat.error)
        selection.select(nil); XCTAssertNil(selection.chat)
    }
    func testChatSelectionCancelsSupersededStartupAndRetriesFailures() async throws {
        let oldAPI = ChatStartupProbe(), api = ChatStartupProbe()
        api.failure = PortalError.message("Startup failed")
        let selection = ChatSelection { id in ChatStore(sessionID: id, api: id == "old" ? oldAPI : api) }
        selection.select("old")
        await Task.yield()
        selection.select("S")
        let chat = try XCTUnwrap(selection.chat)
        defer { selection.stop() }
        let failed = expectation(description: "Startup failure is visible")
        let errorSubscription = chat.$error.first { $0 != nil }.sink { _ in failed.fulfill() }
        defer { errorSubscription.cancel() }
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(chat.error, "Startup failed")
        XCTAssertFalse(oldAPI.calls.contains("session/modelCatalog"))
        api.failure = nil
        let ready = expectation(description: "Reselecting retries the failed startup")
        let subscription = chat.$projections.first { $0["modelSelection"]["selected"]["model"] == "one" }.sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        selection.select("S")
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertTrue(selection.chat === chat); XCTAssertNil(chat.error)
        XCTAssertEqual(api.calls.filter { $0 == "session/state" }.count, 2)
        XCTAssertEqual(chat.modelName, "One")
    }
    func testFileMentionGrammarQuotesDirectoriesUnicodeAndUnsafePaths() throws {
        XCTAssertNil(FileMentionToken.active(in: "mail@example.com"))
        XCTAssertNil(FileMentionToken.active(in: "ordinary text"))
        let token = try XCTUnwrap(FileMentionToken.active(in: "See @src"))
        XCTAssertEqual(token.query, "src")
        XCTAssertEqual(token.inserting(["path": "src/main.swift", "kind": "file"], into: "See @src"), "See @src/main.swift ")
        XCTAssertEqual(token.inserting(["path": "路径/a file.swift", "kind": "file"], into: "See @src"), "See @\"路径/a file.swift\" ")
        XCTAssertEqual(token.inserting(["path": "a directory", "kind": "directory"], into: "See @src"), "See @\"a directory/")
        let quoted = try XCTUnwrap(FileMentionToken.active(in: "@\"a directory/"))
        XCTAssertEqual(quoted.query, "a directory/")
        XCTAssertEqual(quoted.inserting(["path": "a directory/one.txt", "kind": "file"], into: "@\"a directory/"), "@\"a directory/one.txt\" ")
        for path in ["", "a\"b", "a\nb", "a\u{0080}b"] { XCTAssertNil(token.inserting(["path": .string(path), "kind": "file"], into: "See @src")) }
        XCTAssertNil(token.inserting(["path": "one", "kind": "file"], into: "changed"))
    }
    func testHostImageLimitsAndUnboundedGenericFileIntake() throws {
        let store = AttachmentsStore(api: StubAPI(), sessionID: "S")
        let limits: JSON = ["mediaTypes": ["image/png"], "maxImageBytes": 100, "maxMessageImageBytes": 80, "maxImagesPerMessage": 2]
        XCTAssertNoThrow(try store.validate(bytes: 80, mediaType: "image/png", limits: limits))
        XCTAssertNoThrow(try store.validate(bytes: Int.max, mediaType: nil, limits: [:]))
        XCTAssertThrowsError(try store.validate(bytes: 101, mediaType: "image/png", limits: limits))
        XCTAssertThrowsError(try store.validate(bytes: 81, mediaType: "image/png", limits: limits))
        XCTAssertThrowsError(try store.validate(bytes: 10, mediaType: "image/heic", limits: limits))
        var none = limits; none["maxImagesPerMessage"] = 0
        XCTAssertThrowsError(try store.validate(bytes: 10, mediaType: "image/png", limits: none))
        XCTAssertThrowsError(try store.validate(bytes: 10, mediaType: "image/png", limits: [:]))
        XCTAssertTrue(store.items.isEmpty); XCTAssertTrue(store.ready)
    }
    func testUsageProjectionsZeroUnknownAndContextFallback() {
        let usage: JSON = ["uncachedInputTokens": 10, "cacheReadTokens": 20, "cacheWriteTokens": 3, "outputTokens": 5, "reasoningTokens": 4]
        XCTAssertEqual(UsagePresentation.total(usage), 38)
        XCTAssertEqual(UsagePresentation.total(["uncachedInputTokens": 0, "cacheReadTokens": 0, "cacheWriteTokens": 0, "outputTokens": 0]), 0)
        XCTAssertNil(UsagePresentation.total([:]))
        var invalid = usage; invalid["outputTokens"] = -1; XCTAssertNil(UsagePresentation.total(invalid))
        XCTAssertEqual(UsagePresentation.context(["projectedTokens": 0, "pressureTokens": 50, "contextWindow": 100])?.used, 0)
        XCTAssertEqual(UsagePresentation.context(["pressureTokens": 25, "contextWindow": 100])?.percent, 25)
        XCTAssertEqual(UsagePresentation.context(["projectedTokens": 250, "contextWindow": 100])?.percent, 100)
        XCTAssertNil(UsagePresentation.context(["projectedTokens": 10]))
        XCTAssertNil(UsagePresentation.context(["pressureTokens": 10, "contextWindow": 0]))
    }
    func testCapturedCompleteTurnUsageAndPartialHistorySuppression() throws {
        var page = try fixture("live-hello-events")["result"]["value"]
        let events = page["records"].array.map { $0["event"] }
        XCTAssertEqual(TurnUsage.byTurn(events)[1]?["totalTokens"], 150)
        XCTAssertEqual(TurnUsage.byTurn(events)[1]?["uncachedInputTokens"], 100)
        page["type"] = "snapshot"
        let chat = ChatStore(sessionID: "S", api: StubAPI()); chat.apply(page)
        let assistant = try XCTUnwrap(chat.transcript.last { $0.role == "assistant" })
        XCTAssertEqual(chat.usage(for: assistant)?["totalTokens"], 150)
        XCTAssertNil(TurnUsage.derive([]))
        let start = try XCTUnwrap(events.firstIndex { $0["type"] == "turn/start" })
        XCTAssertNil(TurnUsage.derive(Array(events.dropFirst(start + 1))))
        XCTAssertNil(TurnUsage.derive(Array(events[start...].prefix { $0["type"] != "turn/end" })))
    }
    func testTurnUsageRetryAccountingAndMalformedSamples() {
        let first: JSON = ["inputTokens": 10, "outputTokens": 2, "totalTokens": 12]
        let second: JSON = ["inputTokens": 20, "outputTokens": 4, "totalTokens": 29, "cacheReadTokens": 5, "cacheWriteTokens": 0, "reasoningTokens": 2]
        let events: [JSON] = [
            ["type": "turn/start", "data": ["turn": 1]],
            ["type": "step/start", "data": ["turn": 1, "step": 1]],
            ["type": "assistant/attempt", "data": ["turn": 1, "step": 1, "stream": [["type": "chunk", "chunk": ["type": "usage", "usage": first]]]]],
            ["type": "llm/retry", "data": ["turn": 1, "step": 1]],
            ["type": "llm/retry-started", "data": ["turn": 1, "step": 1]],
            ["type": "assistant/message", "data": ["turn": 1, "step": 1, "usage": second, "message": ["source": ["provider": "fake", "model": "one"]]]],
            ["type": "step/end", "data": ["turn": 1, "step": 1]],
            ["type": "turn/end", "data": ["turn": 1]]
        ]
        let result = TurnUsage.derive(events)
        XCTAssertEqual(result?["totalTokens"], 41); XCTAssertEqual(result?["outputTokens"], 6)
        XCTAssertEqual(result?["uncachedInputTokens"], 30)
        XCTAssertEqual(result?["cacheReadTokens"], .null); XCTAssertEqual(result?["reasoningTokens"], .null)
        for key in ["inputTokens", "outputTokens", "reasoningTokens", "totalTokens"] {
            var invalid = events; invalid[5]["data"]["usage"][key] = -1
            XCTAssertNil(TurnUsage.derive(invalid))
        }
        var contradictory = events; contradictory[5]["data"]["usage"]["totalTokens"] = 100
        XCTAssertNil(TurnUsage.derive(contradictory))
        var reasoning = events; reasoning[5]["data"]["usage"]["reasoningTokens"] = 5
        XCTAssertNil(TurnUsage.derive(reasoning))
        var missingLifecycle = events; missingLifecycle.remove(at: 4)
        XCTAssertNil(TurnUsage.derive(missingLifecycle))
    }
    func testInteractionRoutingUsesCapturedWaterfallSessionAddress() throws {
        let events = RemoteEvents(api: StubAPI())
        for frame in try fixture("live-stream-all").array { events.apply(frame["value"]) }
        let item = try XCTUnwrap(events.pending.first)
        let sessionID = "session-18be2ddf-6a3a-42d3-aa72-320df014ae67"
        XCTAssertEqual(item.agentID, sessionID)
        XCTAssertEqual(InteractionRouting.sessionID(item, knownSessionIDs: [sessionID]), sessionID)
        var routing = InteractionRouting()
        routing.reconcile(events.pending, openSessionID: sessionID)
        XCTAssertEqual(routing.presentedID, item.id)
    }
    func testInteractionDeferralReopenCancellationAndReconnect() {
        let events = RemoteEvents(api: StubAPI())
        events.apply(["type": "ready", "clientId": "client"])
        for (id, agent, kind) in [("other", "B", "approval/request"), ("approve", "A", "approval/request"), ("question", "A", "user-questions/request")] {
            events.apply(["type": "waterfall", "eventId": .string(id), "agentId": .string(agent), "event": .string(kind), "request": ["agentId": "unrelated"]])
        }
        var routing = InteractionRouting()
        routing.reconcile(events.pending, openSessionID: nil)
        XCTAssertNil(routing.presentedID)
        routing.reconcile(events.pending, openSessionID: "A")
        XCTAssertEqual(routing.presentedID, "approve")
        routing.dismiss()
        XCTAssertEqual(events.pending.count, 3)
        routing.reconcile(events.pending, openSessionID: "B")
        XCTAssertEqual(routing.presentedID, "other")
        routing.dismiss()
        routing.reconcile(events.pending, openSessionID: "A")
        XCTAssertEqual(routing.presentedID, "question")
        routing.dismiss()
        routing.reconcile(events.pending, openSessionID: "A")
        XCTAssertNil(routing.presentedID)
        let pending = InteractionRouting.forSession(events.pending, sessionID: "A")
        XCTAssertEqual(pending.map(\.id), ["approve", "question"])
        routing.review(pending[0])
        XCTAssertEqual(routing.presentedID, "approve")
        events.apply(["type": "cancel", "eventId": "approve"])
        routing.reconcile(events.pending, openSessionID: "A")
        XCTAssertNil(routing.presentedID)
        XCTAssertFalse(routing.deferred.contains("approve"))
        events.apply(["type": "connection-reset"])
        routing.reconcile(events.pending, openSessionID: "A")
        XCTAssertTrue(routing.deferred.isEmpty)
        XCTAssertNil(routing.presentedID)
        events.apply(["type": "ready", "clientId": "new"])
        events.apply(["type": "waterfall", "eventId": "approve", "agentId": "A", "event": "approval/request"])
        routing.reconcile(events.pending, openSessionID: "A")
        XCTAssertEqual(routing.presentedID, "approve")
    }
    func testInteractionRoutingUnknownAgentsAndBilingualCounts() {
        let approval = PendingInteraction(id: "E", clientID: "C", agentID: "subagent", kind: "approval/request", request: [:])
        let missing = PendingInteraction(id: "M", clientID: "C", agentID: "", kind: "approval/request", request: [:])
        let question = PendingInteraction(id: "Q", clientID: "C", agentID: "A", kind: "user-questions/request", request: [:])
        XCTAssertNil(InteractionRouting.sessionID(approval, knownSessionIDs: ["A"]))
        XCTAssertNil(InteractionRouting.sessionID(missing, knownSessionIDs: [""]))
        XCTAssertTrue(InteractionRouting.forSession([missing], sessionID: "").isEmpty)
        var routing = InteractionRouting()
        routing.reconcile([approval, missing], openSessionID: "A")
        XCTAssertNil(routing.presentedID)
        routing.reconcile([], openSessionID: "A")
        XCTAssertNil(routing.presentedID)
        routing.review(approval)
        XCTAssertEqual(routing.presentedID, "E")
        XCTAssertEqual(InteractionRouting.label([approval], languages: ["en"]), "1 pending approval")
        XCTAssertEqual(InteractionRouting.label([approval, missing], languages: ["en"]), "2 pending approvals")
        XCTAssertEqual(InteractionRouting.label([approval], languages: ["zh-Hans"]), "1 个待处理授权")
        XCTAssertEqual(InteractionRouting.label([question], languages: ["en"]), "1 pending question")
        XCTAssertEqual(InteractionRouting.label([approval, question], languages: ["zh-Hans"]), "2 个待处理请求")
    }
    func testControlProjectionBaselinesDeltasAndQueueReplacement() {
        let chat = ChatStore(sessionID: "S", api: StubAPI())
        chat.applyControl(["type": "baseline", "value": ["projections": ["S": ["asOfSeq": 1, "values": ["plan": ["active": false, "pending": false], "agentPreset": "standard"]]]]])
        XCTAssertFalse(chat.planEnabled)
        chat.applyControl(["type": "projection", "sessionId": "other", "seq": 2, "changes": [["key": "plan", "val": ["active": true]]]])
        XCTAssertFalse(chat.planEnabled)
        chat.applyControl(["type": "projection", "sessionId": "S", "seq": 2, "changes": [["key": "plan", "val": ["active": false, "pending": true]], ["key": "agentPreset", "val": "minimal"]]])
        XCTAssertTrue(chat.planEnabled); XCTAssertEqual(chat.projections["agentPreset"], "minimal")
        chat.applyProjections(["asOfSeq": 1, "values": [:]])
        XCTAssertTrue(chat.planEnabled)
        chat.applyControl(["type": "connection-reset"])
        chat.applyControl(["type": "baseline", "value": ["projections": ["S": ["asOfSeq": 1, "values": ["plan": ["active": true, "pending": false]]]]]])
        XCTAssertTrue(chat.planEnabled)
        chat.applyState(["running": true, "queue": [["id": "host-id", "rpcId": "request-id", "placement": "queued", "content": [["type": "text", "text": "queued"]]]]])
        XCTAssertEqual(chat.queue.first?["id"], "host-id")
        chat.applyState(["running": false, "queue": .null])
        XCTAssertTrue(chat.queue.isEmpty); XCTAssertFalse(chat.running)
    }
    func fixture(_ name: String) throws -> JSON {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    }
    func snapshot(_ name: String) throws -> JSON {
        var value = try fixture(name)["result"]["value"]
        value["type"] = "snapshot"
        return value
    }
    func testHistorySnapshotAndToolResultPairing() throws {
        let chat = ChatStore(sessionID: "S", api: StubAPI())
        chat.apply(try snapshot("live-approval-events"))
        XCTAssertEqual(chat.transcript.filter { $0.role == "user" }.count, 3)
        XCTAssertEqual(chat.transcript.filter { $0.role == "assistant" }.count, 5)
        XCTAssertFalse(chat.transcript.contains { $0.role == "tool" })
        let calls = chat.transcript.flatMap(\.blocks).filter { $0.kind == "tool-call" }
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.result?["message"]["content"].array.first?["text"].text == "/Users/devin/fake-llm\n" })
        XCTAssertTrue(chat.transcript.first { $0.role == "assistant" }!.blocks.contains { $0.kind == "reasoning" })
        let before = chat.transcript
        chat.apply(try snapshot("live-approval-events"))
        XCTAssertEqual(chat.transcript, before)
    }
    func testCapturedRelayToolResultsPreserveHostOutput() throws {
        let capture = try fixture("live-relay-tool-results")
        for name in ["empty", "nonempty"] {
            var page = capture[name]
            page["type"] = "snapshot"
            let chat = ChatStore(sessionID: "S", api: StubAPI())
            chat.apply(page)
            let call = try XCTUnwrap(chat.transcript.flatMap(\.blocks).first { $0.kind == "tool-call" })
            let result = try XCTUnwrap(call.result)
            let captured = try XCTUnwrap(page["records"].array.last?["event"]["data"])
            XCTAssertEqual(result, captured)
            XCTAssertEqual(ToolPresentation.summary(call.arguments), "ls")
            XCTAssertFalse(result["message"]["isError"].boolean)
            let output = ToolPresentation.result(result)
            XCTAssertEqual(output, captured["message"]["content"].array.first?["text"].text)
            if name == "empty" { XCTAssertEqual(output, "(no output)") }
            else { XCTAssertTrue(output.contains("README.md\n")) }
            XCTAssertEqual(chat.transcript.count, 1)
            XCTAssertFalse(chat.transcript.contains { $0.role == "tool" })
        }
    }
    func testLiveChunksCommitAndOptimisticReconciliation() throws {
        let chat = ChatStore(sessionID: "S", api: StubAPI())
        let requestID = try fixture("live-hello-prompt-request")["payload"]["args"]["request"]["requestId"].text
        chat.addOptimistic(text: "hello", requestID: requestID)
        let frames = try fixture("live-hello-stream").array
        var sawStreaming = false
        for frame in frames where frame["streamId"] == "follow" {
            chat.apply(frame["value"])
            if let message = chat.inProgress, !message.text.isEmpty { sawStreaming = true }
            if chat.transcript.contains(where: { $0.role == "assistant" }) { XCTAssertNil(chat.inProgress) }
        }
        XCTAssertTrue(sawStreaming)
        XCTAssertEqual(chat.transcript.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(chat.transcript.filter { $0.role == "assistant" }.count, 1)
        XCTAssertFalse(chat.transcript.contains { $0.optimistic })
        XCTAssertTrue(chat.transcript.last!.text.contains("```sh"))
        let transcript = chat.transcript
        for frame in frames where frame["streamId"] == "follow" { chat.apply(frame["value"]) }
        XCTAssertEqual(chat.transcript, transcript)
        XCTAssertNil(chat.inProgress)
    }
    func testCompactExpansionAndReconnectActiveAttempt() throws {
        let event = try fixture("live-hello-events")["result"]["value"]["records"].array.first { $0["event"]["type"] == "assistant/message" }!["event"]
        let compact = event["data"]["stream"]
        var blocks: [TranscriptBlock] = []
        for chunk in CompactStream.expand(compact.array) { CompactStream.apply(chunk, to: &blocks) }
        XCTAssertEqual(blocks, event["data"]["message"]["content"].array.map(TranscriptBlock.init))
        let chat = ChatStore(sessionID: "S", api: StubAPI())
        chat.apply(["type": "snapshot", "records": [], "assistantStream": ["revision": 10, "activeAttempt": ["attemptId": "A", "turn": 1, "step": 1, "nextIndex": 12, "stream": compact]]])
        XCTAssertEqual(chat.inProgress?.blocks, blocks)
        chat.apply(["type": "assistant-stream", "frame": ["type": "chunk", "attemptId": "A", "revision": 10, "index": 11, "chunk": ["type": "text-delta", "index": 1, "text": "duplicate"]]])
        XCTAssertEqual(chat.inProgress?.blocks, blocks)
        chat.apply(["type": "assistant-stream", "frame": ["type": "end", "attemptId": "A", "revision": 11, "outcome": ["kind": "abandoned"]]])
        XCTAssertNil(chat.inProgress)
    }
    func testSurfaceReplacementAndUnknownEvents() {
        let chat = ChatStore(sessionID: "S", api: StubAPI())
        func user(_ seq: Int, _ text: String, op: JSON = "append") -> JSON { ["type": "event", "event": ["seq": .int(seq), "type": "user/message", "surfaceOp": op, "data": ["id": .string("u\(seq)"), "content": [["type": "text", "text": .string(text)]]]]] }
        chat.apply(user(1, "one")); chat.apply(user(2, "two")); chat.apply(user(3, "three"))
        chat.apply(user(4, "replacement", op: ["op": "replace", "startSeq": 1, "endSeq": 2]))
        chat.apply(["type": "event", "event": ["seq": 5, "type": "future/plugin", "data": [:]]])
        XCTAssertEqual(chat.transcript.map(\.text), ["replacement", "three"])
        chat.apply(user(6, "replacement again", op: ["op": "replace", "startSeq": 4, "endSeq": 3]))
        XCTAssertEqual(chat.transcript.map(\.text), ["replacement again"])
    }
    func testInteractionsFromLiveEventsAndGenerationReset() async throws {
        let api = StubAPI()
        let events = RemoteEvents(api: api)
        for frame in try fixture("live-stream-all").array where frame["streamId"] == "events" { events.apply(frame["value"]) }
        let pending = try XCTUnwrap(events.pending.first)
        XCTAssertEqual(pending.kind, "approval/request")
        XCTAssertEqual(pending.request["toolName"], "bash")
        try await events.answerApproval(pending.id, allow: true)
        XCTAssertEqual(api.calls.last?.0, "$events/result")
        XCTAssertEqual(api.calls.last?.1["clientId"].text, pending.clientID)
        XCTAssertEqual(api.calls.last?.1["outcome"]["value"], "allowed-once")
        XCTAssertTrue(events.pending.isEmpty)
        events.apply(["type": "waterfall", "event": "user-questions/request", "eventId": "Q", "agentId": "S", "request": ["questions": []]])
        try await events.answerQuestions("Q", answers: [["id": "q1", "selected": ["Yes"]]])
        XCTAssertEqual(api.calls.last?.1["outcome"]["value"]["answers"].array.count, 1)
        events.apply(["type": "waterfall", "event": "approval/request", "eventId": "E", "request": [:]])
        events.apply(["type": "cancel", "eventId": "E"])
        XCTAssertTrue(events.pending.isEmpty)
        events.apply(["type": "connection-reset"])
        XCTAssertNil(events.clientID)
        do { try await events.answerApproval("E", allow: false); XCTFail("Stale approval answered") } catch { XCTAssertEqual(error as? APIError, .disconnected) }
    }
    func testWorkspaceGroupingWaitsForInitialAndReconnectBaselines() {
        let store = SidebarStore(api: StubAPI())
        var misplacedWorkspaceSession = false
        let observation = store.objectWillChange.sink {
            if store.groups.contains(where: { $0.id == "ungrouped" && $0.sessions.contains { $0.id == "A" } }) {
                misplacedWorkspaceSession = true
            }
        }
        defer { observation.cancel() }
        store.applySessions(["items": [["sessionId": "A"], ["sessionId": "B"]]])
        XCTAssertFalse(store.loaded)
        XCTAssertTrue(store.groups.isEmpty)
        store.applyEvent(["type": "emit", "event": "api-session/added", "args": [["sessionId": "C"]]])
        XCTAssertTrue(store.groups.isEmpty)
        store.applyWorkspace(["type": "baseline", "value": ["items": [["workspaceId": "W", "title": "Workspace", "sessionIds": ["A"]]], "pinnedSessionIds": ["B"], "archivedSessionIds": ["C"]]])
        XCTAssertTrue(store.loaded)
        XCTAssertEqual(store.groups.first { $0.id == "W" }?.sessions.map(\.id), ["A"])
        XCTAssertEqual(store.groups.first?.sessions.map(\.id), ["B"])
        XCTAssertTrue(store.groups.last!.sessions.isEmpty)
        store.applyWorkspace(["type": "connection-reset"])
        XCTAssertFalse(store.loaded)
        XCTAssertTrue(store.groups.isEmpty)
        store.applySessions(["items": [["sessionId": "A"], ["sessionId": "B"], ["sessionId": "C"], ["sessionId": "D"]]])
        store.applyWorkspace(["type": "upsert", "workspace": ["workspaceId": "W2", "title": "Second", "sessionIds": ["A", "D"]]])
        XCTAssertTrue(store.groups.isEmpty)
        store.applyWorkspace(["type": "baseline", "value": ["items": [["workspaceId": "W2", "title": "Second", "sessionIds": ["A", "D"]]], "pinnedSessionIds": ["B"], "archivedSessionIds": ["C"]]])
        XCTAssertEqual(store.groups.first { $0.id == "W2" }?.sessions.map(\.id), ["A", "D"])
        XCTAssertTrue(store.groups.last!.sessions.isEmpty)
        XCTAssertFalse(misplacedWorkspaceSession)
        store.stop()
        XCTAssertFalse(store.loaded)
        XCTAssertTrue(store.groups.isEmpty)
    }
    func testWorkspaceEmptyBaselineAndBaselineBeforeSessions() {
        let store = SidebarStore(api: StubAPI())
        store.applyWorkspace(["type": "baseline", "value": ["items": []]])
        XCTAssertTrue(store.loaded)
        XCTAssertTrue(store.groups.allSatisfy { $0.sessions.isEmpty })
        store.applySessions(["items": [["sessionId": "A"]]])
        XCTAssertEqual(store.groups.last?.sessions.map(\.id), ["A"])
        store.applyWorkspace(["type": "connection-reset"])
        XCTAssertTrue(store.groups.isEmpty)
        store.applyWorkspace(["type": "baseline", "value": ["items": [["workspaceId": "W", "sessionIds": ["A"]]]]])
        store.applySessions(["items": [["sessionId": "A"], ["sessionId": "B"]]])
        XCTAssertEqual(store.groups.first { $0.id == "W" }?.sessions.map(\.id), ["A"])
        XCTAssertEqual(store.groups.last?.sessions.map(\.id), ["B"])
    }
    func testWorkspaceBaselineDeltasAndGrouping() throws {
        let store = SidebarStore(api: StubAPI())
        let create = try fixture("live-session-create")["result"]["value"]["sessionId"]
        let summary: JSON = ["sessionId": create, "updatedAt": 1, "projections": ["values": ["title": "Fixture conversation"]]]
        store.applySessions(["items": [summary, ["sessionId": "other", "updatedAt": 2]]])
        store.applyWorkspace(["type": "baseline", "value": ["items": [["workspaceId": "W", "title": "Workspace", "path": "/workspace", "sessionIds": [create]]], "pinnedSessionIds": [], "archivedSessionIds": []]])
        XCTAssertEqual(store.groups.first { $0.id == "W" }?.sessions.first?.title, "Fixture conversation")
        XCTAssertEqual(store.groups.last?.sessions.map(\.id), ["other"])
        store.applyWorkspace(["type": "pinned", "pinnedSessionIds": [create]])
        XCTAssertEqual(store.groups.first?.sessions.count, 1)
        XCTAssertTrue(store.groups.first { $0.id == "W" }!.sessions.isEmpty)
        store.applyWorkspace(["type": "archived", "archivedSessionIds": [create]])
        XCTAssertTrue(store.groups.first!.sessions.isEmpty)
        store.applyWorkspace(["type": "upsert", "workspace": ["workspaceId": "W2", "title": "Second", "sessionIds": []]])
        store.applyWorkspace(["type": "order", "workspaceIds": ["W2", "W"]])
        XCTAssertEqual(store.workspaces.map(\.id), ["W2", "W"])
        store.applyWorkspace(["type": "remove", "workspaceId": "W"])
        XCTAssertEqual(store.workspaces.map(\.id), ["W2"])
        store.applyWorkspace(["type": "replace", "value": ["items": [], "archivedSessionIds": [], "pinnedSessionIds": []]])
        XCTAssertEqual(store.groups.last?.sessions.count, 2)
        store.applyEvent(["type": "emit", "event": "api-session/status", "args": [create, true]])
        XCTAssertTrue(store.sessions[create.text]!.running)
        store.applyEvent(["type": "emit", "event": "api-session/activity", "args": [create, 42]])
        XCTAssertEqual(store.sessions[create.text]?.updatedAt.int, 42)
        store.applyControl(["type": "projection", "sessionId": create, "changes": [["key": "title", "val": "Renamed"]]])
        XCTAssertEqual(store.sessions[create.text]?.title, "Renamed")
        store.applyEvent(["type": "emit", "event": "api-session/removed", "args": [create]])
        XCTAssertNil(store.sessions[create.text])
        store.applyEvent(["type": "emit", "event": "api-session/added", "args": [summary]])
        XCTAssertEqual(store.sessions[create.text]?.title, "Fixture conversation")
    }
    func testCapturedWorkspaceBaselineAndDeltas() throws {
        let frames = try fixture("live-workspace-stream").array
        let fixtureWorkspace = try XCTUnwrap(frames.first { $0["workspace"]["title"] == "Native fixture workspace" })["workspace"]
        let session = try XCTUnwrap(fixtureWorkspace["sessionIds"].array.first)
        let store = SidebarStore(api: StubAPI())
        let ids = Set(frames.flatMap { frame in (frame["value"]["items"].array + [frame["workspace"]]).flatMap { $0["sessionIds"].array.map(\.text) } })
        store.applySessions(["items": .array(ids.map { ["sessionId": .string($0), "projections": ["values": ["title": "Captured session"]]] })])
        var sawPinned = false
        var sawGrouped = false
        for frame in frames {
            store.applyWorkspace(frame)
            if store.pinnedIDs.contains(session.text) {
                sawPinned = true
                XCTAssertTrue(store.groups.first!.sessions.contains { $0.id == session.text })
                XCTAssertFalse(store.groups.first { $0.id == fixtureWorkspace["workspaceId"].text }!.sessions.contains { $0.id == session.text })
            } else if store.groups.first(where: { $0.id == fixtureWorkspace["workspaceId"].text })?.sessions.contains(where: { $0.id == session.text }) == true { sawGrouped = true }
        }
        XCTAssertTrue(sawPinned); XCTAssertTrue(sawGrouped)
        XCTAssertTrue(store.archivedIDs.contains(session.text))
        XCTAssertFalse(store.workspaces.contains { $0.id == fixtureWorkspace["workspaceId"].text })
        XCTAssertFalse(store.groups.flatMap(\.sessions).contains { $0.id == session.text })
    }
    func testFullLiveStreamIncludingToolDeltas() throws {
        let chat = ChatStore(sessionID: "S", api: StubAPI())
        var sawToolDelta = false
        for frame in try fixture("live-stream-all").array where frame["streamId"] == "follow" {
            chat.apply(frame["value"])
            if chat.inProgress?.blocks.contains(where: { $0.kind == "tool-call" && $0.name == "bash" && $0.arguments.contains("pwd") }) == true { sawToolDelta = true }
        }
        XCTAssertTrue(sawToolDelta)
        XCTAssertNil(chat.inProgress)
        XCTAssertEqual(chat.transcript.filter { $0.role == "assistant" }.count, 5)
        XCTAssertEqual(chat.transcript.flatMap(\.blocks).filter { $0.kind == "tool-call" && $0.result != nil }.count, 2)
        XCTAssertFalse(chat.transcript.contains { $0.role == "tool" })
    }
    func testActionsFailureEmptySendAndPagination() async throws {
        let api = StubAPI()
        let chat = ChatStore(sessionID: "S", api: api)
        do { try await chat.send(" \n"); XCTFail("Empty prompt sent") } catch { XCTAssertTrue(api.calls.isEmpty) }
        api.failure = APIError.sessionExpired
        do { try await chat.send("hello"); XCTFail("Failure swallowed") } catch { XCTAssertEqual(error as? APIError, .sessionExpired) }
        XCTAssertNotNil(chat.transcript.first?.deliveryError)
        api.failure = nil; api.response = ["accepted": true]
        chat.applyState(["running": true]); try await chat.send("steer", steer: true)
        let request = api.calls.last!.1["request"]
        XCTAssertEqual(request["mode"], "steer")
        XCTAssertNotNil(UUID(uuidString: request["requestId"].text))
        XCTAssertEqual(request["clientTimeZone"].text, TimeZone.current.identifier)
        try await chat.cancel(); XCTAssertEqual(api.calls.last?.0, "session/cancel")
        var page = try snapshot("live-hello-events"); page["hasMore"] = true
        chat.apply(page)
        api.response = ["records": [], "hasMore": false]
        try await chat.loadOlder()
        XCTAssertEqual(api.calls.last?.0, "session/events")
        XCTAssertEqual(api.calls.last?.1["request"]["throughSeq"], page["cursor"])
        XCTAssertEqual(api.calls.last?.1["request"]["beforeSeq"], 0)
        XCTAssertFalse(chat.hasMore)
        let count = api.calls.count; try await chat.loadOlder(); XCTAssertEqual(api.calls.count, count)
    }
    func testEnvelopeErrorsAndPathPrefix() throws {
        let api = PortalAPI(base: try PortalURL.normalize("https://relay.example/__t/id"))
        XCTAssertEqual(api.request("api/session/list").url?.absoluteString, "https://relay.example/__t/id/api/session/list")
        XCTAssertEqual(api.request("api/session/list").value(forHTTPHeaderField: "Origin"), "https://relay.example")
        XCTAssertEqual(api.request("api/session/list").value(forHTTPHeaderField: "User-Agent"), PortalClient.userAgent)
        let envelope = PortalAPI.envelope("session/list", args: ["_request": [:]], id: "id")
        XCTAssertEqual(envelope["payload"]["args"], ["_request": [:]])
        XCTAssertEqual(envelope["rpcId"], "id")
        XCTAssertEqual(try PortalAPI.decode(JSONEncoder().encode(fixture("live-model-catalog")), status: 200)["default"]["provider"], "local-fake")
        XCTAssertThrowsError(try PortalAPI.decode(Data(), status: 401)) { XCTAssertEqual($0 as? APIError, .sessionExpired) }
        XCTAssertThrowsError(try PortalAPI.decode(Data(), status: 503)) { XCTAssertEqual($0 as? APIError, .http(503)) }
        XCTAssertThrowsError(try PortalAPI.decode(Data("not json".utf8), status: 200)) { XCTAssertEqual($0 as? APIError, .invalidResponse) }
        let error: JSON = ["type": "server-response", "result": ["ok": false, "error": ["code": "model/missing", "message": "Select a model"]]]
        XCTAssertThrowsError(try PortalAPI.decode(JSONEncoder().encode(error), status: 200)) { XCTAssertEqual($0 as? APIError, .remote("model/missing", "Select a model")) }
        let void: JSON = ["type": "server-response", "result": ["ok": true]]
        XCTAssertEqual(try PortalAPI.decode(JSONEncoder().encode(void), status: 200), .null)
    }
    func testCookiesPersistAllNamesAndIsolateBaseIncludingPorts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = URL(string: "http://localhost:3081/__t/one/")!
        let vault = CookieVault(root: root)
        for (name, value) in [("dsh_portal", "portal"), ("dsh-auth-demo", "upstream"), ("other", "additional")] {
            let response = HTTPURLResponse(url: base, statusCode: 303, httpVersion: nil, headerFields: ["Set-Cookie": "\(name)=\(value); Path=/; HttpOnly; Max-Age=3600"])!
            try vault.ingest(response, base: base)
        }
        let restored = CookieVault(root: root)
        XCTAssertEqual(Set(restored.cookies(for: base, at: base).map(\.name)), ["dsh_portal", "dsh-auth-demo", "other"])
        let otherBase = URL(string: "http://localhost:3082/__t/one/")!
        XCTAssertTrue(restored.cookies(for: otherBase, at: otherBase).isEmpty)
        let otherPrefix = URL(string: "http://localhost:3081/__t/two/")!
        XCTAssertTrue(restored.cookies(for: otherPrefix, at: otherPrefix).isEmpty)
        let update = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "dsh-auth-demo=renewed; Path=/; Max-Age=3600"])!
        try restored.ingest(update, base: base)
        XCTAssertEqual(restored.cookies(for: base, at: base).first { $0.name == "dsh-auth-demo" }?.value, "renewed")
        let deletion = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "other=; Path=/; Max-Age=0"])!
        try restored.ingest(deletion, base: base)
        XCTAssertFalse(restored.cookies(for: base, at: base).contains { $0.name == "other" })
        try restored.clear(base)
        XCTAssertTrue(CookieVault(root: root).cookies(for: base, at: base).isEmpty)
    }
}
