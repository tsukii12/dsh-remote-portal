import SwiftUI
import WebKit

@main
struct DSHRemoteApp: App {
    var body: some Scene { WindowGroup { ServersView() } }
}

@MainActor
final class ServerStore: ObservableObject {
    @Published var servers: [Server] = [] { didSet { save() } }
    init() {
        if let data = UserDefaults.standard.data(forKey: "servers"), let saved = try? JSONDecoder().decode([Server].self, from: data) { servers = saved }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: "servers") }
    }
}

struct ServersView: View {
    @StateObject private var store = ServerStore()
    @State private var editing: Server?
    @State private var adding = false
    @State private var selected: Server?
    @State private var pairToken = ""
    var body: some View {
        NavigationStack {
            List {
                if store.servers.isEmpty {
                    ContentUnavailableView(L("Your workspace, anywhere", "随时连接你的工作区"), systemImage: "network", description: Text(L("Add your computer’s portal address or paste a pairing link.", "添加电脑的门户地址，或粘贴配对链接。")))
                }
                ForEach(store.servers) { server in
                    Button { pairToken = ""; selected = server } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(server.name).font(.headline).foregroundStyle(.primary)
                            Text(server.addresses.map(\.absoluteString).joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button(role: .destructive) { store.servers.removeAll { $0.id == server.id } } label: { Label(L("Delete", "删除"), systemImage: "trash") } }
                    .contextMenu { Button(L("Edit", "编辑")) { editing = server } }
                }
            }
            .navigationTitle("dsh Remote")
            .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $adding) { ServerEditor(server: nil) { server, token in
                store.servers.append(server)
                if !token.isEmpty { pairToken = token; selected = server }
            } }
            .sheet(item: $editing) { server in ServerEditor(server: server) { updated, _ in
                if let i = store.servers.firstIndex(where: { $0.id == updated.id }) { store.servers[i] = updated }
            } }
            .fullScreenCover(item: $selected) { server in ConnectionView(server: server, initialToken: pairToken) }
        }
    }
}

struct ServerEditor: View {
    let server: Server?
    let save: (Server, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var addresses = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField(L("Name", "名称"), text: $name)
                Section(L("Addresses (one per line) or pairing link", "地址（每行一个）或配对链接")) {
                    TextEditor(text: $addresses).frame(minHeight: 140).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text(L("Keep relay path prefixes, e.g. https://relay.example/__t/id/", "保留中继路径前缀，例如 https://relay.example/__t/id/")).font(.caption)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L("Server", "服务器"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Save", "保存")) {
                    do {
                        let lines = addresses.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        guard !lines.isEmpty else { throw PortalError.message(L("Add at least one address.", "请添加至少一个地址。")) }
                        var urls: [URL] = []; var token = ""
                        for line in lines {
                            if let pair = try PortalURL.pairing(line) { urls.append(pair.0); token = pair.1 }
                            else { urls.append(try PortalURL.normalize(line)) }
                        }
                        save(Server(id: server?.id ?? UUID(), name: name.isEmpty ? (urls[0].host ?? "dsh") : name, addresses: urls), token)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                } }
            }
            .onAppear { name = server?.name ?? ""; addresses = server?.addresses.map(\.absoluteString).joined(separator: "\n") ?? "" }
        }
    }
}

