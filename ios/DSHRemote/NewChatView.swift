import SwiftUI

@MainActor
final class NewChatDraft: ObservableObject {
    let chat: ChatStore
    let attachments: AttachmentsStore
    private let sidebar: SidebarStore
    private let events: RemoteEvents?
    @Published var workspaceID: String?
    @Published private(set) var sending = false
    @Published private(set) var pendingText = ""
    @Published var error: String?
    private(set) var sessionID: String?
    private var submitted = false
    private var requestID = UUID().uuidString
    private var signature: String?
    init(api: RPCServing, sidebar: SidebarStore, workspaceID: String?, events: RemoteEvents? = nil) {
        chat = ChatStore(sessionID: "", api: api, isDraft: true)
        attachments = AttachmentsStore(api: api, sessionID: "", deferred: true)
        self.sidebar = sidebar; self.workspaceID = workspaceID; self.events = events
    }
    func load() async {
        do {
            async let models: Void = chat.loadModels()
            async let controls: Void = chat.loadControls()
            _ = try await (models, controls)
        }
        catch { self.error = error.localizedDescription }
    }
    func submit(_ text: String) async throws -> ChatStore {
        guard !sending else { throw PortalError.message(L("A message is already being sent.", "消息正在发送中。")) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items.isEmpty else { throw PortalError.message(L("Enter a message.", "请输入消息。")) }
        try chat.validateImageInput(attachments.items)
        let signature = text + "\u{0}" + attachments.items.map { $0.id.uuidString }.joined(separator: ",")
        if signature != self.signature { requestID = UUID().uuidString; self.signature = signature }
        pendingText = text; sending = true; error = nil
        defer { sending = false }
        if sessionID == nil { sessionID = try await sidebar.createSession(workspaceID: workspaceID, refreshImmediately: false) }
        guard let id = sessionID else { throw APIError.invalidResponse }
        let target = ChatStore(sessionID: id, api: chat.api, events: events)
        var accepted = false
        defer { if !accepted { target.stop() } }
        async let stream: Void = target.start()
        async let controls: Void = target.loadControls()
        async let models: Void = target.loadModels()
        _ = try await (stream, controls, models)
        try await target.waitForHistory()
        if let preset = chat.projections["agentPreset"].string, target.projections["agentPreset"].string != preset { try await target.selectPreset(preset) }
        let model = chat.currentModel
        if let provider = model["provider"].string, let modelID = model["model"].string,
           model["provider"] != target.currentModel["provider"] || model["model"] != target.currentModel["model"] || model["reasoningEffort"] != target.currentModel["reasoningEffort"] {
            try await target.selectModel(provider: provider, model: modelID, reasoningEffort: model["reasoningEffort"].string)
        }
        if let access = chat.projections["permissions"]["currentValue"].string, .string(access) != target.projections["permissions"]["currentValue"] { try await target.selectPermission(access) }
        if chat.planEnabled != target.planEnabled {
            guard target.supportsPlan else { throw PortalError.message(L("This preset does not provide Plan mode. Choose another preset or turn Plan mode off.", "当前预设不支持计划模式，请选择其他预设或关闭计划模式。")) }
            _ = try await target.executeCommand(chat.planEnabled ? "/plan" : "/plan off")
        }
        if !text.hasPrefix("/") { target.addOptimistic(text: text, requestID: requestID, attachments: attachments.items.map(\.reference)) }
        try target.validateImageInput(attachments.items)
        try await attachments.prepare(sessionID: id, limits: target.projections["imageLimits"])
        if text.hasPrefix("/") {
            let parts: [JSON] = try attachments.items.map { item in
                ["type": item.mediaType == nil ? "file" : "image", "mediaType": .string(item.mediaType ?? "application/octet-stream"), "name": .string(item.name), "data": .string(try Data(contentsOf: item.file).base64EncodedString())]
            }
            _ = try await target.executeCommand(text, attachments: parts)
        } else { try await target.send(text, attachments: attachments.items, requestID: requestID) }
        submitted = true; accepted = true
        return target
    }
    func abandon() async { if !sending && !submitted, let sessionID { try? await sidebar.abandonEmptyCreated(sessionID) } }
}

struct NewChatView: View {
    @StateObject private var draft: NewChatDraft
    @ObservedObject var sidebar: SidebarStore
    let serverName: String
    let base: URL
    let onOpen: (ChatStore) -> Void
    init(api: RPCServing, sidebar: SidebarStore, workspaceID: String?, serverName: String, base: URL, events: RemoteEvents? = nil, onOpen: @escaping (ChatStore) -> Void) {
        _draft = StateObject(wrappedValue: NewChatDraft(api: api, sidebar: sidebar, workspaceID: workspaceID, events: events))
        self.sidebar = sidebar; self.serverName = serverName; self.base = base; self.onOpen = onOpen
    }
    var body: some View { NewChatDraftView(draft: draft, sidebar: sidebar, serverName: serverName, base: base, onOpen: onOpen) }
}

private struct NewChatDraftView: View {
    @ObservedObject private var draft: NewChatDraft
    @ObservedObject private var chat: ChatStore
    @ObservedObject private var attachments: AttachmentsStore
    @ObservedObject private var sidebar: SidebarStore
    let serverName: String
    let base: URL
    let onOpen: (ChatStore) -> Void
    @State private var text = ""
    @State private var options: ChatOptionsPage?
    @State private var usage = false
    @FocusState private var focused: Bool
    init(draft: NewChatDraft, sidebar: SidebarStore, serverName: String, base: URL, onOpen: @escaping (ChatStore) -> Void) {
        self.draft = draft; _chat = ObservedObject(wrappedValue: draft.chat); _attachments = ObservedObject(wrappedValue: draft.attachments); self.sidebar = sidebar
        self.serverName = serverName; self.base = base; self.onOpen = onOpen
    }
    var body: some View {
        Form {
            if draft.sending {
                Section { Text(draft.pendingText).textSelection(.enabled) }
                Section { ProgressView(L("Running…", "运行中…")) }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ChatGreeting.text(hour: Calendar.current.component(.hour, from: Date()))).font(.title2.bold())
                        Text(L("What would you like to do today?", "今天想做点什么？")).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section(L("Conversation options", "对话选项")) {
                    Picker(L("Workspace", "工作区"), selection: $draft.workspaceID) {
                        Text(L("Default workspace", "默认工作区")).tag(Optional<String>.none)
                        ForEach(sidebar.workspaces) { row in Text(row.title).tag(Optional(row.id)) }
                    }.disabled(draft.sessionID != nil)
                    Button { options = .model } label: { LabeledContent(L("Model", "模型"), value: chat.modelName) }
                    Button { options = .mode } label: { LabeledContent(L("Mode", "模式"), value: ChatLabels.preset(chat.projections["agentPreset"].text)) }
                    Button { options = .access } label: { LabeledContent(L("Access", "权限"), value: ChatLabels.permission(chat.projections["permissions"]["currentValue"].text)) }
                }
            }
            if let error = draft.error {
                Section {
                    StatusBanner(message: error, dismiss: { draft.error = nil })
                    Button(L("Reload options", "重新加载选项")) { Task { await draft.load() } }
                }
            }
        }
        .navigationTitle(L("New chat", "新对话")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ChatNavigationTitle(title: L("New chat", "新对话"), subtitle: serverName + " · " + PortalRoute.label(base)) }
        }
        .safeAreaInset(edge: .bottom) {
            ChatComposer(chat: chat, attachments: attachments, text: $text, focused: $focused, sending: draft.sending, canSend: !draft.sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items.isEmpty), onSend: send, onError: { draft.error = $0 }, onModel: { options = .model }, onMode: { options = .mode }, onUsage: { usage = true })
                .frame(maxWidth: 800).frame(maxWidth: .infinity).background(Color(uiColor: .systemBackground)).overlay(alignment: .top) { Divider() }
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
