import XCTest
@testable import DSHRemote

private final class TestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class TransportTests: XCTestCase {
    func testLoginRPCRefreshCookiesAndExpire() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = CookieVault(root: root)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let client = PortalClient(configuration: config, cookies: vault)
        let base = URL(string: "https://relay.example/__t/id/")!
        let api = PortalAPI(base: base, client: client)
        defer { client.session.invalidateAndCancel(); TestURLProtocol.handler = nil; try? vault.clear(base); try? FileManager.default.removeItem(at: root) }
        TestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://relay.example/__t/id/__portal/login")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://relay.example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), PortalClient.userAgent)
            XCTAssertEqual(request.httpMethod, "POST")
            return (303, ["Set-Cookie": "dsh_portal=portal; Path=/; Max-Age=3600, dsh-auth-demo=upstream; Path=/; Max-Age=3600"], Data())
        }
        try await api.login(secret: "not-a-real-password", pairing: false)
        XCTAssertEqual(Set(vault.cookies(for: base, at: base).map(\.name)), ["dsh_portal", "dsh-auth-demo"])
        TestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://relay.example/__t/id/api/session/list")
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            XCTAssertTrue(cookie.contains("dsh_portal=portal")); XCTAssertTrue(cookie.contains("dsh-auth-demo=upstream"))
            return (200, ["Set-Cookie": "dsh-auth-demo=renewed; Path=/; Max-Age=3600"], Data("{\"type\":\"server-response\",\"result\":{\"ok\":true,\"value\":{\"items\":[]}}}".utf8))
        }
        let value = try await api.rpc("session/list", args: ["_request": [:]])
        XCTAssertEqual(value["items"], [])
        XCTAssertEqual(vault.cookies(for: base, at: base).first { $0.name == "dsh-auth-demo" }?.value, "renewed")
        TestURLProtocol.handler = { _ in (401, ["Set-Cookie": "extra=from-error-response; Path=/; Max-Age=3600"], Data()) }
        do { _ = try await api.rpc("session/list"); XCTFail("Unauthorized request succeeded") }
        catch { XCTAssertEqual(error as? APIError, .sessionExpired) }
        XCTAssertTrue(api.sessionExpired)
        XCTAssertTrue(vault.cookies(for: base, at: base).contains { $0.name == "extra" })
    }
    func testModelsAndSidebarActions() async throws {
        let api = StubAPI()
        let chat = ChatStore(sessionID: "S", api: api)
        api.response = ["groups": []]
        try await chat.loadModels()
        XCTAssertEqual(api.calls.last?.0, "session/modelCatalog")
        XCTAssertEqual(chat.catalog["groups"], [])
        api.response = ["selected": ["provider": "local-fake", "model": "native-demo"]]
        try await chat.selectModel(provider: "local-fake", model: "native-demo", reasoningEffort: "high")
        XCTAssertEqual(api.calls.last?.1["request"]["reasoningEffort"], "high")
        XCTAssertEqual(chat.selectedModel, api.response)
        let sidebar = SidebarStore(api: api)
        sidebar.applySessions(["items": [["sessionId": "S"]]])
        api.response = ["title": "Renamed"]
        try await sidebar.rename("S", title: "Renamed")
        XCTAssertEqual(sidebar.sessions["S"]?.title, "Renamed")
        api.response = ["pinnedSessionIds": ["S"]]
        try await sidebar.pin("S", pinned: true)
        XCTAssertEqual(sidebar.pinnedIDs, ["S"])
        api.response = ["pinnedSessionIds": []]
        try await sidebar.pin("S", pinned: false)
        XCTAssertEqual(api.calls.last?.0, "workspace/unpinSession")
        XCTAssertTrue(sidebar.pinnedIDs.isEmpty)
        api.response = ["archivedSessionIds": ["S"]]
        try await sidebar.archive("S")
        XCTAssertEqual(sidebar.archivedIDs, ["S"])
        api.failure = APIError.remote("workspace/session-active", "Still running")
        do { try await sidebar.archive("S"); XCTFail("Failure swallowed") } catch { XCTAssertEqual(error.localizedDescription, "Still running") }
        XCTAssertEqual(sidebar.archivedIDs, ["S"])
    }
}
