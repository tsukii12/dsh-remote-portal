import XCTest
import Combine
import SwiftUI
@testable import DSHRemote

@MainActor
private final class SidebarLifetime: ObservableObject {
    let id = UUID()
}

private struct SidebarLifetimeView: View {
    @StateObject private var lifetime = SidebarLifetime()
    let record: (UUID) -> Void
    var body: some View { Text("Sidebar").onAppear { record(lifetime.id) } }
}

@MainActor
private final class RecoveryAPI: RPCServing {
    var follow: AsyncThrowingStream<JSON, Error>.Continuation?
    var openings = 0
    var failModels = false
    var failState = false
    var state: JSON = ["running": false, "queue": []]
    var stateGate: CheckedContinuation<JSON, Error>?
    var holdState = false
    var onRead: (() -> Void)?
    var commandReply: JSON = ["result": ["kind": "text", "text": "permission danger-full-access"]]
    func rpc(_ method: String, args: JSON) async throws -> JSON {
        if method == "session/state" {
            if failState { throw APIError.http(503) }
            if holdState { return try await withCheckedThrowingContinuation { stateGate = $0; onRead?() } }
            return state
        }
        if method == "session/modelCatalog", failModels { throw APIError.http(503) }
        if method == "commands/execute" { return commandReply }
        return [:]
    }
    func stream(_ endpoint: String, args: JSON) -> AsyncThrowingStream<JSON, Error> {
        AsyncThrowingStream { continuation in
            if endpoint == "session/follow" { follow = continuation; openings += 1 }
        }
    }
}

