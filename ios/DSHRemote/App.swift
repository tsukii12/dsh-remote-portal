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

struct ConnectionView: View {
    let server: Server
    let initialToken: String
    @Environment(\.dismiss) private var dismiss
    @State private var result: HealthResult?
    @State private var api: PortalAPI?
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Group {
                if let api { NativeConnectionGate(api: api, initialToken: initialToken) }
                else if busy { ProgressView(L("Finding fastest address…", "正在寻找最快地址…")) }
                else { VStack { Text(error); Button(L("Retry", "重试")) { Task { await connect() } } } }
            }
            .safeAreaInset(edge: .top) { if let result { Text(result.label).font(.caption2).foregroundStyle(.secondary) } }
            .navigationTitle(server.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") } } }
            .task { await connect() }
        }
    }
    private func connect() async {
        busy = true; error = ""
        do { let winner = try await PortalClient.shared.connect(server.addresses); result = winner; api = PortalAPI(base: winner.base) }
        catch { self.error = error.localizedDescription }
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
    @State private var error = ""
    @State private var busy = false
    init(api: PortalAPI, initialToken: String) {
        self.api = api
        _connection = StateObject(wrappedValue: NativeConnection(api: api))
        _secret = State(initialValue: initialToken); _pairing = State(initialValue: !initialToken.isEmpty)
    }
    var body: some View {
        VStack(spacing: 22) {
            if signedIn {
                ContentUnavailableView(L("Connected", "已连接"), systemImage: "checkmark.circle", description: Text(L("Native workspace and chat UI is coming next.", "原生工作区与聊天界面将在下一步提供。")))
                Button(L("Log out", "退出")) { Task { do { try await api.logout(); signedIn = false } catch { self.error = error.localizedDescription } } }
            } else {
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
                        Button { Task { await login() } } label: {
                            HStack { Spacer(); if busy { ProgressView() }; Text(L("Continue", "继续")); Spacer() }.padding(10)
                        }.buttonStyle(.borderedProminent).tint(.primary).disabled(busy || secret.isEmpty)
                    }.padding(28).frame(maxWidth: 460)
                }.frame(maxWidth: .infinity).background(colorScheme == .dark ? Color(red: 21/255, green: 21/255, blue: 23/255) : .white)
            }
            if busy { ProgressView() }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .task { if secret.isEmpty { await resume() } }
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
