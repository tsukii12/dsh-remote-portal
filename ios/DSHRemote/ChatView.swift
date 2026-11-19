import SwiftUI

private struct BottomPosition: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatView: View {
    @ObservedObject private var chat: ChatStore
    @StateObject private var attachments: AttachmentsStore
    @StateObject private var mentions: FileMentions
    let title: String
    @State private var draft = ""
    @State private var sending = false
    @State private var followingBottom = true
    @State private var loadingOlder = false
    @State private var actionError: String?
    @State private var dismissedError: String?
    @State private var showingOptions = false
    @State private var showingFiles = false
    @State private var editingQueue: String?
    @State private var queuedText = ""
    @State private var steer = false
    @FocusState private var composerFocused: Bool
    init(chat: ChatStore, title: String) {
        self.chat = chat; self.title = title
        _attachments = StateObject(wrappedValue: AttachmentsStore(api: chat.api, sessionID: chat.sessionID))
        _mentions = StateObject(wrappedValue: FileMentions(api: chat.api, sessionID: chat.sessionID))
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = actionError ?? chat.error, error != dismissedError { StatusBanner(message: error, dismiss: { dismissedError = error; actionError = nil }) }
            transcript
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("DRP").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { VStack(spacing: 2) { Text("DRP").font(.headline); Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1) } } }
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { showingFiles = true } label: { Image(systemName: "folder") }.accessibilityLabel(L("Workspace files", "工作区文件")).accessibilityIdentifier("workspaceFiles") } }
        .sheet(isPresented: $showingOptions) { ChatOptionsView(chat: chat) }
        .sheet(isPresented: $showingFiles) { WorkspaceFilesView(api: chat.api, sessionID: chat.sessionID) }
        .task(id: draft) { await mentions.load(draft) }
        .alert(L("Edit queued message", "编辑排队消息"), isPresented: Binding(get: { editingQueue != nil }, set: { if !$0 { editingQueue = nil } })) {
            TextField(L("Message", "消息"), text: $queuedText)
            Button(L("Cancel", "取消"), role: .cancel) { editingQueue = nil }
            Button(L("Save", "保存")) {
                if let id = editingQueue { let text = queuedText; perform { try await chat.updateQueue(id, kind: "edit", text: text) } }
                editingQueue = nil
            }.disabled(queuedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if chat.hasMore {
                            Button {
                                let anchor = chat.transcript.first?.id
                                followingBottom = false; loadingOlder = true
                                Task {
                                    do { try await chat.loadOlder(); if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
                                    catch { actionError = error.localizedDescription }
                                    loadingOlder = false
                                }
                            } label: { HStack { Spacer(); if loadingOlder { ProgressView() }; Text(L("Load earlier messages", "加载更早的消息")); Spacer() }.font(.caption) }.disabled(loadingOlder)
                        }
                        if chat.transcript.isEmpty && chat.inProgress == nil {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkle").font(.system(size: 36)).foregroundStyle(DRPStyle.accent)
                                Text(L("What can we work on?", "今天一起做点什么？")).font(.title2.weight(.semibold))
                                Text(L("Send a message to start this conversation.", "发送消息，开始这段对话。")).font(.subheadline).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 80)
                        }
                        ForEach(chat.transcript) { item in MessageView(item: item, api: chat.api, sessionID: chat.sessionID, usage: chat.usage(for: item)).id(item.id) }
                        if let message = chat.inProgress { MessageView(item: message, api: chat.api, sessionID: chat.sessionID).id(message.id) }
                        Color.clear.frame(height: 1)
                            .background(GeometryReader { geometry in Color.clear.preference(key: BottomPosition.self, value: geometry.frame(in: .named("chatScroll")).maxY) })
                            .id("bottom")
                    }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "chatScroll")
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture().onChanged { _ in followingBottom = false })
                .onPreferenceChange(BottomPosition.self) { bottom in if bottom < viewport.size.height + 60 && !loadingOlder { followingBottom = true } }
                .onChange(of: chat.transcript) { _, _ in if followingBottom && !loadingOlder { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chat.inProgress) { _, _ in if followingBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: composerFocused) { _, focused in if focused && followingBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                .overlay(alignment: .bottomTrailing) {
                    if !followingBottom {
                        Button { followingBottom = true; withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: { Image(systemName: "arrow.down").padding(12).background(.regularMaterial, in: Circle()).shadow(radius: 2) }
                            .accessibilityLabel(L("Jump to latest", "回到最新消息")).padding()
                    }
                }
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if !chat.queue.isEmpty { queueDock }
            if let notice = chat.commandNotice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            if let file = chat.exportedFile { ShareLink(item: file) { Label(L("Share session log", "分享会话日志"), systemImage: "square.and.arrow.up") }.font(.caption) }
            if draft.hasPrefix("/") { commandSuggestions }
            if FileMentionToken.active(in: draft) != nil { mentionSuggestions }
            ComposerAttachmentsView(store: attachments, limits: chat.projections["imageLimits"], disabled: sending || !chat.loaded, onError: { actionError = $0; dismissedError = nil })
            UsageView(usage: chat.projections["tokenUsage"], pressure: chat.projections["contextPressure"])
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { showingOptions = true } label: {
                        Label(L("Model: ", "模型：") + chat.modelName + " · " + chat.effortName, systemImage: "cpu")
                    }.accessibilityIdentifier("modelOptions")
                    Button { showingOptions = true } label: { Label(ChatLabels.permission(chat.projections["permissions"]["currentValue"].text), systemImage: "lock.shield") }
                    Button { showingOptions = true } label: { Text(chat.planEnabled ? L("Plan mode", "计划模式") : ChatLabels.preset(chat.projections["agentPreset"].string ?? "standard")) }
                }.font(.caption.weight(.medium)).buttonStyle(.bordered).tint(DRPStyle.accent)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField(L("Message DRP…", "发送消息给 DRP…"), text: $draft, axis: .vertical)
                    .lineLimit(1...6).focused($composerFocused).padding(.vertical, 12).padding(.leading, 14)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("chatComposer")
                if chat.running {
                    Button { perform { try await chat.cancel() } } label: { Image(systemName: "stop.fill").padding(8) }.accessibilityLabel(L("Stop", "停止"))
                }
                Button {
                    send()
                } label: {
                    Image(systemName: chat.running ? (steer ? "bolt.fill" : "text.badge.plus") : "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(canSend ? DRPStyle.accent : Color.gray.opacity(0.4), in: Circle())
                }
                .disabled(!canSend).padding(6)
                .accessibilityLabel(chat.running ? (steer ? L("Steer", "立即引导") : L("Queue message", "消息排队")) : L("Send", "发送")).accessibilityIdentifier("sendMessage")
            }.background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 22))
            if chat.running { Toggle(L("Steer immediately instead of queue", "立即引导而不是排队"), isOn: $steer).font(.caption) }
        }
        .padding(.horizontal, 16).padding(.bottom, 10).frame(maxWidth: 800).frame(maxWidth: .infinity).background(.bar)
    }
    private var canSend: Bool { !sending && attachments.ready && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items.isEmpty) }
    private var mentionSuggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if mentions.loading { ProgressView() }
                if let error = mentions.error { Text(error).foregroundStyle(.red) }
                ForEach(Array(mentions.candidates.enumerated()), id: \.offset) { _, candidate in
                    Button {
                        if let token = FileMentionToken.active(in: draft), let text = token.inserting(candidate, into: draft) { draft = text; composerFocused = true }
                    } label: { Label(candidate["path"].text, systemImage: candidate["kind"] == "directory" ? "folder" : "doc").frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                }
                if !mentions.loading && mentions.error == nil && mentions.candidates.isEmpty { Text(L("No matching workspace files", "没有匹配的工作区文件")).foregroundStyle(.secondary) }
            }.font(.caption).padding(8)
        }.frame(height: min(140, CGFloat(max(1, mentions.candidates.count)) * 44 + 8))
    }
    private var commandSuggestions: some View {
        let query = draft.dropFirst().split(separator: " ", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let suggestions = ([JSON.object(["name": "model", "description": .string(L("Choose model and thinking effort", "选择模型与思考强度"))])] + chat.commands).filter { query.isEmpty || $0["name"].text.hasPrefix(query) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, command in
                    Button {
                        if command["name"] == "model" { draft = ""; showingOptions = true }
                        else { draft = "/" + command["name"].text + (command["input"] == .null ? "" : " "); composerFocused = true }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("/" + command["name"].text + " " + command["input"]["hint"].text).font(.caption.weight(.semibold))
                            Text(command["description"].text).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
                if suggestions.isEmpty { Text(L("No matching commands", "没有匹配的命令")).font(.caption) }
            }.padding(8)
        }.frame(maxHeight: 150)
    }
    private var queueDock: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Queued messages", "排队消息")).font(.caption.weight(.semibold))
                ForEach(Array(chat.queue.enumerated()), id: \.offset) { _, item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item["placement"] == "steering" ? L("Steering", "引导中") : L("Queued", "排队中")).font(.caption2).foregroundStyle(.secondary)
                            Text(item["content"].array.map { $0["text"].text }.joined(separator: "\n")).font(.caption).lineLimit(2)
                        }
                        Spacer()
                        Menu {
                            Button(L("Edit", "编辑")) { queuedText = item["content"].array.map { $0["text"].text }.joined(separator: "\n"); editingQueue = item["id"].text }
                                .disabled(item["content"].array.contains { $0["type"] != "text" })
                            Button(L("Steer now", "立即引导")) { perform { try await chat.updateQueue(item["id"].text, kind: "steer") } }
                            Button(L("Remove", "移除"), role: .destructive) { perform { try await chat.updateQueue(item["id"].text, kind: "remove") } }
                        } label: { Image(systemName: "ellipsis.circle").padding(6) }.accessibilityLabel(L("Queued message actions", "排队消息操作"))
                    }.padding(8).background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.frame(maxHeight: 140)
    }
    private func send() {
        guard canSend else { return }
        let text = draft; let steerNow = steer; draft = ""; sending = true; followingBottom = true; composerFocused = false
        Task {
            do {
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/model" { showingOptions = true }
                else if text.hasPrefix("/") {
                    let parts: [JSON] = try attachments.items.map { item in
                        if let type = item.mediaType { return ["type": "image", "mediaType": .string(type), "data": .string(try Data(contentsOf: item.file).base64EncodedString()), "name": .string(item.name)] }
                        return item.content
                    }
                    try await chat.executeCommand(text, attachments: parts)
                    attachments.clear()
                }
                else { try await chat.send(text, steer: steerNow, attachments: attachments.items); attachments.clear() }
            }
            catch { actionError = error.localizedDescription; if draft.isEmpty { draft = text } }
            sending = false
        }
    }
    private func perform(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { actionError = error.localizedDescription; dismissedError = nil } } }
}

