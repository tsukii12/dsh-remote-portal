import SwiftUI
import SwiftTerm

@MainActor
final class TerminalInventory: ObservableObject {
    let api: PortalAPI
    let sessionID: String
    @Published private(set) var terminals: [JSON] = []
    @Published private(set) var loaded = false
    @Published var error: String?
    @Published var creating = false
    private var watch: Task<Void, Never>?
    private var allocationID: String?
    var selectionKey: String { "drp.terminal.selection." + api.base.absoluteString + ":" + sessionID }
    init(api: PortalAPI, sessionID: String) { self.api = api; self.sessionID = sessionID }
    func start() async {
        guard watch == nil else { return }
        do {
            terminals = try await api.rpc("terminal/list", args: ["sessionId": .string(sessionID)]).array
            loaded = true; error = nil
            watch = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await value in api.stream("terminal/watch", args: ["sessionId": .string(sessionID)]) {
                        if Task.isCancelled { return }
                        if value["type"] == "connection-reset" { continue }
                        terminals = value.array
                    }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func stop() { watch?.cancel(); watch = nil }
    func create() async -> String? {
        guard !creating else { return nil }
        creating = true; defer { creating = false }
        let id = allocationID ?? UUID().uuidString; allocationID = id
        do {
            let info = try await api.rpc("terminal/create", args: ["agentId": .string(sessionID), "request": ["id": .string(id), "cols": 80, "rows": 24]])
            terminals.removeAll { $0["id"] == .string(id) }; terminals.append(info)
            allocationID = nil; error = nil; return id
        } catch { self.error = error.localizedDescription; return nil }
    }
    func close(_ id: String) async {
        do {
            _ = try await api.rpc("terminal/close", args: ["agentId": .string(sessionID), "id": .string(id)])
            terminals.removeAll { $0["id"] == .string(id) }
            if UserDefaults.standard.string(forKey: selectionKey) == id { UserDefaults.standard.removeObject(forKey: selectionKey) }
        } catch { self.error = error.localizedDescription }
    }
    func rename(_ id: String, title: String) async {
        do { _ = try await api.rpc("terminal/rename", args: ["agentId": .string(sessionID), "id": .string(id), "title": .string(title)]) }
        catch { self.error = error.localizedDescription }
    }
}

private struct TerminalListItem: Identifiable {
    let info: JSON
    var id: String { info["id"].text }
}

struct TerminalsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var inventory: TerminalInventory
    @State private var path: [String] = []
    @State private var closing: String?
    @State private var renaming: String?
    @State private var title = ""
    init(api: PortalAPI, sessionID: String) { _inventory = StateObject(wrappedValue: TerminalInventory(api: api, sessionID: sessionID)) }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Text(L("Shells run with your host account's permissions, independently of agent approvals. Dismissing this screen keeps them running.", "终端以主机账户权限运行，不受智能体审批限制。关闭此页面不会结束进程。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = inventory.error { Section { Text(error).foregroundStyle(.red); Button(L("Retry", "重试")) { Task { inventory.stop(); await inventory.start() } } } }
                if !inventory.loaded { ProgressView() }
                else if inventory.terminals.isEmpty { Text(L("No terminals in this chat", "此对话暂无终端")).foregroundStyle(.secondary) }
                ForEach(inventory.terminals.map { TerminalListItem(info: $0) }) { row in
                    let info = row.info
                    NavigationLink(value: info["id"].text) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(info["title"].text).font(.body.monospaced())
                            Text(info["cwd"].text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(info["state"] == "running" ? L("Running", "运行中") : L("Exited", "已退出")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button(L("Rename", "重命名")) { title = info["title"].text; renaming = info["id"].text }
                        Button(L("Close terminal", "结束终端"), role: .destructive) { closing = info["id"].text }
                    }
                    .swipeActions { Button(L("Close", "结束"), role: .destructive) { closing = info["id"].text } }
                }
            }
            .navigationTitle(L("Terminals", "终端"))
            .navigationDestination(for: String.self) { id in
                if let info = inventory.terminals.first(where: { $0["id"] == .string(id) }) {
                    TerminalScreen(api: inventory.api, sessionID: inventory.sessionID, info: info)
                        .onAppear { UserDefaults.standard.set(id, forKey: inventory.selectionKey) }
                } else { ContentUnavailableView(L("Terminal unavailable", "终端不可用"), systemImage: "terminal", description: Text(L("The host may have restarted or closed it. Create a new terminal explicitly.", "主机可能已重启或结束该终端。请手动新建终端。"))) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Done", "完成")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { Task { if let id = await inventory.create() { path.append(id) } } } label: { Image(systemName: "plus") }.disabled(inventory.creating).accessibilityLabel(L("New terminal", "新建终端")).accessibilityIdentifier("newTerminal") }
            }
        }
        .task {
            await inventory.start()
            if let saved = UserDefaults.standard.string(forKey: inventory.selectionKey), inventory.terminals.contains(where: { $0["id"] == .string(saved) }), path.isEmpty { path = [saved] }
        }
        .onDisappear { inventory.stop() }
        .confirmationDialog(L("End this terminal and its processes?", "结束此终端及其进程？"), isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            Button(L("Close terminal", "结束终端"), role: .destructive) { if let closing { Task { await inventory.close(closing) } }; closing = nil }
        }
        .alert(L("Rename terminal", "重命名终端"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Title", "名称"), text: $title)
            Button(L("Save", "保存")) { if let renaming { Task { await inventory.rename(renaming, title: title) } }; renaming = nil }
            Button(L("Cancel", "取消"), role: .cancel) { renaming = nil }
        }
    }
}

private struct TerminalScreen: View {
    @StateObject private var store: TerminalStore
    init(api: PortalAPI, sessionID: String, info: JSON) { _store = StateObject(wrappedValue: TerminalStore(api: api, sessionID: sessionID, info: info)) }
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error { StatusBanner(message: error) }
            if let notice = store.notice { Text(notice).font(.caption).padding(8).frame(maxWidth: .infinity).background(.orange.opacity(0.12)) }
            HStack {
                if !store.ready { ProgressView().controlSize(.mini) }
                Text(store.ready ? (store.writable ? L("Connected", "已连接") : L("Read-only / exited", "只读／已退出")) : L("Reconnecting…", "正在重连…"))
                Spacer()
                Text("\(store.info["cols"].int ?? 0) × \(store.info["rows"].int ?? 0)")
            }.font(.caption).foregroundStyle(.secondary).padding(8)
            NativeTerminalSurface(store: store)
        }
        .navigationTitle(store.info["title"].text).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { store.reconnect() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(L("Reconnect terminal", "重连终端")) } }
    }
}

