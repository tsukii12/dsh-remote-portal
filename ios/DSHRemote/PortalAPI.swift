import Foundation
import Combine
import CryptoKit

enum APIError: LocalizedError, Equatable {
    case sessionExpired, invalidResponse, http(Int), remote(String, String), disconnected
    var errorDescription: String? {
        switch self {
        case .sessionExpired: return L("Please sign in again.", "请重新登录。")
        case .invalidResponse: return L("Invalid server response.", "服务器响应无效。")
        case .http(let status): return L("Server request failed (HTTP \(status)).", "服务器请求失败（HTTP \(status)）。")
        case .remote(_, let message): return message
        case .disconnected: return L("Connection closed.", "连接已关闭。")
        }
    }
}

final class CookieVault {
    private let root: URL
    private let lock = NSLock()
    private var jars: [String: [HTTPCookie]] = [:]
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PortalCookies")) { self.root = root }
    private func file(_ base: URL) -> URL {
        root.appendingPathComponent(SHA256.hash(data: Data(base.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
    private func load(_ base: URL) -> [HTTPCookie] {
        if let jar = jars[base.absoluteString] { return jar }
        let rows = (try? Data(contentsOf: file(base))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: String]] } ?? []
        let jar = rows.compactMap { row -> HTTPCookie? in
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in row { properties[HTTPCookiePropertyKey(key)] = value }
            if let timestamp = row[HTTPCookiePropertyKey.expires.rawValue].flatMap(Double.init) { properties[.expires] = Date(timeIntervalSince1970: timestamp) }
            return HTTPCookie(properties: properties)
        }
        jars[base.absoluteString] = jar
        return jar
    }
    func cookies(for base: URL, at url: URL) -> [HTTPCookie] {
        lock.lock(); defer { lock.unlock() }
        return load(base).filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let host = url.host?.lowercased() ?? ""
            let pathMatches = url.path == cookie.path || url.path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            return (cookie.expiresDate ?? .distantFuture) > Date() && (!cookie.isSecure || ["https", "wss"].contains(url.scheme)) && (host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))) && pathMatches
        }
    }
    func ingest(_ response: HTTPURLResponse, base: URL) throws {
        guard let url = response.url else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !incoming.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var jar = load(base)
        for cookie in incoming {
            jar.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            HTTPCookieStorage.shared.setCookie(cookie)
            if (cookie.expiresDate ?? .distantFuture) > Date() { jar.append(cookie) }
        }
        jars[base.absoluteString] = jar
        try persist(jar, base: base)
    }
    private func persist(_ jar: [HTTPCookie], base: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rows = jar.map { cookie -> [String: String] in
            var row: [String: String] = [:]
            for (key, value) in cookie.properties ?? [:] { row[key.rawValue] = String(describing: value) }
            row.removeValue(forKey: HTTPCookiePropertyKey.maximumAge.rawValue)
            if let expires = cookie.expiresDate { row[HTTPCookiePropertyKey.expires.rawValue] = String(expires.timeIntervalSince1970) }
            return row
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: file(base), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func clear(_ base: URL) throws {
        lock.lock(); defer { lock.unlock() }
        for cookie in load(base) { HTTPCookieStorage.shared.deleteCookie(cookie) }
        jars[base.absoluteString] = []
        if FileManager.default.fileExists(atPath: file(base).path) { try FileManager.default.removeItem(at: file(base)) }
    }
}

@MainActor
protocol RPCServing: AnyObject {
    func rpc(_ method: String, args: JSON) async throws -> JSON
    func stream(_ endpoint: String, args: JSON) -> AsyncThrowingStream<JSON, Error>
    func portal(_ path: String, query: [URLQueryItem], body: JSON?) async throws -> JSON
    func exportSession(_ id: String) async throws -> URL
    func upload(sessionID: String, file: URL, name: String, mediaType: String?) async throws -> JSON
}

extension RPCServing {
    func portal(_ path: String, query: [URLQueryItem], body: JSON?) async throws -> JSON { throw APIError.invalidResponse }
    func exportSession(_ id: String) async throws -> URL { throw APIError.invalidResponse }
    func upload(sessionID: String, file: URL, name: String, mediaType: String?) async throws -> JSON { throw APIError.invalidResponse }
}

@MainActor
final class PortalAPI: ObservableObject, RPCServing {
    let base: URL
    let client: PortalClient
    @Published private(set) var sessionExpired = false
    lazy var mux = PortalMux(api: self)
    init(base: URL, client: PortalClient = .shared) { self.base = base; self.client = client }

    func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue(PortalClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(PortalURL.origin(base), forHTTPHeaderField: "Origin")
        let cookies = client.cookies.cookies(for: base, at: request.url!)
        for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
    static func envelope(_ method: String, args: JSON, id: String = UUID().uuidString) -> JSON {
        ["type": "client-request", "rpcId": .string(id), "method": .string(method), "payload": ["args": args]]
    }
    static func decode(_ data: Data, status: Int, contentType: String? = nil) throws -> JSON {
        if status == 401 { throw APIError.sessionExpired }
        guard (200..<300).contains(status) else { throw APIError.http(status) }
        let decoded = try BinaryRPC.decode(data, contentType: contentType)
        guard let body = try? JSONDecoder().decode(JSON.self, from: decoded), body["type"] == "server-response", [JSON.bool(true), .bool(false)].contains(body["result"]["ok"]) else { throw APIError.invalidResponse }
        guard body["result"]["ok"].boolean else {
            let error = body["result"]["error"]
            throw APIError.remote(error["code"].text, error["message"].string ?? L("Request failed.", "请求失败。"))
        }
        return body["result"]["value"]
    }
    func rpc(_ method: String, args: JSON = [:]) async throws -> JSON {
        var request = request("api/" + method)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Self.envelope(method, args: args))
        do {
            let (data, response) = try await client.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            try client.cookies.ingest(http, base: base)
            return try Self.decode(data, status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        } catch APIError.sessionExpired { expire(); throw APIError.sessionExpired }
    }
    func upload(sessionID: String, file: URL, name: String, mediaType: String? = nil) async throws -> JSON {
        var request = request("api/session/uploadFileBinary")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionID), URLQueryItem(name: "name", value: name)]
        if let mediaType { components.queryItems?.append(URLQueryItem(name: "mediaType", value: mediaType)) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        request.url = components.url; request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await client.session.upload(for: request, fromFile: file)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            try client.cookies.ingest(http, base: base)
            if http.statusCode == 401 { throw APIError.sessionExpired }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
            guard let body = try? JSONDecoder().decode(JSON.self, from: data), [JSON.bool(true), .bool(false)].contains(body["ok"]) else { throw APIError.invalidResponse }
            guard body["ok"].boolean else {
                throw APIError.remote(body["error"]["code"].text, body["error"]["message"].string ?? L("Upload failed.", "上传失败。"))
            }
            let value = body["value"]
            guard let receipt = value["receiptId"].string, !receipt.isEmpty,
                  value[mediaType == nil ? "file" : "image"]["attachmentId"].string != nil else { throw APIError.invalidResponse }
            return value
        } catch APIError.sessionExpired { expire(); throw APIError.sessionExpired }
    }
    func login(secret: String, pairing: Bool) async throws {
        _ = try await client.post(base, endpoint: "login", fields: [pairing ? "token" : "password": secret])
        sessionExpired = false
    }
    func exportSession(_ id: String) async throws -> URL {
        var request = request("api/session.export")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sessionId", value: id)]; request.url = components.url
        do {
            let (data, response) = try await client.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            try client.cookies.ingest(http, base: base)
            if http.statusCode == 401 { throw APIError.sessionExpired }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
            guard data.starts(with: [0x50, 0x4b]) else { throw APIError.invalidResponse }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("DRP-session-\(UUID().uuidString).zip")
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            return file
        } catch APIError.sessionExpired { expire(); throw APIError.sessionExpired }
    }
    func portal(_ path: String, query: [URLQueryItem] = [], body: JSON? = nil) async throws -> JSON {
        var request = request("dsh-remote-portal/" + path)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        request.url = components.url
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        do {
            let (data, response) = try await client.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            try client.cookies.ingest(http, base: base)
            if http.statusCode == 401 { throw APIError.sessionExpired }
            let value = try? JSONDecoder().decode(JSON.self, from: data)
            guard (200..<300).contains(http.statusCode), value?["ok"].boolean == true else {
                throw APIError.remote(value?["code"].text ?? "portal/http-\(http.statusCode)", value?["error"].string ?? L("Host folder request failed.", "主机文件夹请求失败。"))
            }
            return value!
        } catch APIError.sessionExpired { expire(); throw APIError.sessionExpired }
    }
    func logout() async throws {
        _ = try await client.post(base, endpoint: "logout", fields: [:])
        try client.cookies.clear(base)
        expire()
    }
    func expire() { sessionExpired = true; mux.close() }
    func stream(_ endpoint: String, args: JSON = [:]) -> AsyncThrowingStream<JSON, Error> { mux.open(endpoint, args: args) }
}
