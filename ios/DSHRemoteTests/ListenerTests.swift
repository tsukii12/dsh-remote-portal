import XCTest
import Network
import SwiftUI
import Combine
import UIKit
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
    func testOptionsPresentationLoadsMetadataOverRealHTTP() async throws {
        for empty in [false, true] {
            let server = try HTTPListener { request in
                let body = try! JSONDecoder().decode(JSON.self, from: request.body)
                let method = body["method"].text
                XCTAssertEqual(request.path, "/api/" + method)
                let value: JSON
                switch method {
                case "session/modelCatalog": value = ["groups": empty ? [] : [["id": "fake", "name": "Fake", "models": [["id": "one", "name": "One"]]]]]
                case "permissionPresets/catalog": value = ["options": []]
                case "agentPresets/list": value = ["presets": empty ? [] : [["id": "minimal"]]]
                case "commands/list": value = []
                case "session/projections": value = ["asOfSeq": 0, "values": ["agentPreset": "standard"]]
                default: XCTFail("Unexpected method: \(method)"); value = [:]
                }
                return .init(body: String(decoding: try! JSONEncoder().encode(["type": "server-response", "result": ["ok": true, "value": value]] as JSON), as: UTF8.self))
            }
            let base = try await server.start(); let directory = root(); let client = client(directory)
            let chat = ChatStore(sessionID: "S", api: PortalAPI(base: base, client: client))
            let loaded = expectation(description: "Options loaded on presentation")
            let observation = chat.$projections.dropFirst().sink { _ in loaded.fulfill() }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: ChatOptionsView(chat: chat))
            window.makeKeyAndVisible()
            defer {
                observation.cancel(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory)
            }
            await fulfillment(of: [loaded], timeout: 5)
            XCTAssertEqual(chat.catalog["groups"].array.count, empty ? 0 : 1)
            XCTAssertEqual(chat.presetCatalog["presets"].array.count, empty ? 0 : 1)
        }
    }
    func testChatOptionsCommandsAndQueueOverRealHTTP() async throws {
        var calls: [JSON] = []
        let catalog: JSON = ["default": ["provider": "fake", "model": "one", "reasoningEffort": "high"], "groups": [["id": "fake", "name": "Fake", "models": [["id": "one", "name": "One", "reasoning": ["efforts": [["id": "off", "name": "Off"], ["id": "high", "name": "High"]]]], ["id": "two", "name": "Two"]]]]]
        let server = try HTTPListener { request in
            let body = try! JSONDecoder().decode(JSON.self, from: request.body)
            let method = body["method"].text; let args = body["payload"]["args"]
            XCTAssertEqual(request.path, "/relay/api/" + method)
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.headers["user-agent"], PortalClient.userAgent)
            XCTAssertEqual(request.headers["origin"], "http://" + request.headers["host", default: ""])
            calls.append(body)
            var value: JSON = [:]
            switch method {
            case "session/modelCatalog": value = catalog
            case "session/selectModel": value = ["selected": args["request"]]
            case "permissionPresets/catalog": value = ["options": [["value": "read-only"]]]
            case "agentPresets/list": value = ["presets": [["id": "standard"], ["id": "minimal"]]]
            case "commands/list": value = [["name": "plan", "description": "Plan"]]
            case "session/projections": value = ["asOfSeq": 1, "values": ["agentPreset": "standard", "permissions": ["currentValue": "read-only"], "sessionListMetadata": ["blank": true]]]
            case "commands/execute":
                XCTAssertEqual(args["agentId"], "S"); XCTAssertEqual(args["submittedAttachments"], [])
                value = args["line"] == "/bad" ? ["commandId": "C", "result": ["kind": "error", "text": "Refused"]] : args["line"] == "/unknown" ? .null : ["commandId": "C", "result": ["kind": "success", "text": "Changed"]]
            case "session/state": value = ["running": true, "queue": []]
            default: break
            }
            let response: JSON = ["type": "server-response", "result": ["ok": true, "value": value]]
            return .init(body: String(decoding: try! JSONEncoder().encode(response), as: UTF8.self))
        }
        let base = try await server.start().appendingPathComponent("relay/")
        let directory = root(); let client = client(directory); let api = PortalAPI(base: base, client: client)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let chat = ChatStore(sessionID: "S", api: api)
        try await chat.loadModels(); try await chat.loadControls()
        try await chat.selectModel(provider: "fake", model: "one")
        XCTAssertEqual(calls.last?["payload"]["args"]["request"]["reasoningEffort"], "high")
        try await chat.selectModel(provider: "fake", model: "one", reasoningEffort: "off")
        try await chat.selectModel(provider: "fake", model: "one")
        XCTAssertEqual(calls.last?["payload"]["args"]["request"]["reasoningEffort"], "off")
        try await chat.selectModel(provider: "fake", model: "two")
        XCTAssertEqual(chat.currentModel["model"], "two")
        try await chat.selectModel(provider: "fake", model: "one", useDefaultEffort: true)
        XCTAssertEqual(chat.currentModel["reasoningEffort"], .null)
        try await chat.selectPermission("read-only")
        XCTAssertEqual(chat.projections["permissions"]["currentValue"], "read-only")
        try await chat.selectPreset("minimal")
        XCTAssertTrue(calls.contains { $0["method"] == "agentPresets/select" && $0["payload"]["args"] == ["agentId": "S", "agentPreset": "minimal"] })
        try await chat.executeCommand("/plan")
        XCTAssertEqual(chat.commandNotice, "Changed")
        for line in ["/bad", "/unknown"] {
            do { try await chat.executeCommand(line); XCTFail("Command failure accepted") } catch {}
        }
        chat.applyState(["running": true, "queue": [["id": "Q", "placement": "queued", "rpcId": "R", "content": [["type": "text", "text": "queued"]]]]])
        chat.addOptimistic(text: "queued", requestID: "R")
        XCTAssertFalse(chat.transcript.contains { $0.requestID == "R" })
        for kind in ["edit", "steer", "remove"] {
            try await chat.updateQueue("Q", kind: kind, text: kind == "edit" ? "updated" : nil)
            let request = calls.last { $0["method"] == "session/updateQueue" }!["payload"]["args"]["request"]
            XCTAssertEqual(request["sessionId"], "S"); XCTAssertEqual(request["itemId"], "Q"); XCTAssertEqual(request["action"]["kind"].text, kind)
            if kind == "edit" { XCTAssertEqual(request["action"]["content"], [["type": "text", "text": "updated"]]) }
        }
        do { try await chat.updateQueue("Q", kind: "edit", text: " "); XCTFail("Empty edit accepted") } catch {}
        do { try await chat.selectPreset("ptc"); XCTFail("Started preset accepted") } catch {}
    }
    func testSidebarSearchArchiveAndWorkspaceRoutesOverRealHTTP() async throws {
        var calls: [JSON] = []
        let workspace: JSON = ["workspaceId": "W", "title": "Project", "path": "/host/a b", "sessionIds": ["S"]]
        let server = try HTTPListener { request in
            if request.path.hasSuffix("/__portal/login") { return .init(status: 303, headers: ["Set-Cookie": "dsh_portal=fixture; Path=/; Max-Age=3600"]) }
            if request.path.hasPrefix("/relay/dsh-remote-portal/") {
                XCTAssertTrue(request.headers["cookie", default: ""].contains("dsh_portal=fixture"))
                XCTAssertEqual(request.headers["user-agent"], PortalClient.userAgent)
                XCTAssertEqual(request.headers["origin"], "http://" + request.headers["host", default: ""])
                if request.method == "GET" {
                    XCTAssertEqual(request.path, "/relay/dsh-remote-portal/fs?path=/host/a%20b")
                    return .init(body: "{\"ok\":true,\"listing\":{\"path\":\"/host/a b\",\"entries\":[],\"roots\":[]}}")
                }
                XCTAssertEqual(request.path, "/relay/dsh-remote-portal/fs/mkdir")
                let body = try! JSONDecoder().decode(JSON.self, from: request.body)
                XCTAssertEqual(body, ["parent": "/host/a b", "name": "new"])
                return .init(body: "{\"ok\":true,\"created\":{\"path\":\"/host/a b/new\"}}")
            }
            let body = try! JSONDecoder().decode(JSON.self, from: request.body); calls.append(body)
            let method = body["method"].text
            XCTAssertEqual(request.path, "/relay/api/" + method)
            let value: JSON
            switch method {
            case "session/search": value = ["items": [["sessionId": "S", "snippet": "match"]]]
            case "workspace/create", "workspace/rename": value = ["workspace": workspace]
            case "workspace/unarchiveSession": value = ["archivedSessionIds": []]
            default: value = [:]
            }
            return .init(body: String(decoding: try! JSONEncoder().encode(JSON.object(["type": "server-response", "result": ["ok": true, "value": value]])), as: UTF8.self))
        }
        let base = try await server.start().appendingPathComponent("relay/")
        let directory = root(); let client = client(directory); let api = PortalAPI(base: base, client: client)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let store = SidebarStore(api: api)
        try await api.login(secret: "secret", pairing: false)
        let folders = try await store.folders(path: "/host/a b")
        let created = try await store.makeFolder(parent: "/host/a b", name: "new")
        XCTAssertEqual(folders["entries"], [])
        XCTAssertEqual(created["path"], "/host/a b/new")
        try await store.createWorkspace(path: "/host/a b")
        XCTAssertEqual(store.workspaces.map(\.id), ["W"])
        try await store.renameWorkspace("W", title: "Renamed")
        store.applySessions(["items": [["sessionId": "S", "projections": ["values": ["title": "Other"]]]]])
        store.searchText = "match"; try await store.search("match")
        XCTAssertEqual(store.groups.flatMap(\.sessions).map(\.id), ["S"])
        store.applyWorkspace(["type": "archived", "archivedSessionIds": ["S"]])
        XCTAssertTrue(store.groups.flatMap(\.sessions).isEmpty)
        store.archivedOnly = true; XCTAssertEqual(store.groups.flatMap(\.sessions).map(\.id), ["S"])
        try await store.unarchive("S"); XCTAssertTrue(store.groups.flatMap(\.sessions).isEmpty)
        try await store.deleteWorkspace("W"); XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertEqual(calls.first { $0["method"] == "workspace/create" }?["payload"]["args"], ["request": ["path": "/host/a b"]])
        XCTAssertEqual(calls.first { $0["method"] == "workspace/rename" }?["payload"]["args"], ["request": ["workspaceId": "W", "title": "Renamed"]])
        XCTAssertEqual(calls.first { $0["method"] == "workspace/delete" }?["payload"]["args"], ["request": ["workspaceId": "W"]])
    }
    func testSessionExportAndDownloadFailuresOverRealHTTP() async throws {
        for (status, body, success) in [(200, "PKfixture", true), (200, "", false), (200, "{}", false), (401, "", false), (500, "Failed", false)] {
            let server = try HTTPListener { request in
                if request.path == "/relay/api/commands/execute" {
                    return .init(body: "{\"type\":\"server-response\",\"result\":{\"ok\":true,\"value\":{\"commandId\":\"C\",\"result\":{\"kind\":\"success\"}}}}")
                }
                if request.path == "/relay/api/session/projections" {
                    return .init(body: "{\"type\":\"server-response\",\"result\":{\"ok\":true,\"value\":{\"asOfSeq\":0,\"values\":{}}}}")
                }
                XCTAssertEqual(request.path, "/relay/api/session.export?sessionId=S")
                XCTAssertEqual(request.method, "GET")
                XCTAssertEqual(request.headers["user-agent"], PortalClient.userAgent)
                XCTAssertEqual(request.headers["origin"], "http://" + request.headers["host", default: ""])
                return .init(status: status, headers: ["Content-Type": "application/zip"], body: body)
            }
            let base = try await server.start().appendingPathComponent("relay/")
            let directory = root(); let client = client(directory); let api = PortalAPI(base: base, client: client)
            defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
            let chat = ChatStore(sessionID: "S", api: api)
            do {
                try await chat.executeCommand("/export")
                XCTAssertTrue(success)
                let url = try XCTUnwrap(chat.exportedFile)
                XCTAssertEqual(try Data(contentsOf: url), Data(body.utf8))
                try FileManager.default.removeItem(at: url)
            } catch { XCTAssertFalse(success); XCTAssertNil(chat.exportedFile) }
            XCTAssertEqual(api.sessionExpired, status == 401)
        }
    }
    func testRoundOneHTTPFailuresDoNotMutateState() async throws {
        for status in [200, 401, 404, 500] {
            let server = try HTTPListener { request in
                .init(status: status, body: request.path.contains("/api/") ? "{\"type\":\"server-response\",\"result\":{\"ok\":false,\"error\":{\"code\":\"refused\",\"message\":\"Refused\"}}}" : "{\"ok\":false,\"error\":\"Refused\"}")
            }
            let base = try await server.start(); let directory = root(); let client = client(directory); let api = PortalAPI(base: base, client: client)
            defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
            let store = SidebarStore(api: api); let chat = ChatStore(sessionID: "S", api: api)
            do { _ = try await store.folders(); XCTFail("Failed browse accepted") } catch {}
            do { _ = try await store.makeFolder(parent: "/host", name: "new"); XCTFail("Failed mkdir accepted") } catch {}
            do { try await store.createWorkspace(path: "/host"); XCTFail("Failed workspace accepted") } catch {}
            do { try await chat.selectModel(provider: "p", model: "m"); XCTFail("Failed selection accepted") } catch {}
            do { try await chat.loadModels(); XCTFail("Failed catalog accepted") } catch {}
            do { try await chat.loadControls(); XCTFail("Failed options accepted") } catch {}
            do { try await chat.executeCommand("/plan"); XCTFail("Failed command accepted") } catch {}
            XCTAssertTrue(store.workspaces.isEmpty); XCTAssertEqual(chat.selectedModel, [:])
            XCTAssertEqual(api.sessionExpired, status == 401)
        }
    }
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
