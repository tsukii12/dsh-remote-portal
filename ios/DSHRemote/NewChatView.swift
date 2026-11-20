import SwiftUI

@MainActor
final class NewChatDraft: ObservableObject {
    let chat: ChatStore
    let attachments: AttachmentsStore
    private let sidebar: SidebarStore
    @Published var workspaceID: String?
    @Published private(set) var sending = false
    @Published var error: String?
    private(set) var sessionID: String?
    private var submitted = false
    private var configured = false
    private var requestID = UUID().uuidString
    private var signature: String?
    init(api: RPCServing, sidebar: SidebarStore, workspaceID: String?) {
        chat = ChatStore(sessionID: "", api: api, isDraft: true)
        attachments = AttachmentsStore(api: api, sessionID: "", deferred: true)
        self.sidebar = sidebar; self.workspaceID = workspaceID
    }
    func load() async {
        do { try await chat.loadModels(); try await chat.loadControls() }
        catch { self.error = error.localizedDescription }
    }
    func submit(_ text: String) async throws -> String {
        guard !sending else { throw PortalError.message(L("A message is already being sent.", "消息正在发送中。")) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items.isEmpty else { throw PortalError.message(L("Enter a message.", "请输入消息。")) }
        try chat.validateImageInput(attachments.items)
        let signature = text + "\u{0}" + attachments.items.map { $0.id.uuidString }.joined(separator: ",")
        if signature != self.signature { requestID = UUID().uuidString; self.signature = signature }
        sending = true; error = nil
        defer { sending = false }
        if sessionID == nil { sessionID = try await sidebar.createSession(workspaceID: workspaceID) }
        guard let id = sessionID else { throw APIError.invalidResponse }
        let target = ChatStore(sessionID: id, api: chat.api)
        if !configured, let preset = chat.projections["agentPreset"].string { try await target.selectPreset(preset) }
        else { try await target.loadControls() }
        try await target.loadModels()
        let model = chat.currentModel
        if !configured, let provider = model["provider"].string, let modelID = model["model"].string {
            try await target.selectModel(provider: provider, model: modelID, reasoningEffort: model["reasoningEffort"].string)
        }
        if !configured, let access = chat.projections["permissions"]["currentValue"].string { try await target.selectPermission(access) }
        if !configured, chat.planEnabled {
            guard target.supportsPlan else { throw PortalError.message(L("This preset does not provide Plan mode. Choose another preset or turn Plan mode off.", "当前预设不支持计划模式，请选择其他预设或关闭计划模式。")) }
            _ = try await target.executeCommand("/plan")
        }
        configured = true
        try target.validateImageInput(attachments.items)
        try await attachments.prepare(sessionID: id, limits: target.projections["imageLimits"])
        if text.hasPrefix("/") {
            let parts: [JSON] = try attachments.items.map { item in
                ["type": item.mediaType == nil ? "file" : "image", "mediaType": .string(item.mediaType ?? "application/octet-stream"), "name": .string(item.name), "data": .string(try Data(contentsOf: item.file).base64EncodedString())]
            }
            _ = try await target.executeCommand(text, attachments: parts)
        } else { try await target.send(text, attachments: attachments.items, requestID: requestID) }
        submitted = true
        return id
    }
    func abandon() async { if !sending && !submitted, let sessionID { try? await sidebar.abandonEmptyCreated(sessionID) } }
}

struct NewChatView: View {
    @StateObject private var draft: NewChatDraft
    @ObservedObject var sidebar: SidebarStore
    let serverName: String
    let base: URL
    let onMenu: () -> Void
    let onOpen: (String) -> Void
    init(api: RPCServing, sidebar: SidebarStore, workspaceID: String?, serverName: String, base: URL, onMenu: @escaping () -> Void, onOpen: @escaping (String) -> Void) {
        _draft = StateObject(wrappedValue: NewChatDraft(api: api, sidebar: sidebar, workspaceID: workspaceID))
        self.sidebar = sidebar; self.serverName = serverName; self.base = base; self.onMenu = onMenu; self.onOpen = onOpen
    }
    var body: some View { NewChatDraftView(draft: draft, sidebar: sidebar, serverName: serverName, base: base, onMenu: onMenu, onOpen: onOpen) }
}

private struct NewChatDraftView: View {
    @ObservedObject private var draft: NewChatDraft
    @ObservedObject private var chat: ChatStore
    @ObservedObject private var attachments: AttachmentsStore
    @ObservedObject private var sidebar: SidebarStore
    let serverName: String
    let base: URL
    let onMenu: () -> Void
    let onOpen: (String) -> Void
    @State private var text = ""
    @State private var options: ChatOptionsPage?
    @State private var usage = false
    @FocusState private var focused: Bool
    init(draft: NewChatDraft, sidebar: SidebarStore, serverName: String, base: URL, onMenu: @escaping () -> Void, onOpen: @escaping (String) -> Void) {
        self.draft = draft; _chat = ObservedObject(wrappedValue: draft.chat); _attachments = ObservedObject(wrappedValue: draft.attachments); self.sidebar = sidebar
        self.serverName = serverName; self.base = base; self.onMenu = onMenu; self.onOpen = onOpen
    }
    private var workspace: String { sidebar.workspaces.first { $0.id == draft.workspaceID }?.title ?? L("Default workspace", "默认工作区") }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(ChatGreeting.text(hour: Calendar.current.component(.hour, from: Date()))).font(.largeTitle.weight(.light))
                Text(L("What would you like to do today?", "今天想做点什么？")).font(.title3).foregroundStyle(.secondary)
                Menu {
                    ForEach(sidebar.workspaces) { row in Button(row.title) { draft.workspaceID = row.id } }
                } label: { Label(L("In “\(workspace)”", "在「\(workspace)」中") + " ⌄", systemImage: "folder").padding(.horizontal, 16).frame(minHeight: 44).background(.secondary.opacity(0.06), in: Capsule()) }.disabled(draft.sessionID != nil)
                HStack(spacing: 20) {
                    Button { options = .mode } label: { Label((chat.projections["agentPreset"].string.map(ChatLabels.preset) ?? L("Default mode", "默认模式")) + " ⌄", systemImage: "wrench") }
                    Button { options = .access } label: { Label((chat.projections["permissions"]["currentValue"].string.map(ChatLabels.permission) ?? L("Access", "权限")) + " ⌄", systemImage: "shield") }
                }.font(.subheadline).frame(minHeight: 44)
                if let error = draft.error { StatusBanner(message: error, dismiss: { draft.error = nil }); Button(L("Reload options", "重新加载选项")) { Task { await draft.load() } }.frame(minHeight: 44) }
            }.frame(maxWidth: .infinity).padding(.horizontal, 20).containerRelativeFrame(.vertical) { height, _ in max(220, height * 0.8) }
        }.background { ChatBackdrop() }.toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    GlassCircle(symbol: "line.3.horizontal", label: L("Conversations", "对话列表"), action: onMenu)
                    ChatTitlePill(title: L("New chat", "新对话"), subtitle: serverName + " · " + PortalRoute.label(base))
                    Button { options = .model } label: { Text(chat.modelName + " · " + ChatLabels.preset(chat.projections["agentPreset"].text) + " ⌄").font(.caption).lineLimit(1).padding(.horizontal, 12).frame(maxWidth: 145, minHeight: 44).background(.regularMaterial, in: Capsule()) }.accessibilityLabel(L("Choose model", "选择模型")).accessibilityValue(chat.modelName + " · " + ChatLabels.preset(chat.projections["agentPreset"].text))
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    PixelWhale().padding(.leading, 50)
                    GlassComposer(chat: chat, attachments: attachments, text: $text, focused: $focused, sending: draft.sending, canSend: !draft.sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items.isEmpty), onSend: send, onError: { draft.error = $0 }, onModel: { options = .model }, onMode: { options = .mode }, onUsage: { usage = true })
                }.padding(.horizontal, 12).padding(.bottom, 12).frame(maxWidth: 800).frame(maxWidth: .infinity)
            }
            .sheet(item: $options) { ChatOptionsView(chat: chat, page: $0) }
            .sheet(isPresented: $usage) { NavigationStack { Form { UsageView(usage: [:], pressure: [:]); Text(L("Usage appears after the first request.", "首次请求后显示用量。")) }.navigationTitle(L("Usage", "用量")) } }
            .task { await draft.load() }
            .onDisappear { Task { await draft.abandon() } }
    }
    private func send() {
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/model" { text = ""; options = .model; return }
        let message = text
        Task {
            do { let id = try await draft.submit(message); text = ""; attachments.clear(); onOpen(id) }
            catch { draft.error = error.localizedDescription; focused = true }
        }
    }
}
