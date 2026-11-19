import Foundation
import Combine
import CryptoKit

enum APIError: LocalizedError, Equatable {
    case sessionExpired, invalidResponse, http(Int), remote(String, String), disconnected
    var errorDescription: String? {
        switch self {
        case .sessionExpired: return L("Please sign in again.", "请重新登录。")
        case .invalidResponse: return "Invalid server response"
        case .http(let status): return "HTTP \(status)"
        case .remote(_, let message): return message
        case .disconnected: return "Connection closed"
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
    static func decode(_ data: Data, status: Int) throws -> JSON {
        if status == 401 { throw APIError.sessionExpired }
        guard (200..<300).contains(status) else { throw APIError.http(status) }
        guard let body = try? JSONDecoder().decode(JSON.self, from: data), body["type"] == "server-response", [JSON.bool(true), .bool(false)].contains(body["result"]["ok"]) else { throw APIError.invalidResponse }
        guard body["result"]["ok"].boolean else {
            let error = body["result"]["error"]
            throw APIError.remote(error["code"].text, error["message"].string ?? "Request failed")
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
            return try Self.decode(data, status: http.statusCode)
        } catch APIError.sessionExpired { expire(); throw APIError.sessionExpired }
    }
    func login(secret: String, pairing: Bool) async throws {
        _ = try await client.post(base, endpoint: "login", fields: [pairing ? "token" : "password": secret])
        sessionExpired = false
    }
    func logout() async throws {
        _ = try await client.post(base, endpoint: "logout", fields: [:])
        try client.cookies.clear(base)
        expire()
    }
    func expire() { sessionExpired = true; mux.close() }
    func stream(_ endpoint: String, args: JSON = [:]) -> AsyncThrowingStream<JSON, Error> { mux.open(endpoint, args: args) }
}
