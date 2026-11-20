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
    func rpc(_ method: String, args: JSON) async throws -> JSON {
        if method == "session/state" {
            if failState { throw APIError.http(503) }
            if holdState { return try await withCheckedThrowingContinuation { stateGate = $0; onRead?() } }
            return state
        }
        if method == "session/modelCatalog", failModels { throw APIError.http(503) }
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
        XCTAssertEqual(turns.last?.detailItems.map(\.id), ["a", "notice"])
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
        for kind in ["system/message", "developer/message", "compaction/prune"] { XCTAssertTrue(blocks.contains { $0.kind == kind }, kind) }
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
        XCTAssertEqual(chat.transcript.count, 3)
        XCTAssertEqual(chat.transcript.first?.text, "Notice")
        XCTAssertEqual(chat.transcript.last?.blocks.first?.kind, "future/plugin")
        XCTAssertTrue(chat.transcript.last!.blocks[0].raw.formatted.contains("retained"))
        let call = chat.transcript.flatMap(\.blocks).first { $0.kind == "tool-call" }!
        XCTAssertTrue(ToolPresentation.result(call.result!).contains("42"))
        let mixed: JSON = ["message": ["content": [["type": "text", "text": "Readable"], ["type": "future/result", "value": "retained"]]]]
        XCTAssertTrue(ToolPresentation.result(mixed).contains("Readable"))
        XCTAssertTrue(ToolPresentation.result(mixed).contains("retained"))
        XCTAssertTrue(TranscriptBlock(["type": "tool-call", "arguments": ["path": "/workspace"]]).arguments.contains("/workspace"))
    }
}