private struct MessageView: View {
    let item: TranscriptItem
    let api: RPCServing
    let sessionID: String
    var usage: JSON?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.role == "user" {
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            if block.kind == "image" || block.kind == "file" { HistoricalAttachmentView(block: block, api: api, sessionID: sessionID) }
                        }
                        if !item.text.isEmpty {
                            Text(item.text).textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 12)
                                .background(DRPStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                        }
                        if let error = item.deliveryError { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
                        else if item.optimistic { Text(L("Sending…", "正在发送…")).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            } else {
                HStack(spacing: 6) { Image(systemName: "sparkle").foregroundStyle(DRPStyle.accent); Text("DRP").font(.caption.weight(.semibold)); if item.inProgress { ProgressView().controlSize(.mini) } }
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                    switch block.kind {
                    case "text": MarkdownView(text: block.text).textSelection(.enabled)
                    case "reasoning": ThinkingView(text: block.text)
                    case "tool-call": ToolCard(block: block)
                    case "image", "file": HistoricalAttachmentView(block: block, api: api, sessionID: sessionID)
                    default: EmptyView()
                    }
                }
                if let usage { TurnUsageView(usage: usage) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThinkingView: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: { Label(L("Thinking", "思考过程"), systemImage: "sparkles").font(.caption).foregroundStyle(Color.secondary) }
    }
}
