import XCTest
@testable import DSHRemote

@MainActor
final class LiveSmokeTests: XCTestCase {
    private func eventually(_ description: String, timeout: TimeInterval = 20, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { throw PortalError.message("Timed out: " + description) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testGatewayNativeFlow() async throws {
        guard ProcessInfo.processInfo.environment["DSH_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt in with test runner DSH_LIVE_SMOKE=1") }
        weak var releasedAPI: PortalAPI?
        try await exerciseGateway { releasedAPI = $0 }
        try await eventually("transport released") { releasedAPI == nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        print("LIVE PASS teardown: transport released and socket shutdown drained")
    }
    private func exerciseGateway(_ created: (PortalAPI) -> Void) async throws {
        let api = PortalAPI(base: URL(string: "http://127.0.0.1:3081/")!)
        created(api)
        let connection = NativeConnection(api: api)
        defer { connection.stop() }
        try await api.login(secret: "demo-pass-123", pairing: false)
        let cookies = api.client.cookies.cookies(for: api.base, at: api.base)
        XCTAssertTrue(cookies.contains { $0.name == "dsh_portal" })
        XCTAssertTrue(cookies.contains { $0.name.hasPrefix("dsh-auth-") })
        print("LIVE PASS login: portal + upstream cookies stored")
        try await connection.start()
        try await eventually("sidebar baseline and events ready") { connection.sidebar.loaded && connection.events.clientID != nil }
        print("LIVE PASS sidebar: workspace baseline, session list, event client ready")
        let workspace = connection.sidebar.workspaces.first
        let id = try await connection.sidebar.createSession(workspaceID: workspace?.id, cwd: workspace == nil ? "/Users/devin/fake-llm" : nil)
        print("LIVE PASS create session: \(id)")
        let chat = connection.chat(id)
        defer { chat.stop() }
        try await chat.start()
        try await eventually("history snapshot") { chat.loaded }
        try await chat.loadModels(); try await chat.loadControls()
        XCTAssertTrue(chat.catalog["groups"].array.flatMap { $0["models"].array }.contains { $0["id"] == "native-demo-fast" })
        try await chat.selectModel(provider: "local-fake", model: "native-demo", reasoningEffort: "off")
        try await chat.selectModel(provider: "local-fake", model: "native-demo")
        XCTAssertEqual(chat.currentModel["reasoningEffort"], "off")
        try await chat.selectModel(provider: "local-fake", model: "native-demo-fast", reasoningEffort: "high")
        XCTAssertEqual(chat.currentModel["model"], "native-demo-fast")
        XCTAssertEqual(chat.currentModel["reasoningEffort"], "high")
        print("LIVE PASS model: Off preserved on reselection; switched to second route with High")
        try await chat.selectPermission("read-only")
        XCTAssertEqual(chat.projections["permissions"]["currentValue"], "read-only")
        try await chat.executeCommand("/permission workspace-write")
        XCTAssertEqual(chat.projections["permissions"]["currentValue"], "workspace-write")
        print("LIVE PASS access/slash: read-only then workspace-write through commands/execute and projections")
        let folders = try await connection.sidebar.folders(path: "/Users/devin/fake-llm")
        XCTAssertEqual(folders["path"], "/Users/devin/fake-llm")
        print("LIVE PASS host folders: Portal fs listing with authenticated native transport")
        try await chat.send("hello")
        try await eventually("incremental text") { !(chat.inProgress?.text.isEmpty ?? true) }
        print("LIVE PASS hello: incremental assistant text received")
        try await eventually("hello committed") { chat.transcript.contains { $0.role == "assistant" && $0.text.contains("# Local native chat demo") } && chat.inProgress == nil && !chat.running }
        XCTAssertEqual(chat.transcript.filter { $0.role == "user" }.count, 1)
        XCTAssertTrue(chat.transcript.contains { $0.role == "assistant" && $0.text.contains("Model: native-demo-fast") })
        try await chat.selectModel(provider: "local-fake", model: "native-demo", reasoningEffort: "high")
        try await chat.selectModel(provider: "local-fake", model: "native-demo")
        XCTAssertEqual(chat.currentModel["model"], "native-demo")
        XCTAssertEqual(chat.currentModel["reasoningEffort"], "high")
        print("LIVE PASS model generation: second route streamed its identity; switched back preserving High")
        let previousClient = connection.events.clientID
        api.mux.reconnect()
        try await eventually("mux reconnect and fresh baselines") { connection.events.clientID != nil && connection.events.clientID != previousClient && chat.loaded }
        XCTAssertEqual(chat.transcript.filter { $0.role == "user" }.count, 1)
        print("LIVE PASS mux: reconnected, streams reopened without duplicate history")
        try await chat.send("run pwd approval")
        try await eventually("approval request") { connection.events.pending.contains { $0.agentID == id && $0.kind == "approval/request" } }
        let approval = try XCTUnwrap(connection.events.pending.first { $0.agentID == id })
        XCTAssertEqual(approval.request["toolName"], "bash")
        print("LIVE PASS approval: approval/request received")
        let input = ApprovalInputLoader(api: api, item: approval)
        await input.load()
        XCTAssertEqual(input.input, "pwd")
        XCTAssertTrue(input.canAllow)
        print("LIVE PASS approval input: fetched matching pwd command through session/events")
        try await connection.events.answerApproval(approval.id, allow: true)
        print("LIVE PASS approval: allowed-once sent with current clientId")
        try await eventually("tool result and final answer") { chat.transcript.contains { $0.role == "assistant" && $0.turn == 2 && $0.step == 2 && $0.text.contains("Tool result:") } && chat.inProgress == nil && !chat.running }
        let tool = try XCTUnwrap(chat.transcript.flatMap(\.blocks).first { $0.kind == "tool-call" })
        XCTAssertEqual(tool.result?["message"]["isError"], false)
        XCTAssertFalse(connection.events.pending.contains { $0.id == approval.id })
        XCTAssertEqual(chat.transcript.filter { $0.role == "user" }.count, 2)
        print("LIVE PASS final: successful tool result paired, final answer committed, no duplicate users")
        try await connection.sidebar.archive(id)
    }
}
