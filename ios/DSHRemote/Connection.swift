import Foundation

struct Server: Identifiable, Codable {
    var id = UUID()
    var name: String
    var addresses: [URL]
}

enum PortalURL {
    static func normalize(_ input: String) throws -> URL {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host != nil, c.user == nil, c.password == nil else { throw PortalError.message(L("Enter a valid HTTP(S) address.", "请输入有效的 HTTP(S) 地址。")) }
        c.query = nil
        c.fragment = nil
        if !c.path.hasSuffix("/") { c.path += "/" }
        guard let url = c.url else { throw PortalError.message(L("Invalid address.", "地址无效。")) }
        return url
    }

    static func pairing(_ input: String) throws -> (URL, String)? {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.path.hasSuffix("/__portal/pair") else { return nil }
        guard let token = c.queryItems?.first(where: { $0.name == "t" })?.value, !token.isEmpty else {
            throw PortalError.message(L("Pairing link has no token.", "配对链接缺少令牌。"))
        }
        c.path = String(c.path.dropLast("__portal/pair".count))
        c.query = nil
        c.fragment = nil
        return (try normalize(c.string ?? ""), token)
    }

    static func origin(_ base: URL) -> String {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = ""; c.query = nil; c.fragment = nil
        return c.string!
    }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)!
    }
}

func L(_ english: String, _ chinese: String, languages: [String] = Locale.preferredLanguages) -> String {
    languages.first?.hasPrefix("zh") == true ? chinese : english
}

enum PortalError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct HealthResult {
    let base: URL
    let milliseconds: Int
    var label: String {
        let host = base.host ?? ""
        let lan = host == "localhost" || host == "::1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("127.") || host.hasSuffix(".local") || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
        return "\(lan ? "LAN" : L("Public", "公网")) · \(milliseconds) ms · \(base.absoluteString)"
    }
}

final class PortalClient: NSObject, URLSessionTaskDelegate {
    static let shared = PortalClient()
    let cookies: CookieVault
    private let configuration: URLSessionConfiguration
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 DSHRemote/1.0"
    lazy var session: URLSession = {
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpShouldSetCookies = false
        config.httpCookieStorage = .shared
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    init(configuration: URLSessionConfiguration = .default, cookies: CookieVault = CookieVault()) {
        self.configuration = configuration; self.cookies = cookies
        super.init(); _ = session
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func race(_ addresses: [URL], probe: @escaping (URL) async throws -> Int) async throws -> HealthResult {
        try await withThrowingTaskGroup(of: HealthResult?.self) { group in
            for base in addresses {
                group.addTask {
                    do { return HealthResult(base: base, milliseconds: try await probe(base)) }
                    catch { return nil }
                }
            }
            for try await result in group {
                if let result { group.cancelAll(); return result }
            }
            throw PortalError.message(L("No address responded. Check your server and network.", "所有地址均无法连接，请检查服务器和网络。"))
        }
    }

    func connect(_ addresses: [URL]) async throws -> HealthResult {
        try await Self.race(addresses) { base in
            var request = URLRequest(url: base.appendingPathComponent("__portal/health"))
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let start = Date()
            let (_, response) = try await self.session.data(for: request)
            if let http = response as? HTTPURLResponse { try self.cookies.ingest(http, base: base) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PortalError.message(L("Server is unavailable.", "服务器不可用。")) }
            return Int(Date().timeIntervalSince(start) * 1000)
        }
    }

    func post(_ base: URL, endpoint: String, fields: [String: String]) async throws -> [HTTPCookie] {
        let url = base.appendingPathComponent("__portal/\(endpoint)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = PortalURL.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(L("en", "zh"), forHTTPHeaderField: "Accept-Language")
        request.setValue(PortalURL.origin(base), forHTTPHeaderField: "Origin")
        for (key, value) in HTTPCookie.requestHeaderFields(with: cookies.cookies(for: base, at: url)) { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        try cookies.ingest(http, base: base)
        if http.statusCode == 429 {
            throw PortalError.message(L("Too many attempts. Try again after \(http.value(forHTTPHeaderField: "Retry-After") ?? "a few") seconds.", "尝试次数过多，请稍后重试（\(http.value(forHTTPHeaderField: "Retry-After") ?? "若干")秒）。"))
        }
        guard http.statusCode == 303 || (endpoint == "logout" && (200..<300).contains(http.statusCode)) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = [json?["error"], json?["message"]].compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            throw PortalError.message(message ?? (endpoint == "logout" ? L("Sign-out failed. Please try again.", "退出登录失败，请重试。") : L("Sign-in failed. Check your password or pairing code.", "登录失败，请检查密码或配对码。")))
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in result[String(describing: item.key)] = String(describing: item.value) }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
    }
}
