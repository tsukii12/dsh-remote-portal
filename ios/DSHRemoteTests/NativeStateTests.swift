import XCTest
@testable import DSHRemote

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
