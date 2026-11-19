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
        var data: Data?
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
                    let body = reply.data ?? Data(reply.body.utf8)
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
    func testChatSelectionBootstrapOutlivesCancelledSearchOverRealHTTP() async throws {
        var calls: [String] = []
        let server = try HTTPListener { request in
            if request.method == "GET" { return .init(status: 404) }
            let body = try! JSONDecoder().decode(JSON.self, from: request.body)
            let method = body["method"].text, args = body["payload"]["args"]
            calls.append(method)
            XCTAssertEqual(request.path, "/relay/api/" + method)
            switch method {
            case "session/state":
                XCTAssertEqual(args, ["request": ["sessionId": "search-result"]])
                return self.reply(["isRunning": false])
            case "session/modelCatalog":
                XCTAssertEqual(args, [:])
                return self.reply(["default": ["provider": "fake", "model": "one"], "groups": [["id": "fake", "models": [["id": "one", "name": "One"]]]]])
            case "permissionPresets/catalog", "agentPresets/list":
                XCTAssertEqual(args, [:]); return self.reply([:])
            case "commands/list":
                XCTAssertEqual(args, ["agentId": "search-result"]); return self.reply([["name": "plan"]])
            case "session/projections":
                XCTAssertEqual(args, ["request": ["sessionId": "search-result"]])
                return self.reply(["asOfSeq": 1, "values": ["modelSelection": ["selected": ["provider": "fake", "model": "one", "reasoningEffort": "high"]]]])
            default: XCTFail("Unexpected startup RPC: " + method); return .init(status: 404)
            }
        }
        let base = try await server.start().appendingPathComponent("relay/"); let directory = root(); let client = client(directory)
        let api = PortalAPI(base: base, client: client)
        let selection = ChatSelection { ChatStore(sessionID: $0, api: api) }
        defer { selection.stop(); api.mux.close(); server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            selection.select("search-result")
        }
        await search.value
        let chat = try XCTUnwrap(selection.chat)
        let ready = expectation(description: "Selected search result loads its controls despite navigation cancellation")
        let subscription = chat.$projections.first { $0["modelSelection"]["selected"]["model"] == "one" }.sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(chat.modelName, "One"); XCTAssertEqual(chat.effortName, "high"); XCTAssertTrue(chat.supportsPlan)
        XCTAssertEqual(calls, ["session/state", "session/modelCatalog", "permissionPresets/catalog", "agentPresets/list", "commands/list", "session/projections"])
    }
    private func client(_ root: URL) -> PortalClient { PortalClient(configuration: .ephemeral, cookies: CookieVault(root: root)) }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func reply(_ value: JSON) -> HTTPListener.Reply {
        .init(body: String(decoding: try! JSONEncoder().encode(["type": "server-response", "result": ["ok": true, "value": value]] as JSON), as: UTF8.self))
    }
    private func png() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).pngData { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
    }
    private func multipart(_ metadata: JSON, bytes: Data, extra: Bool = false) -> Data {
        var data = Data("--drp-boundary\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
        data.append(try! JSONEncoder().encode(metadata))
        data.append(Data("\r\n--drp-boundary\r\nContent-Disposition: form-data; name=\"binary\"; filename=\"image.png\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)); data.append(bytes)
        if extra { data.append(Data("\r\n--drp-boundary\r\nContent-Disposition: form-data; name=\"extra\"\r\n\r\nunexpected".utf8)) }
        data.append(Data("\r\n--drp-boundary--\r\n".utf8)); return data
    }
    func testPlanAvailabilityRefreshesAfterPresetChangesOverRealHTTP() async throws {
        var preset = "standard"; var revision = 0; var refuseCommands = false; var commandReads = 0
        let server = try HTTPListener { request in
            let body = try! JSONDecoder().decode(JSON.self, from: request.body)
            let args = body["payload"]["args"]
            XCTAssertEqual(request.path, "/api/" + body["method"].text)
            switch body["method"].text {
            case "permissionPresets/catalog": return self.reply(["options": []])
            case "agentPresets/list": return self.reply(["presets": [["id": "standard"], ["id": "minimal"]]])
            case "agentPresets/select": XCTAssertEqual(args["agentId"], "S"); preset = args["agentPreset"].text; revision += 1; return self.reply([:])
            case "commands/list":
                XCTAssertEqual(args, ["agentId": "S"]); commandReads += 1
                if refuseCommands { return .init(status: 503) }
                return self.reply(preset == "minimal" ? [] : [["name": "plan"]])
            case "session/projections": return self.reply(["asOfSeq": .int(revision), "values": ["agentPreset": .string(preset), "sessionListMetadata": ["blank": true]]])
            default: XCTFail("Unexpected Plan request"); return .init(status: 404)
            }
        }
        let base = try await server.start(); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let chat = ChatStore(sessionID: "S", api: PortalAPI(base: base, client: client))
        XCTAssertFalse(chat.supportsPlan)
        try await chat.loadControls(); XCTAssertTrue(chat.supportsPlan)
        try await chat.selectPreset("minimal"); XCTAssertFalse(chat.supportsPlan); XCTAssertEqual(chat.projections["agentPreset"], "minimal")
        try await chat.selectPreset("standard"); XCTAssertTrue(chat.supportsPlan)
        refuseCommands = true
        do { try await chat.selectPreset("minimal"); XCTFail("Failed catalog accepted") } catch {}
        XCTAssertFalse(chat.supportsPlan); XCTAssertEqual(commandReads, 4)
    }
    func testRawUploadsAndAttachmentOnlyPromptOverRealHTTP() async throws {
        let bytes = Data([0, 255, 13, 10, 42]); var prompt: JSON = [:]
        let reference: JSON = ["attachmentId": "sha256:fixture", "name": "a+图.txt", "bytes": .int(bytes.count)]
        let server = try HTTPListener { request in
            if request.path.hasSuffix("/__portal/login") { return .init(status: 303, headers: ["Set-Cookie": "dsh_portal=fixture; Path=/; Max-Age=3600"]) }
            XCTAssertTrue(request.headers["cookie", default: ""].contains("dsh_portal=fixture"))
            XCTAssertEqual(request.headers["user-agent"], PortalClient.userAgent)
            XCTAssertEqual(request.headers["origin"], "http://" + request.headers["host", default: ""])
            if request.path.hasPrefix("/relay/api/session/uploadFileBinary?") {
                XCTAssertEqual(request.method, "POST"); XCTAssertEqual(request.headers["content-type"], "application/octet-stream"); XCTAssertEqual(request.body, bytes)
                XCTAssertTrue(request.path.contains("%2B"))
                let query = URLComponents(string: "http://test" + request.path)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "sessionId" }?.value, "S")
                XCTAssertEqual(query.first { $0.name == "name" }?.value, "a+图.txt")
                return .init(body: String(decoding: try! JSONEncoder().encode(["ok": true, "value": ["receiptId": "R", "file": reference]] as JSON), as: UTF8.self))
            }
            XCTAssertEqual(request.path, "/relay/api/session/prompt")
            prompt = try! JSONDecoder().decode(JSON.self, from: request.body)["payload"]["args"]["request"]
            return self.reply(["accepted": true])
        }
        let base = try await server.start().appendingPathComponent("relay/"); let directory = root(); let client = client(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("a+图.txt"); try bytes.write(to: file)
        let api = PortalAPI(base: base, client: client)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        try await api.login(secret: "secret", pairing: false)
        let value = try await api.upload(sessionID: "S", file: file, name: "a+图.txt", mediaType: nil)
        var attachment = DraftAttachment(id: UUID(), file: file, name: "a+图.txt", mediaType: nil, bytes: bytes.count)
        attachment.receipt = value; attachment.uploading = false
        let chat = ChatStore(sessionID: "S", api: api)
        try await chat.send("", attachments: [attachment])
        XCTAssertEqual(prompt["sessionId"], "S"); XCTAssertEqual(prompt["content"], [["type": "file", "receiptId": "R"]])
        XCTAssertEqual(chat.transcript.first?.blocks.first?.attachment, reference)
        XCTAssertEqual(chat.transcript.first?.blocks.first?.kind, "file")
        do { try await chat.send(""); XCTFail("Empty prompt accepted") } catch {}
        attachment.uploading = true
        do { try await chat.send("text", attachments: [attachment]); XCTFail("Unfinished upload accepted") } catch {}
    }
    func testImageUploadFailureRetryRemovalAndHistoricalReadOverRealHTTP() async throws {
        let data = png(); var uploads = 0
        let reference: JSON = ["attachmentId": "sha256:image", "mediaType": "image/png", "bytes": .int(data.count), "width": 2, "height": 2, "name": "photo.png"]
        let server = try HTTPListener { request in
            if request.path.hasPrefix("/api/session/uploadFileBinary?") {
                uploads += 1; XCTAssertEqual(request.body, data); XCTAssertTrue(request.path.contains("mediaType=image/png"))
                if uploads == 1 { return .init(body: "{\"ok\":false,\"error\":{\"code\":\"image/refused\",\"message\":\"Image refused\"}}") }
                return .init(body: String(decoding: try! JSONEncoder().encode(["ok": true, "value": ["receiptId": "I", "image": reference]] as JSON), as: UTF8.self))
            }
            XCTAssertEqual(request.path, "/api/session/attachment")
            let body = try! JSONDecoder().decode(JSON.self, from: request.body)
            XCTAssertEqual(body["payload"]["args"], ["request": ["sessionId": "S", "attachment": reference]])
            return self.reply(["attachment": reference, "data": .string(data.base64EncodedString())])
        }
        let base = try await server.start(); let directory = root(); let client = client(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("photo.png"); try data.write(to: file)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let api = PortalAPI(base: base, client: client); let store = AttachmentsStore(api: api, sessionID: "S", directory: directory.appendingPathComponent("drafts"))
        let limits: JSON = ["mediaTypes": ["image/png"], "maxImageBytes": 5000, "maxMessageImageBytes": 10000, "maxImagesPerMessage": 2, "maxImagePixels": 4, "maxImageDimension": 2]
        var smallDimensions = limits; smallDimensions["maxImageDimension"] = 1
        XCTAssertThrowsError(try store.add(file: file, mediaType: "image/png", limits: smallDimensions))
        var smallPixels = limits; smallPixels["maxImagePixels"] = 3
        XCTAssertThrowsError(try store.add(file: file, mediaType: "image/png", limits: smallPixels))
        try store.add(file: file, mediaType: "image/png", limits: limits)
        let failed = expectation(description: "Failed upload remains removable")
        let failedObservation = store.$items.first(where: { $0.first?.error != nil }).sink { _ in failed.fulfill() }
        await fulfillment(of: [failed], timeout: 3); failedObservation.cancel()
        XCTAssertFalse(store.ready); XCTAssertFalse(store.items[0].uploading)
        let ready = expectation(description: "Retry returns receipt")
        let readyObservation = store.$items.first(where: { $0.first?.ready == true }).sink { _ in ready.fulfill() }
        store.retry(store.items[0].id)
        await fulfillment(of: [ready], timeout: 3); readyObservation.cancel()
        XCTAssertTrue(store.ready); XCTAssertEqual(store.items[0].content, ["type": "file", "receiptId": "I"])
        XCTAssertEqual(store.items[0].reference, ["type": "image", "attachment": reference])
        var smallTotal = limits; smallTotal["maxMessageImageBytes"] = .int(2 * data.count - 1)
        XCTAssertThrowsError(try store.validate(bytes: data.count, mediaType: "image/png", limits: smallTotal))
        var smallCount = limits; smallCount["maxImagesPerMessage"] = 1
        XCTAssertThrowsError(try store.validate(bytes: data.count, mediaType: "image/png", limits: smallCount))
        let image = try await AttachmentReader.image(api: api, sessionID: "S", reference: reference)
        XCTAssertEqual(image.size, CGSize(width: 2, height: 2))
        let stagedFile = store.items[0].file; store.clear()
        XCTAssertTrue(store.items.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path))
        try store.add(file: file, mediaType: "image/png", limits: limits)
        store.remove(store.items[0].id); await Task.yield()
        XCTAssertTrue(store.items.isEmpty)
    }
    func testMalformedUploadsAndExpiryOverRealHTTP() async throws {
        for (status, body) in [(200, "{}"), (200, "bad JSON"), (200, "{\"ok\":true,\"value\":{}}"), (401, ""), (413, ""), (503, "")] {
            let server = try HTTPListener { _ in .init(status: status, body: body) }
            let base = try await server.start(); let directory = root(); let client = client(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("file.txt"); try Data("body".utf8).write(to: file)
            defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
            let api = PortalAPI(base: base, client: client)
            do { _ = try await api.upload(sessionID: "S", file: file, name: "file.txt", mediaType: nil); XCTFail("Invalid upload accepted") } catch {}
            XCTAssertEqual(api.sessionExpired, status == 401)
        }
    }
    func testMentionsNormalEmptyAndErrorOverRealHTTP() async throws {
        var queries: [String] = []
        let server = try HTTPListener { request in
            XCTAssertEqual(request.path, "/relay/api/fileReferences/list")
            let args = try! JSONDecoder().decode(JSON.self, from: request.body)["payload"]["args"]
            XCTAssertEqual(args["agentId"], "S"); queries.append(args["query"].text)
            if args["query"] == "fail" { return .init(status: 503) }
            return self.reply(args["query"] == "empty" ? [] : [["path": "a file.txt", "kind": "file"]])
        }
        let base = try await server.start().appendingPathComponent("relay/"); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let store = FileMentions(api: PortalAPI(base: base, client: client), sessionID: "S")
        await store.load("See @a"); XCTAssertEqual(store.candidates.count, 1); XCTAssertNil(store.error)
        await store.load("@"); XCTAssertEqual(queries.last, "")
        await store.load("@empty"); XCTAssertTrue(store.candidates.isEmpty); XCTAssertNil(store.error)
        await store.load("@fail"); XCTAssertTrue(store.candidates.isEmpty); XCTAssertNotNil(store.error); XCTAssertFalse(store.loading)
        await store.load("ordinary text"); XCTAssertNil(store.error); XCTAssertEqual(queries.count, 4)
    }
    func testWorkspaceFilesPagingImagesEmptyAndFailureOverRealHTTP() async throws {
        let data = png(); var reads = 0
        let server = try HTTPListener { request in
            let body = try! JSONDecoder().decode(JSON.self, from: request.body); let args = body["payload"]["args"]
            XCTAssertEqual(args["workspaceFileScopeId"], "S"); XCTAssertEqual(request.path, "/relay/api/" + body["method"].text)
            switch body["method"].text {
            case "workspaceFiles/list":
                if args["path"] == "bad" { return .init(status: 503) }
                return self.reply(["path": args["path"] == "." ? "" : args["path"], "entries": args["path"] == "." ? [["name": "Sources", "type": "directory"], ["name": "notes.swift", "type": "file"]] : [], "truncated": false])
            case "workspaceFiles/read":
                XCTAssertEqual(args["range"]["limit"], 200)
                if args["path"] == "empty.swift" { return self.reply(["text": "", "lines": 0, "eof": true, "version": "v1"]) }
                reads += 1; XCTAssertEqual(args["range"]["offset"], reads == 1 ? 1 : 3)
                return self.reply(["text": reads == 1 ? "line1\nline2" : "", "lines": reads == 1 ? 2 : 0, "eof": .bool(reads > 1), "version": "v1"])
            case "workspaceFiles/readBytes":
                XCTAssertEqual(args["options"], [:])
                let metadata: JSON = ["type": "server-response", "result": ["ok": true, "value": ["data": nil, "eof": true, "version": "v1"]], "attachments": [["codec": "bytes", "part": "binary", "path": ["data"]]]]
                return .init(headers: ["Content-Type": "multipart/form-data; boundary=\"drp-boundary\""], data: self.multipart(metadata, bytes: data))
            default: XCTFail("Unexpected files request"); return .init(status: 404)
            }
        }
        let base = try await server.start().appendingPathComponent("relay/"); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let api = PortalAPI(base: base, client: client); let store = WorkspaceFilesStore(api: api, sessionID: "S")
        await store.list(); XCTAssertTrue(store.loaded); XCTAssertEqual(store.child("Sources"), "Sources"); XCTAssertEqual(store.listing["entries"].array.count, 2)
        await store.list("Sources"); XCTAssertTrue(store.loaded); XCTAssertTrue(store.listing["entries"].array.isEmpty); XCTAssertEqual(store.parent, ".")
        await store.list("bad"); XCTAssertFalse(store.loaded); XCTAssertTrue(store.listing.object.isEmpty); XCTAssertNotNil(store.error)
        let preview = WorkspacePreviewStore(api: api, sessionID: "S", path: "notes.swift")
        await preview.load(); XCTAssertEqual(preview.text, "line1\nline2"); XCTAssertFalse(preview.eof)
        await preview.load(); XCTAssertEqual(preview.text, "line1\nline2"); XCTAssertTrue(preview.eof)
        let empty = WorkspacePreviewStore(api: api, sessionID: "S", path: "empty.swift")
        await empty.load(); XCTAssertTrue(empty.loaded); XCTAssertTrue(empty.text.isEmpty); XCTAssertTrue(empty.eof)
        let image = WorkspacePreviewStore(api: api, sessionID: "S", path: "image.png")
        await image.load(); XCTAssertEqual(image.imageData, data); XCTAssertTrue(image.eof); XCTAssertNil(image.error)
    }
    func testBinaryPreviewRejectsMalformedMultipartOverRealHTTP() async throws {
        let bytes = png()
        let baseMetadata: JSON = ["type": "server-response", "result": ["ok": true, "value": ["data": nil]], "attachments": [["codec": "bytes", "part": "binary", "path": ["data"]]]]
        for kind in ["extra", "placeholder", "codec", "path", "missing", "bad-json"] {
            var metadata = baseMetadata
            if kind == "placeholder" { metadata["result"]["value"]["data"] = "not null" }
            if ["codec", "path", "missing"].contains(kind) { metadata["attachments"] = [["codec": kind == "codec" ? "other" : "bytes", "part": kind == "missing" ? "absent" : "binary", "path": kind == "path" ? ["absent"] : ["data"]]] }
            let response = kind == "bad-json" ? Data("not multipart".utf8) : multipart(metadata, bytes: bytes, extra: kind == "extra")
            let server = try HTTPListener { _ in .init(headers: ["Content-Type": "multipart/form-data; boundary=drp-boundary"], data: response) }
            let base = try await server.start(); let directory = root(); let client = client(directory)
            defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
            let preview = WorkspacePreviewStore(api: PortalAPI(base: base, client: client), sessionID: "S", path: "image.png")
            await preview.load(); XCTAssertNotNil(preview.error); XCTAssertNil(preview.imageData); XCTAssertFalse(preview.loaded)
        }
    }
    func testWorkspacePreviewVersionChangesAndInvalidEmptyPagesOverRealHTTP() async throws {
        var calls = 0
        let server = try HTTPListener { request in
            XCTAssertEqual(request.path, "/api/workspaceFiles/read")
            calls += 1
            let args = try! JSONDecoder().decode(JSON.self, from: request.body)["payload"]["args"]
            XCTAssertEqual(args["range"]["offset"], calls == 1 || calls == 3 ? 1 : 2)
            return self.reply(["text": calls == 1 ? "old" : calls == 4 ? "" : "new", "lines": calls == 4 ? 0 : 1, "version": calls == 1 ? "v1" : "v2", "eof": false])
        }
        let base = try await server.start(); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let preview = WorkspacePreviewStore(api: PortalAPI(base: base, client: client), sessionID: "S", path: "source.swift")
        await preview.load(); XCTAssertEqual(preview.text, "old"); XCTAssertNil(preview.error)
        await preview.load(); XCTAssertEqual(preview.text, "old"); XCTAssertNotNil(preview.error)
        await preview.load(reload: true); XCTAssertEqual(preview.text, "new"); XCTAssertNil(preview.error)
        await preview.load(); XCTAssertNotNil(preview.error); XCTAssertEqual(preview.text, "new")
    }
    func testSettingsRevisionWritesConflictAndDeviceRevocationOverRealHTTP() async throws {
        var revision = 3; var writes = 0; var conflict = false
        var model: JSON = ["provider": "fake", "model": "one", "reasoningEffort": "high", "preserve": true]
        var permission: JSON = ["defaultPreset": "workspace-write", "preserve": true]
        var devices: [JSON] = [["id": "other", "label": "Other device"]]
        let server = try HTTPListener { request in
            if request.path == "/relay/dsh-remote-portal/status" { return .init(body: "{\"ok\":true,\"status\":{\"running\":true,\"authMode\":\"password\"}}") }
            if request.path == "/relay/dsh-remote-portal/devices" { return .init(body: String(decoding: try! JSONEncoder().encode(["ok": true, "devices": .array(devices)] as JSON), as: UTF8.self)) }
            if request.path == "/relay/dsh-remote-portal/devices/revoke" {
                XCTAssertEqual(request.method, "POST"); XCTAssertEqual(try! JSONDecoder().decode(JSON.self, from: request.body), ["id": "other"])
                devices = []; return .init(body: "{\"ok\":true}")
            }
            let body = try! JSONDecoder().decode(JSON.self, from: request.body); let args = body["payload"]["args"]
            XCTAssertEqual(request.path, "/relay/api/" + body["method"].text)
            switch body["method"].text {
            case "settings/describe": return self.reply(["writable": true, "namespaces": [["ns": "agent-default-model", "revision": .int(revision), "value": model], ["ns": "permission", "revision": .int(revision), "value": permission]]])
            case "session/modelCatalog": return self.reply(["groups": [], "routableProviders": []])
            case "permissionPresets/catalog": return self.reply(["defaultPreset": "workspace-write", "defaultOptions": [["value": "read-only"], ["value": "workspace-write"]]])
            case "settings/mutate":
                writes += 1; XCTAssertEqual(args["expectedRevision"], .int(revision)); revision += 1
                if conflict { model["model"] = "changed-elsewhere"; return .init(body: "{\"type\":\"server-response\",\"result\":{\"ok\":false,\"error\":{\"code\":\"settings/conflict\",\"message\":\"Changed\"}}}") }
                var value = args["ns"] == "permission" ? permission.object : model.object
                for op in args["ops"].array {
                    let path = op["path"].array; XCTAssertEqual(path.count, 1)
                    if op["op"] == "unset" { value.removeValue(forKey: path[0].text) } else { value[path[0].text] = op["value"] }
                }
                if args["ns"] == "permission" { permission = .object(value) } else { model = .object(value) }
                return self.reply([:])
            default: XCTFail("Unexpected settings request"); return .init(status: 404)
            }
        }
        let base = try await server.start().appendingPathComponent("relay/"); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let store = HostSettingsStore(api: PortalAPI(base: base, client: client))
        await store.load(); XCTAssertTrue(store.writable); XCTAssertEqual(store.devices.count, 1); XCTAssertNil(store.portalError)
        try await store.setDefaultModel(provider: "fake", model: "two", effort: "off")
        XCTAssertEqual(store.defaultModel["reasoningEffort"], "off"); XCTAssertEqual(model["preserve"], true)
        try await store.setDefaultModel(provider: "fake", model: "two", effort: nil); XCTAssertEqual(store.defaultModel["reasoningEffort"], .null)
        try await store.setDefaultPermission("read-only"); XCTAssertEqual(store.defaultPermission, "read-only"); XCTAssertEqual(permission["preserve"], true)
        conflict = true
        do { try await store.setDefaultModel(provider: "fake", model: "one", effort: nil); XCTFail("Stale write accepted") } catch { XCTAssertTrue(error.localizedDescription.contains(L("another client", "其他客户端"))) }
        XCTAssertEqual(store.defaultModel["model"], "changed-elsewhere"); XCTAssertEqual(writes, 4); XCTAssertFalse(store.busy)
        try await store.revoke("other"); XCTAssertTrue(store.devices.isEmpty)
    }
    func testSettingsReadOnlyAndMissingPortalDoNotPreventHostReads() async throws {
        let server = try HTTPListener { request in
            if request.path.contains("dsh-remote-portal") { return .init(status: 404, body: "{\"ok\":false,\"error\":\"Unavailable\"}") }
            let method = try! JSONDecoder().decode(JSON.self, from: request.body)["method"].text
            switch method {
            case "settings/describe": return self.reply(["writable": false, "namespaces": []])
            case "session/modelCatalog": return self.reply(["groups": []])
            case "permissionPresets/catalog": return self.reply(["defaultOptions": []])
            default: XCTFail("Read-only store attempted a write"); return .init(status: 500)
            }
        }
        let base = try await server.start(); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let store = HostSettingsStore(api: PortalAPI(base: base, client: client)); await store.load()
        XCTAssertTrue(store.loaded); XCTAssertFalse(store.writable); XCTAssertNil(store.error); XCTAssertNotNil(store.portalError)
        do { try await store.setDefaultPermission("read-only"); XCTFail("Read-only write accepted") } catch {}
    }
    func testDeferredApprovalReopensAndAnswersOverRealHTTP() async throws {
        var calls: [JSON] = []
        let server = try HTTPListener { request in
            XCTAssertEqual(request.path, "/relay/api/$events/result")
            let body = try! JSONDecoder().decode(JSON.self, from: request.body)
            calls.append(body)
            XCTAssertEqual(body["payload"]["args"], ["clientId": "client", "eventId": "E", "outcome": ["kind": "result", "value": "allowed-once"]])
            if calls.count == 1 { return .init(status: 503) }
            return .init(body: "{\"type\":\"server-response\",\"result\":{\"ok\":true}}")
        }
        let base = try await server.start().appendingPathComponent("relay/"); let directory = root(); let client = client(directory)
        defer { server.stop(); client.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let events = RemoteEvents(api: PortalAPI(base: base, client: client))
        events.apply(["type": "ready", "clientId": "client"])
        events.apply(["type": "waterfall", "event": "approval/request", "eventId": "E", "agentId": "B", "request": ["agentId": "not-the-session"]])
        var routing = InteractionRouting()
        routing.reconcile(events.pending, openSessionID: "A")
        XCTAssertNil(routing.presentedID)
        let item = try XCTUnwrap(events.pending.first)
        XCTAssertEqual(InteractionRouting.sessionID(item, knownSessionIDs: ["A", "B"]), "B")
        routing.review(item); routing.dismiss()
        routing.reconcile(events.pending, openSessionID: "B")
        XCTAssertNil(routing.presentedID)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(events.pending, [item])
        routing.review(item)
        do { try await events.answerApproval(item.id, allow: true); XCTFail("Failure swallowed") } catch {}
        XCTAssertEqual(events.pending, [item])
        routing.reconcile(events.pending, openSessionID: "B")
        XCTAssertEqual(routing.presentedID, "E")
        try await events.answerApproval(item.id, allow: true)
        routing.reconcile(events.pending, openSessionID: "B")
        XCTAssertTrue(events.pending.isEmpty)
        XCTAssertNil(routing.presentedID)
        XCTAssertEqual(calls.count, 2)
    }
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
        store.applyWorkspace(["type": "baseline", "value": ["items": []]])
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
            XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"), locale == "en" ? "Take a photo to attach to your DeepSeek Harness message." : "拍摄照片并添加到 DeepSeek Harness 消息中。")
        }
    }
}