final class RemoteTerminalView: SwiftTerm.TerminalView {
    var protocolReply: ((String) -> Void)?
    weak var controlButton: UIButton?
    var controlArmed = false { didSet { controlButton?.setTitle(controlArmed ? "Ctrl •" : "Ctrl", for: .normal) } }
    override func send(source: Terminal, data: ArraySlice<UInt8>) { protocolReply?(String(decoding: data, as: UTF8.self)) }
    func copyAll() { selectAll(); UIPasteboard.general.string = getSelection() ?? ""; selectNone() }
}

private struct NativeTerminalSurface: UIViewRepresentable {
    let store: TerminalStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeUIView(context: Context) -> RemoteTerminalView {
        let view = RemoteTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = .black; view.nativeForegroundColor = .white
        view.accessibilityIdentifier = "nativeTerminal"
        view.terminalDelegate = context.coordinator
        view.protocolReply = { [weak store] in store?.write($0, typed: false) }
        let scroller = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        scroller.backgroundColor = .secondarySystemBackground
        let keys = UIStackView(); keys.axis = .horizontal; keys.spacing = 6; keys.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(keys)
        NSLayoutConstraint.activate([keys.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: 8), keys.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -8), keys.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor), keys.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor), keys.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)])
        func key(_ title: String, action: @escaping () -> Void) {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
            button.addAction(UIAction { _ in action() }, for: .touchUpInside); keys.addArrangedSubview(button)
        }
        key("Esc") { [weak view] in view?.send(txt: "\u{1b}") }
        key("Tab") { [weak view] in view?.send(txt: "\t") }
        key("Ctrl") { [weak view] in view?.controlArmed.toggle() }
        view.controlButton = keys.arrangedSubviews.last as? UIButton
        for (symbol, suffix) in [("←", "D"), ("↓", "B"), ("↑", "A"), ("→", "C")] {
            key(symbol) { [weak view] in if let view { view.send(txt: "\u{1b}" + (view.getTerminal().applicationCursor ? "O" : "[") + suffix) } }
        }
        for symbol in ["|", "~", "/"] { key(symbol) { [weak view] in view?.send(txt: symbol) } }
        key("Ctrl-C") { [weak view] in view?.send(txt: "\u{3}") }
        key(L("Paste", "粘贴")) { [weak view] in view?.paste(nil) }
        key(L("Copy all", "复制全部")) { [weak view] in view?.copyAll() }
        key(L("Hide", "收起")) { [weak view] in _ = view?.resignFirstResponder() }
        view.inputAccessoryView = scroller
        store.render = { [weak view, weak store] frame in
            guard let view else { return }
            if frame["type"] == "snapshot" {
                let local = view.getTerminal().getDims()
                view.getTerminal().resetToInitialState()
                view.getTerminal().resize(cols: frame["info"]["cols"].int ?? 80, rows: frame["info"]["rows"].int ?? 24)
                view.changeScrollback(store?.environment["scrollback"].int ?? 1000)
                view.feed(text: frame["screen"].text)
                view.getTerminal().resize(cols: max(2, local.cols), rows: max(1, local.rows))
            } else { view.feed(text: frame["data"].text) }
        }
        store.start()
        return view
    }
    func updateUIView(_ uiView: RemoteTerminalView, context: Context) {}
    static func dismantleUIView(_ uiView: RemoteTerminalView, coordinator: Coordinator) { coordinator.store.stop(); coordinator.store.render = nil; uiView.terminalDelegate = nil; uiView.updateUiClosed() }
    @MainActor final class Coordinator: NSObject, TerminalViewDelegate {
        let store: TerminalStore
        init(store: TerminalStore) { self.store = store }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { store.resize(cols: newCols, rows: newRows) }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            var text = String(decoding: data, as: UTF8.self)
            if let source = source as? RemoteTerminalView, source.controlArmed {
                source.controlArmed = false
                if let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1, (64...127).contains(scalar.value) { text = String(UnicodeScalar(scalar.value & 31)!) }
            }
            store.write(text)
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
