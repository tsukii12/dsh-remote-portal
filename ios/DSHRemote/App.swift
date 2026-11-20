import SwiftUI

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
            .navigationTitle("DeepSeek Remote")
            .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel(L("Add server", "添加服务器")) }
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
    @State private var scanning = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField(L("Name", "名称"), text: $name)
                Section(L("Addresses (one per line) or pairing link", "地址（每行一个）或配对链接")) {
                    TextEditor(text: $addresses).frame(minHeight: 140).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button { scanning = true } label: { Label(L("Scan pairing QR", "扫描配对二维码"), systemImage: "qrcode.viewfinder") }
                    Text(L("Keep relay path prefixes, e.g. https://relay.example/__t/id/", "保留中继路径前缀，例如 https://relay.example/__t/id/")).font(.caption)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L("Server", "服务器"))
            .sheet(isPresented: $scanning) { PairingScanner { value in
                _ = try PortalURL.scannedPairing(value)
                addresses = value
            } }
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

struct ConnectionView: View {
    let server: Server
    let initialToken: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var network = PortalPathMonitor()
    @State private var foregroundRevision = 0
    @State private var gateToken: String?
    @State private var result: HealthResult?
    @State private var api: PortalAPI?
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        Group {
            if let api { NativeConnectionGate(api: api, initialToken: gateToken ?? "", serverName: server.name, addressLabel: result?.label ?? "", onSwitch: { dismiss() }).id(api.base.absoluteString) }
            else {
                NavigationStack {
                    VStack(spacing: 20) {
                        if busy { ProgressView(L("Finding best address…", "正在寻找最佳地址…")) }
                        if !error.isEmpty { Text(error); Button(L("Retry", "重试")) { Task { await connect() } } }
                    }
                    .navigationTitle("DRP")
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel(L("Servers", "服务器")) } }
                }
            }
        }
        .tint(DRPStyle.accent)
        .task(id: "\(network.revision):\(foregroundRevision)") { await connect() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { foregroundRevision += 1 } }
    }
    private func connect() async {
        busy = true; error = ""
        do {
            let winner = try await PortalClient.shared.connect(server.addresses)
            try Task.checkCancellation()
            if api?.base != winner.base {
                gateToken = api == nil ? initialToken : ""
                api = PortalAPI(base: winner.base)
            }
            result = winner
        }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        guard !Task.isCancelled else { return }
        busy = false
    }
}

struct NativeConnectionGate: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var api: PortalAPI
    @StateObject private var connection: NativeConnection
    @State private var signedIn = false
    @State private var secret: String
    @State private var pairing: Bool
    @State private var scanning = false
    @State private var error = ""
    @State private var busy = false
    let serverName: String
    let addressLabel: String
    let onSwitch: () -> Void
    init(api: PortalAPI, initialToken: String, serverName: String, addressLabel: String, onSwitch: @escaping () -> Void) {
        self.api = api
        self.serverName = serverName; self.onSwitch = onSwitch
        self.addressLabel = addressLabel
        _connection = StateObject(wrappedValue: NativeConnection(api: api))
        _secret = State(initialValue: initialToken); _pairing = State(initialValue: !initialToken.isEmpty)
    }
    var body: some View {
        Group {
            if signedIn {
                WorkspaceView(connection: connection, serverName: serverName, addressLabel: addressLabel, onSwitch: { connection.stop(); onSwitch() }, onLogout: {
                    try await api.logout(); connection.stop(); signedIn = false
                })
            } else {
                NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack { Image(systemName: "sparkle").font(.title).foregroundStyle(DRPStyle.accent); Text("DRP").font(.title.bold()) }
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
                        Button { scanning = true } label: { Label(L("Scan pairing QR", "扫描配对二维码"), systemImage: "qrcode.viewfinder") }.disabled(busy)
                        if !error.isEmpty { Text(error).foregroundStyle(.red).font(.callout) }
                        Button { Task { await login() } } label: {
                            HStack { Spacer(); if busy { ProgressView() }; Text(L("Continue", "继续")); Spacer() }.padding(10)
                        }.buttonStyle(.borderedProminent).disabled(busy || secret.isEmpty)
                    }.padding(28).frame(maxWidth: 460)
                }.frame(maxWidth: .infinity).background(colorScheme == .dark ? Color(red: 21/255, green: 21/255, blue: 23/255) : .white)
                .navigationTitle("DRP").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button(action: onSwitch) { Label(L("Servers", "服务器"), systemImage: "chevron.left") } } }
                }
            }
        }
        .task { if secret.isEmpty { await resume() } }
        .sheet(isPresented: $scanning) { PairingScanner { value in
            let pair = try PortalURL.scannedPairing(value, matching: api.base)
            secret = pair.1; pairing = true
        } }
        .onChange(of: api.sessionExpired) { _, expired in if expired { signedIn = false; connection.stop() } }
        .onDisappear { connection.stop() }
    }
    private func resume() async {
        busy = true
        do { try await connection.start(); signedIn = true }
        catch APIError.sessionExpired { signedIn = false }
        catch { self.error = error.localizedDescription }
        busy = false
    }
    private func login() async {
        busy = true; error = ""
        do { try await api.login(secret: secret, pairing: pairing); secret = ""; try await connection.start(); signedIn = true }
        catch { self.error = error.localizedDescription }
        busy = false
    }
}