@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var needsLogin = false
    @Published var error = ""
    var base: URL?
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.customUserAgent = PortalClient.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.loadHTMLString("<html></html>", baseURL: nil)
    }
    func open(_ base: URL) { self.base = base; needsLogin = false; webView.load(URLRequest(url: base)) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url, let base,
           PortalURL.origin(url) == PortalURL.origin(base), url.path == base.appendingPathComponent("__portal/login").path {
            needsLogin = true; decisionHandler(.cancel); return
        }
        if let scheme = navigationAction.request.url?.scheme, !["http", "https", "about", "blob", "data"].contains(scheme) { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let base, let url = webView.url, PortalURL.origin(url) == PortalURL.origin(base) else { return }
        let loginPath = base.appendingPathComponent("__portal/login").path
        webView.evaluateJavaScript("Array.from(document.forms).map(f => new URL(f.action, document.baseURI).pathname)") { [weak self] value, _ in
            if let paths = value as? [String], paths.contains(loginPath) { self?.needsLogin = true }
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }; return nil
    }
}

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ConnectionView: View {
    let server: Server
    let initialToken: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var browser = Browser()
    @State private var result: HealthResult?
    @State private var busy = false
    @State private var error = ""
    @State private var secret = ""
    @State private var pairing = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let result { Text(result.label).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(6) }
                if result != nil && !browser.needsLogin {
                    WebSurface(webView: browser.webView)
                    if !browser.error.isEmpty { Text(browser.error).font(.caption).foregroundStyle(.red) }
                } else if result != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack { Image(systemName: "sparkle").font(.title); Text("DeepSeek").font(.title2.bold()); Text("HARNESS").font(.caption.bold()).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 5)) }
                            Text(L("REMOTE ACCESS", "远程访问")).font(.caption).foregroundStyle(.secondary)
                            Text(L("Verify this device", "验证这台设备")).font(.largeTitle.bold())
                            Text(pairing
                                 ? L("Enter the pairing code generated on your computer to connect this device to DeepSeek Harness.", "输入在电脑端生成的配对码，将这台设备接入 DeepSeek Harness。")
                                 : L("This device is reaching DeepSeek Harness on your computer. Enter the access password to continue.", "这台设备正在访问你电脑上的 DeepSeek Harness。输入访问密码即可进入工作区。")).foregroundStyle(.secondary)
                            Picker(L("Sign in with", "登录方式"), selection: $pairing) {
                                Text(L("Password", "密码")).tag(false)
                                Text(L("Pairing code", "配对码")).tag(true)
                            }.pickerStyle(.segmented)
                            SecureField(pairing ? L("Pairing code", "配对码") : L("Access password", "访问密码"), text: $secret).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.callout) }
                            Button { Task { await login() } } label: {
                                HStack { Spacer(); if busy { ProgressView() }; Text(L("Continue", "继续")); Spacer() }.padding(10)
                            }.buttonStyle(.borderedProminent).tint(.primary).disabled(busy || secret.isEmpty)
                        }.padding(28).frame(maxWidth: 460)
                    }.frame(maxWidth: .infinity).background(colorScheme == .dark ? Color(red: 21/255, green: 21/255, blue: 23/255) : .white)
                } else {
                    Spacer()
                    if busy { ProgressView(L("Finding fastest address…", "正在寻找最快地址…")) }
                    if !error.isEmpty { Text(error).padding(); Button(L("Retry", "重试")) { Task { await connect() } } }
                    Spacer()
                }
            }
            .navigationTitle(server.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if result != nil && !browser.needsLogin {
                        Button { browser.error = ""; browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                        Button(L("Log out", "退出")) { Task { await logout() } }.disabled(busy)
                    }
                }
            }
            .alert(L("Connection error", "连接错误"), isPresented: Binding(get: { !error.isEmpty && result != nil && !browser.needsLogin }, set: { if !$0 { error = "" } })) { Button("OK") { error = "" } } message: { Text(error) }
            .task { secret = initialToken; pairing = !initialToken.isEmpty; await connect() }
        }
    }
    private func connect() async {
        busy = true; error = ""
        do {
            let winner = try await PortalClient.shared.connect(server.addresses)
            result = winner
            if !initialToken.isEmpty { browser.base = winner.base; browser.needsLogin = true }
            else { browser.open(winner.base) }
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    private func login() async {
        guard let result else { return }
        busy = true; error = ""
        do {
            let cookies = try await PortalClient.shared.post(result.base, endpoint: "login", fields: [pairing ? "token" : "password": secret])
            guard cookies.contains(where: { $0.name == "dsh_portal" }) else { throw PortalError.message(L("Server did not return a session cookie.", "服务器未返回会话 Cookie。")) }
            for cookie in cookies { await browser.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
            secret = ""; browser.open(result.base)
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    private func logout() async {
        guard let result else { return }
        busy = true
        do {
            let store = browser.webView.configuration.websiteDataStore.httpCookieStore
            let cookies = await store.allCookies()
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return result.base.host == domain || (cookie.domain.hasPrefix(".") && (result.base.host?.hasSuffix("." + domain) ?? false))
            }
            _ = try await PortalClient.shared.post(result.base, endpoint: "logout", fields: [:], cookies: matching)
            for cookie in matching { await store.deleteCookie(cookie) }
            browser.webView.stopLoading(); browser.needsLogin = true
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}
