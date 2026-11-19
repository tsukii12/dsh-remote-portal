import XCTest
import Network
@testable import DSHRemote

private final class HTTPListener {
    struct Request {
        let path: String
        let method: String
        let headers: [String: String]
        let body: Data
    }
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DRP.HTTPListener")
    private let handler: (Request) -> Reply
    init(_ handler: @escaping (Request) -> Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] bytes, _, complete, error in
            var data = buffer; data.append(bytes ?? Data())
            guard data.count <= 1_048_576, error == nil else { connection.cancel(); return }
            if let split = data.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if first.count >= 2 && data.count - split.upperBound >= length {
                    let request = Request(path: String(first[1]), method: String(first[0]), headers: headers, body: Data(data[split.upperBound..<(split.upperBound + length)]))
                    let reply = handler(request)
                    let body = Data(reply.body.utf8)
                    var text = "HTTP/1.1 \(reply.status) Response\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                    for (key, value) in reply.headers { text += "\(key): \(value)\r\n" }
                    var output = Data((text + "\r\n").utf8); output.append(body)
                    connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if complete { connection.cancel() } else { receive(connection, buffer: data) }
        }
    }
}

@MainActor
final class ListenerTests: XCTestCase {
    private func client(_ root: URL) -> PortalClient { PortalClient(configuration: .ephemeral, cookies: CookieVault(root: root)) }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testGatewayLoginAndPairFailureReasonsOverHTTP() async throws {
        let generic = L("Sign-in failed. Check your password or pairing code.", "登录失败，请检查密码或配对码。")
        let cases: [(Int, String, Bool, String)] = [
            (401, "{\"error\":\"This pairing code has expired. Generate a new one.\",\"message\":\"wrong field\"}", true, "This pairing code has expired. Generate a new one."),
            (403, "{\"error\":\"Password login is disabled.\"}", false, "Password login is disabled."),
            (401, "{\"error\":\"配对码无效或已被使用。\"}", true, "配对码无效或已被使用。"),
            (401, "{\"message\":\"Legacy reason\"}", false, "Legacy reason"),
            (401, "{\"error\":\"  \"}", true, generic),
            (500, "not JSON", false, generic),
            (401, "{\"error\":123}", false, generic),
            (429, "{}", false, L("Too many attempts. Try again after 3 seconds.", "尝试次数过多，请稍后重试（3秒）。"))
        ]
        for (status, body, pairing, expected) in cases {
            let server = try HTTPListener { request in
                XCTAssertEqual(request.path, "/__t/test/__portal/login")
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(request.headers["user-agent"], PortalClient.userAgent)
                XCTAssertEqual(request.headers["accept-language"], L("en", "zh"))
                XCTAssertEqual(request.headers["origin"], "http://" + request.headers["host", default: ""])
                XCTAssertEqual(String(decoding: request.body, as: UTF8.self), pairing ? "token=secret" : "password=secret")
                return .init(status: status, headers: ["Content-Type": "application/json", "Retry-After": "3"], body: body)
            }
            let base = try await server.start().appendingPathComponent("__t/test/")
            let directory = root(); let client = client(directory)
            defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
            do { try await PortalAPI(base: base, client: client).login(secret: "secret", pairing: pairing); XCTFail("Failure accepted") }
            catch { XCTAssertEqual(error.localizedDescription, expected) }
        }
    }
    func testLogoutClearsOnlySelectedPersistedJarAndExpiresStreams() async throws {
        for status in [303, 204] {
            let server = try HTTPListener { request in
                if request.path.hasSuffix("/__portal/login") {
                    XCTAssertEqual(request.method, "POST")
                    return .init(status: 303, headers: ["Set-Cookie": "dsh_portal=test; Path=/; Max-Age=3600, dsh-auth-demo=upstream; Path=/; Max-Age=3600", "Location": "/should-not-follow"])
                }
                if request.path == "/selected/__portal/logout" {
                    XCTAssertEqual(request.method, "POST")
                    XCTAssertTrue(request.headers["cookie", default: ""].contains("dsh_portal=test"))
                    return .init(status: status, headers: ["Location": "/should-not-follow"])
                }
                return .init(status: 404)
            }
            let origin = try await server.start()
            let base = origin.appendingPathComponent("selected/"); let other = origin.appendingPathComponent("other/")
            let directory = root(); let client = client(directory)
            let api = PortalAPI(base: base, client: client)
            defer { api.mux.close(); server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
            try await api.login(secret: "secret", pairing: false)
            try await PortalAPI(base: other, client: client).login(secret: "secret", pairing: true)
            XCTAssertEqual(CookieVault(root: directory).cookies(for: base, at: base).count, 2)
            let stream = api.stream("$events")
            try await api.logout()
            let expired = expectation(description: "Logout expires stream")
            let reader = Task {
                do { for try await _ in stream {}; XCTFail("Stream closed without expiry") }
                catch { XCTAssertEqual(error as? APIError, .sessionExpired) }
                expired.fulfill()
            }
            await fulfillment(of: [expired], timeout: 3)
            reader.cancel()
            XCTAssertTrue(api.sessionExpired)
            XCTAssertTrue(client.cookies.cookies(for: base, at: base).isEmpty)
            let restored = CookieVault(root: directory)
            XCTAssertTrue(restored.cookies(for: base, at: base).isEmpty)
            XCTAssertEqual(Set(restored.cookies(for: other, at: other).map(\.name)), ["dsh_portal", "dsh-auth-demo"])
        }
    }
    func testFailedLogoutPreservesSessionAndCookies() async throws {
        let server = try HTTPListener { request in
            if request.path.hasSuffix("/login") { return .init(status: 303, headers: ["Set-Cookie": "dsh_portal=test; Path=/; Max-Age=3600"]) }
            return .init(status: 500, body: "{}")
        }
        let base = try await server.start(); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let api = PortalAPI(base: base, client: client)
        try await api.login(secret: "secret", pairing: false)
        do { try await api.logout(); XCTFail("Failure accepted") }
        catch { XCTAssertEqual(error.localizedDescription, L("Sign-out failed. Please try again.", "退出登录失败，请重试。")) }
        XCTAssertFalse(api.sessionExpired)
        XCTAssertEqual(CookieVault(root: directory).cookies(for: base, at: base).count, 1)
    }
    func testApprovalLoaderFailureEmptyRetryAndRejectOverHTTP() async throws {
        var calls = 0
        let server = try HTTPListener { request in
            let body = try! JSONDecoder().decode(JSON.self, from: request.body)
            if request.path == "/relay/api/$events/result" {
                XCTAssertEqual(body["payload"]["args"]["outcome"]["value"], "rejected")
                return .init(body: "{\"type\":\"server-response\",\"result\":{\"ok\":true}}")
            }
            XCTAssertEqual(request.path, "/relay/api/session/events")
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(body["type"], "client-request")
            XCTAssertEqual(body["method"], "session/events")
            XCTAssertNotNil(body["rpcId"].string)
            XCTAssertEqual(body["payload"]["args"], ["request": ["address": ["kind": "session", "sessionId": "S"], "maxMessages": 50]])
            calls += 1
            if calls == 1 || calls == 4 { return .init(status: 503) }
            let records: JSON = calls == 2 ? [] : [["event": ["type": "tool/call", "data": ["callId": "wrong", "arguments": "{\"command\":\"wrong\"}"]]], ["event": ["type": "tool/call", "data": ["callId": "C", "arguments": "{\"command\":\"pwd\"}"]]]]
            let value: JSON = ["type": "server-response", "result": ["ok": true, "value": ["records": records]]]
            return .init(body: String(decoding: try! JSONEncoder().encode(value), as: UTF8.self))
        }
        let base = try await server.start().appendingPathComponent("relay/"); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let api = PortalAPI(base: base, client: client)
        let item = PendingInteraction(id: "E", clientID: "client", agentID: "S", kind: "approval/request", request: ["toolName": "bash", "callId": "C"])
        let loader = ApprovalInputLoader(api: api, item: item)
        for _ in 0..<2 {
            await loader.load()
            XCTAssertFalse(loader.isLoading); XCTAssertFalse(loader.canAllow); XCTAssertNil(loader.input); XCTAssertNotNil(loader.error)
        }
        await loader.load()
        XCTAssertEqual(loader.input, "pwd"); XCTAssertTrue(loader.canAllow); XCTAssertNil(loader.error)
        await loader.load()
        XCTAssertNil(loader.input); XCTAssertFalse(loader.canAllow); XCTAssertFalse(loader.isLoading)
        let events = RemoteEvents(api: api)
        events.apply(["type": "ready", "clientId": "client"])
        events.apply(["type": "waterfall", "event": "approval/request", "eventId": "E", "agentId": "S", "request": item.request])
        try await events.answerApproval("E", allow: false)
        XCTAssertTrue(events.pending.isEmpty)
        await loader.load()
        XCTAssertTrue(loader.canAllow); XCTAssertEqual(loader.input, "pwd"); XCTAssertNil(loader.error)
    }
    func testBilingualErrorsAndPermissionResources() async throws {
        XCTAssertEqual(L("English", "中文", languages: ["zh-Hans"]), "中文")
        XCTAssertEqual(L("English", "中文", languages: ["en"]), "English")
        XCTAssertEqual(APIError.invalidResponse.localizedDescription, L("Invalid server response.", "服务器响应无效。"))
        XCTAssertEqual(APIError.disconnected.localizedDescription, L("Connection closed.", "连接已关闭。"))
        XCTAssertEqual(APIError.http(503).localizedDescription, L("Server request failed (HTTP 503).", "服务器请求失败（HTTP 503）。"))
        do { _ = try PortalAPI.decode(Data("{\"type\":\"server-response\",\"result\":{\"ok\":false,\"error\":{}}}".utf8), status: 200); XCTFail("Failure accepted") }
        catch { XCTAssertEqual(error.localizedDescription, L("Request failed.", "请求失败。")) }
        let api = StubAPI()
        do { _ = try await ChatStore(sessionID: "S", api: api).send(" \n"); XCTFail("Empty message accepted") }
        catch { XCTAssertEqual(error.localizedDescription, L("Enter a message.", "请输入消息。")) }
        XCTAssertTrue(api.calls.isEmpty)
        for (locale, expected) in [("en", "Connect to your DeepSeek Harness on the local network."), ("zh-Hans", "连接到本地网络中的 DeepSeek Harness。") ] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "NSLocalNetworkUsageDescription", value: nil, table: "InfoPlist"), expected)
        }
    }
}