@MainActor
final class Round4Tests: XCTestCase {
    func testGoalCommandInputEchoAndResultRemainSeparate() {
        for (args, text) in [(" 中文目标  \n", "/goal 中文目标"), ("", "/goal")] {
            let items = ChatTranscriptProjection.project([
                ["type": "command/run", "seq": 1, "data": ["commandId": "G", "name": "goal", "args": .string(args)]],
                ["type": "command/done", "seq": 2, "data": ["commandId": "G", "kind": "error", "text": "Failed"]]
            ])
            XCTAssertEqual(items.map(\.role), ["command-input", "command"])
            XCTAssertEqual(items.first?.text, text)
            XCTAssertEqual(items.last?.blocks.first?.raw["outcome"], "error")
        }
        XCTAssertFalse(ChatTranscriptProjection.project([["type": "command/done", "seq": 1, "data": ["commandId": "partial", "kind": "success"]]]).contains { $0.role == "command-input" })
    }
    func testWebProcessFoldingKeepsRepliesInputsAndTerminalNoticesIndependent() {
        let user = TranscriptItem(id: "u", role: "user", blocks: [], turn: 1, turnOutcome: "completed")
        let first = TranscriptItem(id: "a", role: "assistant", blocks: [TranscriptBlock(["type": "text", "text": "First reply"])], turn: 1, turnOutcome: "completed")
        let second = TranscriptItem(id: "b", role: "assistant", blocks: [TranscriptBlock(["type": "text", "text": "Final reply"])], turn: 1, turnOutcome: "completed")
        let command = TranscriptItem(id: "c", role: "command", blocks: [], turn: 1)
        let context = TranscriptItem(id: "d", role: "context", blocks: [], turn: 1)
        let notice = TranscriptItem(id: "n", role: "notice", blocks: [TranscriptBlock(["type": "system-notice", "text": "Stopped"])], turn: 1)
        let turn = TranscriptTurn(id: "turn", items: [user, context, first, command, second])
        XCTAssertTrue(turn.canCollapse)
        XCTAssertTrue(turn.independent(user)); XCTAssertTrue(turn.independent(notice))
        XCTAssertFalse(turn.independent(command)); XCTAssertFalse(turn.independent(context))
        XCTAssertEqual(turn.items.filter { $0.role == "assistant" }.map(\.text), ["First reply", "Final reply"])
        XCTAssertFalse(TranscriptTurn(id: "steer", items: [first, user, second]).canCollapse)
        XCTAssertFalse(TranscriptTurn(id: "empty", items: []).canCollapse)
        var stopped = first; stopped.turnOutcome = "error"
        XCTAssertFalse(TranscriptTurn(id: "error", items: [user, stopped]).canCollapse)
    }
    func testCommandAcknowledgementRetiresWhenItsDurableCardArrives() async throws {
        let api = RecoveryAPI()
        api.commandReply = ["commandId": "C", "result": ["kind": "success", "text": "Receipt"]]
        let chat = ChatStore(sessionID: "fixture", api: api)
        try await chat.executeCommand("/example")
        XCTAssertEqual(chat.visibleCommandNotice, "Receipt")
        chat.apply(["type": "event", "event": ["type": "command/run", "seq": 1, "data": ["commandId": "C", "name": "example"]]])
        chat.apply(["type": "event", "event": ["type": "command/done", "seq": 2, "data": ["commandId": "C", "kind": "success", "text": "Receipt"]]])
        XCTAssertEqual(chat.commandNotice, "Receipt"); XCTAssertNil(chat.visibleCommandNotice)
        XCTAssertEqual(chat.transcript.filter { $0.role == "command" }.count, 1)
        api.commandReply = ["commandId": "empty", "result": ["kind": "success"]]
        try await chat.executeCommand("/empty"); XCTAssertNil(chat.visibleCommandNotice)
        api.commandReply = ["commandId": "error", "result": ["kind": "error", "text": "Failed"]]
        do { try await chat.executeCommand("/error"); XCTFail("Error swallowed") } catch { XCTAssertNil(chat.visibleCommandNotice) }
        api.commandReply = ["commandId": "permission", "result": ["kind": "success", "text": "preset danger-full-access"]]
        try await chat.executeCommand("/permission danger-full-access"); XCTAssertNil(chat.commandNotice)
    }
    func testWebProjectionSuppressesInternalRecordsAndGroupsContext() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "r7-local-projection", withExtension: "json"))
        let fixture = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
        let events = fixture["records"].array.map { $0["event"] }
        let projected = ChatTranscriptProjection.project(events)
        let suppressed = Set(["permission/preset", "sandbox/mode", "approval/policy", "turn/end", "command/run", "command/done", "system/message", "request/header", "request/context", "step/start", "step/end", "session/title", "approval/asked", "approval/decided"])
        XCTAssertTrue(projected.flatMap(\.blocks).allSatisfy { !suppressed.contains($0.kind) })
        XCTAssertTrue(projected.contains { $0.role == "context" && $0.blocks.first?.raw["source"]["kind"] == "time-context" })
        XCTAssertFalse(projected.filter { $0.role == "user" }.contains { $0.text.contains("Time sampled") || $0.text.contains("Browser time zone") })
        XCTAssertTrue(projected.contains { $0.blocks.contains { $0.kind == "tool-call" && $0.result != nil } })
        XCTAssertTrue(projected.contains { $0.blocks.contains { $0.kind == "text" && $0.text.contains("Local native chat demo") } })
        XCTAssertEqual(projected.filter { $0.role == "user" }.count, events.filter { $0["type"] == "user/message" && $0["surfaceOp"] == "append" && $0["data"]["source"]["kind"] == "user" }.count)
        for type in Set(events.map { $0["type"].text }).sorted() {
            let isolated = ChatTranscriptProjection.project(events.filter { $0["type"].text == type })
            if suppressed.contains(type), !["turn/end", "command/run", "command/done"].contains(type) { XCTAssertTrue(isolated.isEmpty, type) }
        }
        let repeated = ChatTranscriptProjection.project(fixture["r6Repeated"].array.map { $0["event"] })
        XCTAssertEqual(repeated.count, 3)
        XCTAssertEqual(Set(repeated.compactMap(\.requestID)).count, 3)
        XCTAssertEqual(Set(repeated.compactMap(\.messageID)).count, 3)
        let interrupted = ChatTranscriptProjection.project(fixture["interrupted"].array.map { $0["event"] })
        XCTAssertFalse(interrupted.isEmpty)
        XCTAssertTrue(interrupted.allSatisfy { $0.interrupted && $0.blocks.allSatisfy(ChatTranscriptProjection.visible) })
        let pendingChat = ChatStore(sessionID: "fixture", api: RecoveryAPI())
        for message in fixture["pendingState"]["queue"].array {
            pendingChat.addOptimistic(text: message["content"].array.first?["text"].text ?? "", requestID: message["rpcId"].text)
        }
        pendingChat.applyState(fixture["pendingState"])
        XCTAssertEqual(pendingChat.queue.count, 1)
        XCTAssertEqual(pendingChat.transcript.count, 1)
        XCTAssertTrue(pendingChat.transcript[0].steering)
    }
    func testWebQueueOptimisticAndDurableIdentityReconciliation() {
        let chat = ChatStore(sessionID: "fixture", api: RecoveryAPI())
        chat.addOptimistic(text: "DRP测试 r6 slow queue", requestID: "rpc")
        let message: JSON = ["id": "message", "placement": "queued", "rpcId": "rpc", "source": ["kind": "user", "rpcId": "rpc"], "content": [["type": "text", "text": "DRP测试 r6 slow queue"]]]
        chat.applyState(["running": true, "queue": [message]])
        XCTAssertEqual(chat.queue.count, 1); XCTAssertTrue(chat.transcript.isEmpty)
        chat.apply(["type": "event", "event": ["type": "user/message", "seq": 1, "surfaceOp": "append", "data": message]])
        XCTAssertTrue(chat.queue.isEmpty); XCTAssertEqual(chat.transcript.map(\.text), ["DRP测试 r6 slow queue"])
        chat.applyState(["running": false, "queue": [message]])
        XCTAssertTrue(chat.queue.isEmpty); XCTAssertFalse(chat.transcript.contains { $0.optimistic })
        var second = message; second["id"] = "second"; second["source"]["rpcId"] = "other"
        chat.apply(["type": "event", "event": ["type": "user/message", "seq": 2, "surfaceOp": "append", "data": second]])
        XCTAssertEqual(chat.transcript.count, 2)
        XCTAssertTrue(ChatTranscriptProjection.project([]).isEmpty)
    }
    func testWebAssistantVisibilityAndTerminalReasons() {
        func assistant(_ seq: Int, _ content: [JSON], interrupted: Bool = false) -> JSON {
            ["seq": .int(seq), "type": "assistant/message", "surfaceOp": "append", "data": ["turn": 1, "step": .int(seq), "interrupted": .bool(interrupted), "message": ["content": .array(content)]]]
        }
        let empty = assistant(1, [["type": "reasoning", "text": " \n"]])
        let reply = assistant(2, [["type": "reasoning", "text": "Consider"], ["type": "text", "text": "First reply"]])
        let next = assistant(3, [["type": "text", "text": "Final reply"]])
        let partial = assistant(4, [["type": "reasoning", "text": "Interrupted evidence"]], interrupted: true)
        let projected = ChatTranscriptProjection.project([empty, reply, next, partial])
        XCTAssertEqual(projected.count, 3)
        XCTAssertEqual(projected.filter { !$0.text.isEmpty }.map(\.text), ["First reply", "Final reply"])
        XCTAssertTrue(projected.last!.interrupted)
        XCTAssertFalse(ChatTranscriptProjection.visible(TranscriptBlock(["type": "reasoning", "text": ""])))
        XCTAssertTrue(ChatTranscriptProjection.project([["seq": 5, "type": "assistant/attempt", "data": ["stream": [["type": "reasoning-chunks", "index": 0, "texts": ["trajectory only"]]]]]]).isEmpty)
        for kind in ["completed", "aborted", "blocked"] {
            let event: JSON = ["seq": 9, "type": "turn/end", "data": ["turn": 1, "reason": ["kind": .string(kind)]]]
            let result = ChatTranscriptProjection.project([reply, event])
            XCTAssertEqual(result.count, 1, kind); XCTAssertEqual(result[0].turnOutcome, kind)
        }
        for kind in ["error", "interrupted", "max-tokens"] {
            let event: JSON = ["seq": 9, "type": "turn/end", "data": ["turn": 1, "reason": ["kind": .string(kind), "error": ["code": "AUTH", "message": "sensitive provider detail"]]]]
            let result = ChatTranscriptProjection.project([reply, event])
            XCTAssertEqual(result.count, 2, kind)
            XCTAssertFalse(result.flatMap(\.blocks).contains { $0.raw.formatted.contains("sensitive provider detail") })
        }
    }
    func testWebCommandsCompactionAndFallbackBoundaries() {
        func command(_ seq: Int, _ name: String, args: String = "", outcome: String = "success") -> [JSON] {
            [["seq": .int(seq), "type": "command/run", "data": ["commandId": .string(name), "name": .string(name), "args": .string(args)]], ["seq": .int(seq + 1), "type": "command/done", "data": ["commandId": .string(name), "kind": .string(outcome), "text": "receipt"]]]
        }
        XCTAssertTrue(ChatTranscriptProjection.project(command(1, "permission", outcome: "error")).isEmpty)
        XCTAssertTrue(ChatTranscriptProjection.project(command(1, "team", args: " on ")).isEmpty)
        XCTAssertEqual(ChatTranscriptProjection.project(command(1, "team", args: "off", outcome: "error")).count, 1)
        XCTAssertEqual(ChatTranscriptProjection.project(command(1, "export")).count, 1)
        XCTAssertEqual(ChatTranscriptProjection.project([command(1, "export")[1]]).count, 1)
        let internalEvent: JSON = ["seq": 1, "type": "future/plugin", "surfaceOp": "append", "data": ["value": "hidden"]]
        XCTAssertTrue(ChatTranscriptProjection.project([internalEvent]).isEmpty)
        let opaque: JSON = ["seq": 2, "type": "assistant/message", "surfaceOp": "append", "data": ["message": ["content": [["type": "future/block", "payload": "kept"]]]]]
        XCTAssertEqual(ChatTranscriptProjection.project([opaque]).first?.blocks.first?.raw["payload"], "kept")
        let orphan: JSON = ["seq": 3, "type": "tool/result", "surfaceOp": "append", "data": ["message": ["toolCallId": "absent", "content": [["type": "future/result", "payload": "kept"]]]]]
        XCTAssertEqual(ChatTranscriptProjection.project([orphan]).first?.blocks.first?.kind, "unknown-surface")
        let start: JSON = ["seq": 3, "type": "compaction/start", "data": ["compactionId": "C"]]
        let summary: JSON = ["seq": 4, "type": "compaction/summary", "data": ["compactionId": "C", "summary": [["type": "text", "text": "Summary"]]]]
        let checkpoint: JSON = ["seq": 5, "type": "user/message", "surfaceOp": ["op": "replace", "startSeq": 1, "endSeq": 3], "data": ["source": ["kind": "compact-checkpoint", "compactionId": "C"], "content": [["type": "text", "text": "model history"]]]]
        XCTAssertTrue(ChatTranscriptProjection.project([start, summary]).isEmpty)
        XCTAssertEqual(ChatTranscriptProjection.project([start, summary, checkpoint]).first?.blocks.first?.text, "Summary")
        var manual = checkpoint; manual["data"]["source"]["sourceCommandId"] = "compact"
        XCTAssertEqual(ChatTranscriptProjection.project(command(1, "compact") + [summary, manual]).flatMap(\.blocks).map(\.kind), ["compaction"])
    }
    func testWebContextFormsUseOpaqueFallbackForMalformedSources() {
        let sources: [JSON] = [
            ["kind": "instructions", "form": "instructions", "changes": [["path": "AGENTS.md", "action": "set"]]],
            ["kind": "skills", "form": "catalog", "entries": []],
            ["kind": "time-context", "form": "snapshot", "sections": [["name": "time", "text": "Time sampled…"]]],
            ["kind": "notice", "form": "notice", "summary": "Policy changed"],
            ["kind": "agent", "form": "relay", "senderSessionId": "sender"],
            ["kind": "session-reference", "form": "recall", "references": [["label": "Earlier", "retainedMessages": 1, "omittedMessages": 2, "truncated": true]]]
        ]
        for source in sources {
            let block = TranscriptBlock(["type": "context", "source": source, "content": [["type": "text", "text": "one"], ["type": "text", "text": "two"], ["type": "future/context", "payload": 42]]])
            XCTAssertEqual(ChatTranscriptProjection.contextBody(block).form, source["form"].text)
            var malformed = block; malformed.raw["source"] = ["form": source["form"]]
            let fallback = ChatTranscriptProjection.contextBody(malformed)
            XCTAssertNil(fallback.form)
            XCTAssertEqual(fallback.rows.first?["text"], "onetwo")
            XCTAssertTrue(fallback.rows.contains { $0["text"].text.contains("future/context") })
        }
        XCTAssertTrue(ChatTranscriptProjection.contextBody(TranscriptBlock([:])).rows.isEmpty)
        XCTAssertTrue(ChatTranscriptProjection.bounded(String(repeating: "月", count: 20_001)).contains("20001"))
    }
    func testHostQueueContextWaitsForItsDurableContextRowAndIsNeverEditable() {
        let chat = ChatStore(sessionID: "fixture", api: RecoveryAPI())
        let notice: JSON = ["id": "approval", "placement": "context", "content": [["type": "text", "text": "The user changed the approval policy."]]]
        let prompt: JSON = ["id": "prompt", "source": ["kind": "user", "rpcId": "request"], "placement": "queued", "content": [["type": "text", "text": "My queued prompt"]]]
        let legacy: JSON = ["id": "legacy", "content": [["type": "text", "text": "Legacy prompt"]]]
        let unknown: JSON = ["id": "plugin", "source": ["kind": "future-plugin"], "content": [["type": "text", "text": "Host context"]]]
        chat.applyState(["running": false, "queue": [notice, prompt, legacy, unknown]])
        XCTAssertEqual(chat.queue.map { $0["id"].text }, ["prompt", "legacy"])
        XCTAssertTrue(chat.transcript.isEmpty)
        var committed = notice; committed["source"] = ["kind": "user-approval"]
        chat.apply(["type": "event", "event": ["type": "user/message", "seq": 1, "data": committed]])
        XCTAssertEqual(chat.transcript.filter { $0.messageID == "approval" }.count, 1)
        XCTAssertEqual(chat.transcript.first?.role, "context")
        XCTAssertEqual(chat.transcript.first?.blocks.first?.text, "The user changed the approval policy.")
        chat.applyState(["running": false, "queue": []])
        XCTAssertTrue(chat.queue.isEmpty)
        XCTAssertEqual(chat.transcript.count, 1)
        chat.applyState(["queue": [prompt]])
        XCTAssertTrue(chat.queue.isEmpty)
        XCTAssertEqual(chat.transcript.count, 1)
    }
    func testSystemNoticesStayOutsideCollapsedTurnsAndSummaryCounts() {
        let items = [TranscriptItem(id: "u", role: "user", blocks: []), TranscriptItem(id: "a", role: "assistant", blocks: [TranscriptBlock(["type": "text", "text": "Reply"])]), TranscriptItem(id: "n", role: "notice", blocks: [TranscriptBlock(["type": "system-notice", "text": "Policy changed"])]), TranscriptItem(id: "next", role: "user", blocks: [])]
        let turns = TranscriptTurn.group(items)
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns[0].items.contains { $0.id == "n" })
        XCTAssertFalse(turns[0].detailItems.contains { $0.id == "n" })
        XCTAssertEqual(turns[0].messageCount, 2)
        XCTAssertTrue(TranscriptTurn.group([]).isEmpty)
    }
    func testAccessPickerDoesNotRepeatItsValueAsACommandCaption() async throws {
        let chat = ChatStore(sessionID: "fixture", api: RecoveryAPI())
        try await chat.executeCommand("/example")
        XCTAssertEqual(chat.commandNotice, L("Full access", "完全权限"))
        var captions: [String?] = []
        let subscription = chat.$commandNotice.dropFirst().sink { captions.append($0) }
        defer { subscription.cancel() }
        try await chat.selectPermission("danger-full-access")
        XCTAssertNil(chat.commandNotice)
        XCTAssertTrue(captions.allSatisfy { $0 == nil })
    }
    func testScannedServerAcceptsVisitorAndLANAddressesWithoutLosingPrefixes() throws {
        for address in ["https://relay.example:8443/__t/fixture/", "http://192.168.1.20:3081/"] {
            let target = try PortalURL.scannedServer(address)
            XCTAssertEqual(target.base.absoluteString, address); XCTAssertEqual(target.token, "")
        }
        let target = try PortalURL.scannedServer(" https://relay.example/__t/fixture/__portal/pair?t=fixture%2Btoken ")
        XCTAssertEqual(target.base.absoluteString, "https://relay.example/__t/fixture/")
        XCTAssertEqual(target.token, "fixture+token")
        XCTAssertEqual(try PortalURL.scannedServer("http://host.local:3081").base.absoluteString, "http://host.local:3081/")
    }
    func testScannedServerRejectsEmptyMalformedAndNonHTTPValues() {
        for value in ["", "   ", "hello", "http://", "https://", "file:///tmp/qr", "ftp://example.com/", "javascript:alert(1)", "https://user:secret@example.com/", "https://relay.example/__portal/pair"] {
            XCTAssertThrowsError(try PortalURL.scannedServer(value))
        }
    }
    func testScannedServerRegistrationUsesHostNameAndReusesSavedServer() throws {
        let store = ServerStore(), saved = store.servers
        defer { store.servers = saved }
        store.servers = []
        let base = try PortalURL.scannedServer("https://fixture.example:8443/__t/fixture/").base
        let server = store.server(for: base)
        XCTAssertEqual(server.name, "fixture.example"); XCTAssertEqual(server.addresses, [base])
        store.servers[0].name = "Personal server"
        let reused = store.server(for: base)
        XCTAssertEqual(reused.id, server.id); XCTAssertEqual(reused.name, "Personal server")
        XCTAssertEqual(store.servers.count, 1)
    }
    func testControlAcknowledgementsUseLocalizedNamesWithoutChangingUnknownText() {
        XCTAssertEqual(ChatLabels.notice("preset danger-full-access"), L("Full access", "完全权限"))
        XCTAssertEqual(ChatLabels.notice("permission read-only"), L("Read Only", "只读"))
        XCTAssertEqual(ChatLabels.notice("preset minimal"), L("Minimal", "精简"))
        XCTAssertEqual(ChatLabels.notice(""), "")
        XCTAssertEqual(ChatLabels.notice("Permission denied: 中文"), "Permission denied: 中文")
        XCTAssertEqual(ChatLabels.notice("preset custom-mode"), "preset custom-mode")
    }
    func testTableCellsPreserveWindowsPathsAndLiteralBackslashes() {
        XCTAssertEqual(MarkdownParser.cells(#"| C:\Users\alice | \\server\share | a\|b | `C:\Users\alice\\` |"#), [#"C:\Users\alice"#, #"\\server\share"#, "a|b", #"`C:\Users\alice\\`"#])
        XCTAssertEqual(MarkdownParser.cells(#"| \ | \\ | `a\|b` |"#), [#"\"#, #"\\"#, "`a|b`"])
    }
    func testMarkdownTablesPreserveEscapedAndCodePipes() {
        XCTAssertEqual(MarkdownParser.blocks("| Key | Value |\n| :--- | ---: |\n| a\\|b | `x|y` |"), [.table(["Key", "Value"], [["a|b", "`x|y`"]], [.leading, .trailing])])
        XCTAssertEqual(MarkdownParser.blocks("| One |\n| :---: |"), [.table(["One"], [], [.center])])
        let invalid = "| One |\n| -- |\n| Text |"
        XCTAssertEqual(MarkdownParser.blocks(invalid), [.paragraph(invalid)])
        XCTAssertEqual(MarkdownParser.blocks(""), [])
        XCTAssertEqual(MarkdownParser.blocks("```\n| A |\n| --- |\n```"), [.code("", "| A |\n| --- |")])
    }
    func testTurnSummaryRetainsAllContentAndCountsTools() {
        let items = [TranscriptItem(id: "u", role: "user", blocks: [TranscriptBlock(["type": "text", "text": "Hello"])]), TranscriptItem(id: "a", role: "assistant", blocks: [TranscriptBlock(["type": "tool-call", "id": "c", "name": "read"])], turn: 1), TranscriptItem(id: "notice", role: "notice", blocks: [TranscriptBlock(["type": "future/notice"])]), TranscriptItem(id: "b", role: "assistant", blocks: [TranscriptBlock(["type": "text", "text": "Done"]), TranscriptBlock(["type": "reasoning", "text": "Reason"])], turn: 1)]
        let turns = TranscriptTurn.group(items)
        XCTAssertEqual(turns.flatMap(\.items).map(\.id), items.map(\.id))
        XCTAssertEqual(turns.last?.toolCount, 1)
        XCTAssertEqual(turns.last?.countsLabel, L(" · 1 tool call · 3 messages", " · 1 次工具调用 · 3 条消息"))
        XCTAssertEqual(TranscriptTurn(id: "empty", items: []).countsLabel, L(" · 0 tool calls · 0 messages", " · 0 次工具调用 · 0 条消息"))
        XCTAssertEqual(TranscriptTurn(id: "single", items: [items[0]]).countsLabel, L(" · 0 tool calls · 1 message", " · 0 次工具调用 · 1 条消息"))
        XCTAssertEqual(turns.last?.messageCount, 3)
        XCTAssertEqual(turns.last?.final?.id, "b")
        XCTAssertEqual(turns.last?.detailItems.map(\.id), ["a"])
        XCTAssertTrue(TranscriptTurn.group([]).isEmpty)
        let preface = TranscriptItem(id: "system", role: "notice", blocks: [], turn: 1)
        let observed = TranscriptTurn.group([preface, items[0], items[3]])
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.final?.id, "b")
        let next = TranscriptItem(id: "next", role: "user", blocks: [])
        let later = TranscriptTurn.group([preface, items[0], items[3], next, TranscriptItem(id: "reply", role: "assistant", blocks: [TranscriptBlock(["type": "text", "text": "Next"])], turn: 2)])
        XCTAssertEqual(later.count, 2); XCTAssertEqual(Set(later.map(\.id)).count, 2)
    }
    func testToolPreviewFitsShortArgumentsAndCapsLongOrErrorOutput() {
        XCTAssertEqual(ToolPresentation.previewHeight("", lineHeight: 18, limit: 180), 28)
        XCTAssertEqual(ToolPresentation.previewHeight("{\"command\":\"pwd\"}", lineHeight: 18, limit: 180), 28)
        for newline in ["\n", "\r\n", "\r"] {
            XCTAssertEqual(ToolPresentation.previewHeight(["Path", "----", "/home/test"].joined(separator: newline), lineHeight: 18, limit: 220), 64)
        }
        XCTAssertEqual(ToolPresentation.previewHeight(String(repeating: "line\n", count: 100), lineHeight: 18, limit: 180), 180)
        XCTAssertEqual(ToolPresentation.previewHeight("large type", lineHeight: 36, limit: 180), 46)
        XCTAssertEqual(ToolPresentation.previewHeight(ToolPresentation.result(["error": ["message": "Denied"]]), lineHeight: 18, limit: 220), 28)
    }
    func testNativeSplitNavigationRetainsSidebarState() async throws {
        var lifetimes = Set<UUID>()
        func root(_ column: NavigationSplitViewColumn) -> some View {
            AdaptiveWorkspace(visibility: .constant(.all), column: .constant(column)) {
                SidebarLifetimeView { lifetimes.insert($0) }
            } detail: { Text("Detail") }.environment(\.horizontalSizeClass, .compact)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: root(.sidebar))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lifetimes.count, 1)
        host.rootView = root(.detail)
        try await Task.sleep(nanoseconds: 300_000_000)
        host.rootView = root(.sidebar)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(lifetimes.count, 1)
    }
    func testSidebarDateGroupsAndUnread() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!
        let rows = [("pin", "2026-10-01T10:00:00Z"), ("today", "2026-11-19T10:00:00Z"), ("yesterday", "2026-11-18T10:00:00Z"), ("week", "2026-11-16T10:00:00Z"), ("old", "2026-10-02T10:00:00Z")].map { SessionRow(["sessionId": .string($0.0), "updatedAt": .string($0.1)]) }
        XCTAssertEqual(SessionTimeline.groups(rows, pinned: ["pin"], now: now, calendar: calendar).map(\.id), ["pinned", "today", "yesterday", "week", "older"])
        XCTAssertEqual(SessionTimeline.timestamp(.int(1_000_000_000_000)), 1_000_000_000)
        XCTAssertEqual(SessionTimeline.timestamp(.null), 0)
        let name = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let read = SidebarReadState(defaults: defaults)
        read.baseline(rows, server: "host"); XCTAssertFalse(read.unread(rows[1]))
        var changed = rows[1]; changed.updatedAt = .int(Int(Date().timeIntervalSince1970) + 10)
        XCTAssertTrue(read.unread(changed)); read.mark(changed); XCTAssertFalse(read.unread(changed))
        XCTAssertFalse(SidebarReadState(defaults: defaults).unread(changed))
    }
    func testSanitizedRelayCaptureRetainsNoticesAndTools() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "r4-relay-render", withExtension: "json"))
        var snapshot = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url)); snapshot["type"] = "snapshot"
        let chat = ChatStore(sessionID: "fixture", api: StubAPI()); chat.apply(snapshot)
        XCTAssertTrue(chat.loaded)
        let blocks = chat.transcript.flatMap(\.blocks)
        XCTAssertTrue(blocks.contains { $0.kind == "context" })
        for kind in ["system/message", "developer/message", "compaction/prune"] { XCTAssertFalse(blocks.contains { $0.kind == kind }, kind) }
        XCTAssertTrue(blocks.contains { $0.kind == "reasoning" })
        for name in ["pwsh", "read_image", "ask_user_question", "write", "edit", "read", "working_directory"] {
            XCTAssertTrue(blocks.contains { $0.kind == "tool-call" && $0.name == name }, name)
        }
        XCTAssertTrue(blocks.contains { $0.kind == "tool-call" && $0.result?["message"]["content"].array.contains { $0["type"] == "image" } == true })
        XCTAssertFalse(chat.transcript.contains { $0.optimistic })
    }
    func testScannedPairingUsesPasteParserAndRejectsOtherServers() throws {
        let link = "https://relay.example/__t/test/__portal/pair?t=fixture%2Btoken"
        let paste = try XCTUnwrap(PortalURL.pairing(link))
        let scan = try PortalURL.scannedPairing(link, matching: paste.0)
        XCTAssertEqual(scan.0, paste.0); XCTAssertEqual(scan.1, paste.1)
        for invalid in ["", "hello", "https://relay.example/", "https://relay.example/__portal/pair", "file:///__portal/pair?t=fixture"] {
            XCTAssertThrowsError(try PortalURL.scannedPairing(invalid))
        }
        XCTAssertThrowsError(try PortalURL.scannedPairing(link, matching: URL(string: "https://other.example/")!))
    }
    func testModelSearchAndSubagentFiltering() {
        let group: JSON = ["id": "provider", "name": "Local"]
        let model: JSON = ["id": "vision", "name": "Picture", "description": "Images"]
        for query in ["", "  ", "VISION", "picture", "Images", "local"] { XCTAssertTrue(ChatModelSearch.matches(model, group: group, query: query)) }
        XCTAssertFalse(ChatModelSearch.matches(model, group: group, query: "missing"))
        let store = SidebarStore(api: StubAPI())
        store.applyWorkspace(["type": "baseline", "value": ["items": [["workspaceId": "W", "sessionIds": ["root", "child", "origin"]]], "pinnedSessionIds": ["child"]]])
        store.applySessions(["items": [["sessionId": "root"], ["sessionId": "child", "parentSessionId": "root"], ["sessionId": "origin", "origin": "subagent"]]])
        XCTAssertEqual(store.groups.flatMap(\.sessions).map(\.id), ["root"])
        store.searchText = "child"; XCTAssertTrue(store.groups.flatMap(\.sessions).isEmpty)
    }
    func testOptionsFailureDoesNotCancelHistoryAndEndedFollowReopens() async throws {
        let api = RecoveryAPI(); api.failModels = true
        let chat = ChatStore(sessionID: "S", api: api)
        defer { chat.stop() }
        chat.activate()
        let failed = expectation(description: "Model failure reported")
        let observation = chat.$error.compactMap { $0 }.first().sink { _ in failed.fulfill() }
        await fulfillment(of: [failed], timeout: 3); observation.cancel()
        api.follow?.yield(["type": "snapshot", "records": [["event": ["seq": 1, "type": "user/message", "data": ["content": [["type": "text", "text": "Existing"]]]]]]])
        let loaded = expectation(description: "History survives options failure")
        let history = chat.$loaded.first { $0 }.sink { _ in loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 3); history.cancel()
        XCTAssertEqual(chat.transcript.first?.text, "Existing")
        api.follow?.finish()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(api.openings, 2)
    }
    func testStateReadCannotOverwriteNewerObservation() async throws {
        let api = RecoveryAPI(); api.holdState = true
        let chat = ChatStore(sessionID: "S", api: api)
        chat.applyState(["running": true])
        let requested = expectation(description: "State RPC waiting")
        api.onRead = { requested.fulfill() }
        let read = Task { try await chat.reconcile(loadHistory: false) }
        await fulfillment(of: [requested], timeout: 2)
        chat.applyState(["running": false, "queue": []])
        api.stateGate?.resume(returning: ["running": true]); api.stateGate = nil
        try await read.value
        XCTAssertFalse(chat.running)
        chat.applyState(["unexpected": true]); XCTAssertFalse(chat.running)
    }
    func testStateFailureDoesNotCancelFirstHistoryLoad() async throws {
        let api = RecoveryAPI(); api.failState = true
        let chat = ChatStore(sessionID: "S", api: api)
        defer { chat.stop() }
        try await chat.start()
        XCTAssertNotNil(chat.error)
        api.follow?.yield(["type": "snapshot", "records": [["event": ["seq": 1, "type": "user/message", "data": ["content": [["type": "text", "text": "Existing"]]]]]]])
        let loaded = expectation(description: "History survives initial state failure")
        let history = chat.$loaded.first { $0 }.sink { _ in loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 3); history.cancel()
        XCTAssertEqual(chat.transcript.first?.text, "Existing")
        XCTAssertEqual(api.openings, 1)
    }
    func testToolAndUnknownContentAreRetained() {
        let chat = ChatStore(sessionID: "S", api: StubAPI())
        chat.apply(["type": "snapshot", "records": [
            ["event": ["seq": 1, "type": "system/message", "data": ["message": ["content": [["type": "text", "text": "Notice"]]]]]],
            ["event": ["seq": 2, "type": "tool/call", "data": ["callId": "C", "name": "mcp/example", "arguments": "{}"]]],
            ["event": ["seq": 3, "type": "tool/result", "data": ["message": ["toolCallId": "C", "content": [["type": "structured", "value": 42]]]]]],
            ["event": ["seq": 4, "type": "future/plugin", "data": ["value": "retained"]]]
        ]])
        XCTAssertEqual(chat.transcript.count, 1)
        XCTAssertEqual(chat.transcript.first?.blocks.first?.kind, "tool-call")
        let call = chat.transcript.flatMap(\.blocks).first { $0.kind == "tool-call" }!
        XCTAssertTrue(ToolPresentation.result(call.result!).contains("42"))
        let mixed: JSON = ["message": ["content": [["type": "text", "text": "Readable"], ["type": "future/result", "value": "retained"]]]]
        XCTAssertTrue(ToolPresentation.result(mixed).contains("Readable"))
        XCTAssertTrue(ToolPresentation.result(mixed).contains("retained"))
        XCTAssertTrue(TranscriptBlock(["type": "tool-call", "arguments": ["path": "/workspace"]]).arguments.contains("/workspace"))
    }
}
