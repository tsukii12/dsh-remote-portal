import SwiftUI

private struct ChatContentFrame: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

enum ChatScrollFollowing {
    static func update(previous: CGRect?, current: CGRect, viewportHeight: CGFloat, following: Bool, loadingOlder: Bool) -> (following: Bool, scroll: Bool) {
        guard !current.isNull, current.height.isFinite, current.minY.isFinite, !loadingOlder else { return (following, false) }
        if let previous, !previous.isNull, abs(current.height - previous.height) < 0.5 {
            return (current.maxY <= viewportHeight + 60, false)
        }
        return (following, following)
    }
}

struct ChatView: View {
    @ObservedObject private var chat: ChatStore
    @StateObject private var attachments: AttachmentsStore
    @StateObject private var mentions: FileMentions
    let title: String
    let serverName: String
    let workspaceName: String
    let agents: [SessionRow]
    let onNew: () -> Void
    let onAgent: (String) -> Void
    let focusOnOpen: Bool
    @State private var draft = ""
    @State private var sending = false
    @State private var followingBottom = true
    @State private var previousContentFrame: CGRect?
    @State private var loadingOlder = false
    @State private var actionError: String?
    @State private var dismissedError: String?
    @State private var optionsPage: ChatOptionsPage?
    @State private var showingFiles = false
    @State private var showingTerminals = false
    @State private var showingUsage = false
    @State private var editingQueue: String?
    @State private var queuedText = ""
    @ScaledMetric(relativeTo: .caption) private var queueRowHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .caption) private var queueHeaderHeight: CGFloat = 26
    @State private var steer = false
    @State private var sendFeedback = 0
    @FocusState private var composerFocused: Bool
    init(chat: ChatStore, title: String, serverName: String = "", workspaceName: String = "", agents: [SessionRow] = [], focusOnOpen: Bool = false, onNew: @escaping () -> Void = {}, onAgent: @escaping (String) -> Void = { _ in }) {
        self.chat = chat; self.title = title; self.serverName = serverName
        self.workspaceName = workspaceName; self.agents = agents; self.focusOnOpen = focusOnOpen; self.onNew = onNew; self.onAgent = onAgent
        _attachments = StateObject(wrappedValue: AttachmentsStore(api: chat.api, sessionID: chat.sessionID))
        _mentions = StateObject(wrappedValue: FileMentions(api: chat.api, sessionID: chat.sessionID))
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = actionError ?? chat.error, error != dismissedError { StatusBanner(message: error, dismiss: { dismissedError = error; actionError = nil }) }
            transcript
        }
        .background(Color(uiColor: .systemBackground))
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedback)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { header }
        .sheet(item: $optionsPage) { page in ChatOptionsView(chat: chat, page: page) }
        .sheet(isPresented: $showingFiles) {
            WorkspaceFilesView(api: chat.api, sessionID: chat.sessionID) { path in
                guard let text = FileMentionToken.insertingFile(path, into: draft) else { return }
                draft = text; showingFiles = false; composerFocused = true
            }
        }
        .sheet(isPresented: $showingTerminals) { if let api = chat.api as? PortalAPI { TerminalsView(api: api, sessionID: chat.sessionID) } }
        .sheet(isPresented: $showingUsage) { NavigationStack { Form { UsageView(usage: chat.projections["tokenUsage"], pressure: chat.projections["contextPressure"]) }.navigationTitle(L("Usage", "用量")) } }
        .onAppear { if focusOnOpen { composerFocused = true } }
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
    @ToolbarContentBuilder private var header: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ChatNavigationTitle(title: title, subtitle: [serverName.isEmpty ? nil : serverName, (chat.api as? PortalAPI).map { PortalRoute.label($0.base) }, workspaceName.isEmpty ? nil : workspaceName].compactMap { $0 }.joined(separator: " · "))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Section(L("Agents", "代理")) {
                    if agents.isEmpty { Text(L("No subagents", "暂无子代理")) }
                    ForEach(agents) { agent in Button(agent.title) { onAgent(agent.id) } }
                }
                Section(L("Conversation tools", "对话工具")) {
                    Button { showingFiles = true } label: { Label(L("Workspace files", "工作区文件"), systemImage: "folder") }
                    if chat.api is PortalAPI { Button { showingTerminals = true } label: { Label(L("Terminals", "终端"), systemImage: "terminal") } }
                    Button(L("Model & thinking", "模型与思考")) { optionsPage = .model }
                    Button(L("Access mode", "访问模式")) { optionsPage = .access }
                    Button(L("Mode & preset", "模式与预设")) { optionsPage = .mode }
                    Button(L("Usage", "用量")) { showingUsage = true }
                }
            } label: { Label(L("Agents & tools", "代理与工具"), systemImage: "ellipsis") }
            Button(action: onNew) { Label(L("New chat", "新对话"), systemImage: "square.and.pencil") }
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
                        if !chat.loaded && chat.transcript.isEmpty {
                            ProgressView(L("Loading conversation…", "正在加载对话…")).frame(maxWidth: .infinity).padding(.vertical, 60)
                        } else if chat.transcript.isEmpty && chat.inProgress == nil {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkle").font(.system(size: 36)).foregroundStyle(DRPStyle.accent)
                                Text(L("What can we work on?", "今天想做些什么？")).font(.title2.weight(.semibold))
                                Text(L("Send a message to start this conversation.", "发送消息，开始这段对话。")).font(.subheadline).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 80)
                        }
                        ForEach(TranscriptTurn.group(chat.transcript)) { turn in TurnView(turn: turn, chat: chat).id(turn.id) }
                        if let message = chat.inProgress, message.blocks.contains(where: ChatTranscriptProjection.visible) { MessageView(item: message, api: chat.api, sessionID: chat.sessionID).id(message.id) }
                        Color.clear.frame(height: 1)
                            .id("bottom")
                    }.padding(.horizontal, 16).padding(.vertical, 20).frame(maxWidth: 900).frame(maxWidth: .infinity)
                        .background(GeometryReader { geometry in Color.clear.preference(key: ChatContentFrame.self, value: geometry.frame(in: .named("chatScroll"))) })
                }
                .coordinateSpace(name: "chatScroll")
                .environment(\.attachmentViewportHeight, viewport.size.height)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture().onChanged { _ in followingBottom = false })
                .onPreferenceChange(ChatContentFrame.self) { frame in
                    let update = ChatScrollFollowing.update(previous: previousContentFrame, current: frame, viewportHeight: viewport.size.height, following: followingBottom, loadingOlder: loadingOlder)
                    previousContentFrame = frame; followingBottom = update.following
                    if update.scroll { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: viewport.size.height) { _, _ in if followingBottom && !loadingOlder { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chat.transcript) { _, _ in if followingBottom && !loadingOlder { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chat.inProgress) { _, _ in if followingBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: composerFocused) { _, focused in if focused && followingBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                .safeAreaInset(edge: .bottom) {
                    if !followingBottom {
                        Button { followingBottom = true; withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: { Label(L("Jump to latest", "回到最新消息"), systemImage: "arrow.down").frame(minHeight: 44) }
                            .frame(maxWidth: .infinity).background(Color(uiColor: .systemBackground))
                    }
                }
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.queue.isEmpty { queueDock }
            if let notice = chat.visibleCommandNotice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            if let file = chat.exportedFile { ShareLink(item: file) { Label(L("Share session log", "分享会话日志"), systemImage: "square.and.arrow.up") }.font(.caption) }
            if draft.hasPrefix("/") { commandSuggestions }
            if FileMentionToken.active(in: draft) != nil { mentionSuggestions }
            ChatComposer(chat: chat, attachments: attachments, text: $draft, focused: $composerFocused, sending: sending, canSend: canSend, onSend: send, onError: { actionError = $0; dismissedError = nil }, onModel: { optionsPage = .model }, onMode: { optionsPage = .mode }, onUsage: { showingUsage = true }, onCancel: { perform { try await chat.cancel() } }, onAccess: { optionsPage = .access }, steering: $steer)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 800).frame(maxWidth: .infinity).background(Color(uiColor: .systemBackground)).overlay(alignment: .top) { Divider() }
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
                    } label: { Label(candidate["displayTitle"].string ?? candidate["label"].string ?? candidate["path"].text, systemImage: candidate["mention"].string != nil ? "bubble.left" : candidate["kind"] == "directory" ? "folder" : "doc").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                }
                if !mentions.loading && mentions.error == nil && mentions.candidates.isEmpty { Text(L("No matching files or sessions", "没有匹配的文件或会话")).foregroundStyle(.secondary) }
            }.font(.caption).padding(8)
        }.frame(height: min(160, CGFloat(max(1, mentions.candidates.count)) * 52 + 8))
    }
    private var commandSuggestions: some View {
        let query = draft.dropFirst().split(separator: " ", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let suggestions = ([JSON.object(["name": "model", "description": .string(L("Choose model and thinking effort", "选择模型与思考强度"))])] + chat.commands).filter { query.isEmpty || $0["name"].text.hasPrefix(query) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, command in
                    Button {
                        if command["name"] == "model" { draft = ""; optionsPage = .model }
                        else { draft = "/" + command["name"].text + (command["input"] == .null ? "" : " "); composerFocused = true }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("/" + command["name"].text + " " + command["input"]["hint"].text).font(.caption.weight(.semibold))
                            Text(command["description"].text).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item["placement"] == "steering" ? L("Steering", "引导中") : L("Queued", "排队中")).font(.caption2).foregroundStyle(.secondary)
                            Text(item["content"].array.map { $0["text"].text }.joined(separator: "\n")).font(.caption).lineLimit(2, reservesSpace: true)
                        }
                        Spacer()
                        Menu {
                            Button(L("Edit", "编辑")) { queuedText = item["content"].array.map { $0["text"].text }.joined(separator: "\n"); editingQueue = item["id"].text }
                                .disabled(item["content"].array.contains { $0["type"] != "text" })
                            Button(L("Steer now", "立即引导")) { perform { try await chat.updateQueue(item["id"].text, kind: "steer") } }
                            Button(L("Remove", "移除"), role: .destructive) { perform { try await chat.updateQueue(item["id"].text, kind: "remove") } }
                        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel(L("Queued message actions", "排队消息操作"))
                    }.padding(8).frame(height: queueRowHeight).background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.frame(height: min(140, queueHeaderHeight + CGFloat(chat.queue.count) * queueRowHeight + CGFloat(max(0, chat.queue.count - 1)) * 8))
    }
    private func send() {
        guard canSend else { return }
        let text = draft; let steerNow = steer; sending = true; followingBottom = true; composerFocused = true
        Task {
            do {
                if text.trimmingCharacters(in: .whitespacesAndNewlines) != "/model" { try chat.validateImageInput(attachments.items) }
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/model" { optionsPage = .model }
                else if text.hasPrefix("/") {
                    let parts: [JSON] = try attachments.items.map { item in
                        if let type = item.mediaType { return ["type": "image", "mediaType": .string(type), "data": .string(try Data(contentsOf: item.file).base64EncodedString()), "name": .string(item.name)] }
                        return item.content
                    }
                    try await chat.executeCommand(text, attachments: parts)
                    attachments.clear()
                }
                else { try await chat.send(text, steer: steerNow, attachments: attachments.items); attachments.clear() }
                if draft == text { draft = "" }
                if text.trimmingCharacters(in: .whitespacesAndNewlines) != "/model" { sendFeedback += 1 }
            }
            catch { actionError = error.localizedDescription; if draft.isEmpty { draft = text } }
            sending = false
        }
    }
    private func perform(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { actionError = error.localizedDescription; dismissedError = nil } } }
}

private struct TurnView: View {
    let turn: TranscriptTurn
    @ObservedObject var chat: ChatStore
    @State private var expanded = false
    private var headerID: String? { turn.items.first { $0.role != "user" && $0.role != "command" }?.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(turn.items) { item in
                if item.id == headerID, turn.items.contains(where: { $0.turn != nil }) {
                    let active = chat.running && turn.outcome == nil && turn.id == TranscriptTurn.group(chat.transcript).last?.id
                    let label = active ? L("Running", "运行中") : turn.outcome == "completed" ? L("Completed", "已完成") : turn.outcome == "error" ? L("Failed", "失败") : turn.outcome != nil ? L("Stopped", "已停止") : L("Work details", "工作详情")
                    if turn.canCollapse {
                        Button { expanded.toggle() } label: {
                            Label(label + turn.countsLabel, systemImage: expanded ? "chevron.down" : "chevron.right").font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44)
                        }.tint(.secondary)
                    } else { Text(label + turn.countsLabel).font(.subheadline).foregroundStyle(.secondary) }
                }
                if turn.independent(item) {
                    MessageView(item: item, api: chat.api, sessionID: chat.sessionID).id(item.id)
                } else if item.role == "assistant" {
                    if expanded || !turn.canCollapse { MessageView(item: item, api: chat.api, sessionID: chat.sessionID, detailsOnly: true) }
                    MessageView(item: item, api: chat.api, sessionID: chat.sessionID, usage: chat.usage(for: item), hideDetails: true).id(item.id)
                } else if expanded || !turn.canCollapse {
                    MessageView(item: item, api: chat.api, sessionID: chat.sessionID).id(item.id)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageView: View {
    let item: TranscriptItem
    let api: RPCServing
    let sessionID: String
    var usage: JSON?
    var detailsOnly = false
    var hideDetails = false
    private var visibleBlocks: [TranscriptBlock] {
        item.blocks.filter { block in
            let main = ["text", "image", "file"].contains(block.kind)
            return ChatTranscriptProjection.visible(block) && (detailsOnly ? !main : hideDetails ? main : true)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.role == "user" || item.role == "command-input" {
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 6) {
                        if item.steering { Text(L("Steering", "引导中")).font(.caption2).foregroundStyle(.secondary) }
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            if block.kind == "image" || block.kind == "file" { HistoricalAttachmentView(block: block, api: api, sessionID: sessionID) }
                        }
                        if !item.text.isEmpty {
                            Text(item.text).textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 12)
                                .background(DRPStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                        }
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            if !["text", "image", "file"].contains(block.kind) { GenericTranscriptBlock(block: block) }
                        }
                        if let error = item.deliveryError { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
                        else if item.optimistic { Text(L("Sending…", "正在发送…")).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            } else if item.role == "context" || item.role == "trigger" {
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in ContextTranscriptBlock(block: block) }
            } else if item.role == "command" {
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                    DisclosureGroup {
                        if !block.text.isEmpty { Text(block.text).font(.caption).textSelection(.enabled) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(block.name.isEmpty ? L("Command", "命令") : block.name)
                            Text(block.text.isEmpty ? (block.raw["outcome"] == .null ? L("Running…", "运行中…") : block.raw["outcome"] == "error" ? L("Failed", "失败") : L("Done", "完成")) : block.text).lineLimit(1).foregroundStyle(block.raw["outcome"] == "error" ? Color.red : Color.secondary)
                        }.font(.caption).foregroundStyle(.secondary)
                    }.tint(.secondary)
                }
            } else if item.role == "notice" {
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                    if block.kind == "compaction" {
                        DisclosureGroup {
                            MarkdownView(text: block.text).font(.body).foregroundStyle(.primary).textSelection(.enabled)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("Conversation compacted", "对话已压缩"))
                                if let count = block.raw["shadowedItemCount"].int {
                                    Text(L("\(count) history items", "\(count) 条历史记录") + (block.raw["shadowedTokenCount"].int.map { L(" (~\($0) tokens)", "（约 \($0) 个令牌）") } ?? ""))
                                }
                            }
                        }.font(.caption).foregroundStyle(.secondary).tint(.secondary)
                    } else if block.kind == "model-retry" {
                        Label(L("Retrying model request", "正在重试模型请求"), systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                        if !block.text.isEmpty { Text(block.text).font(.caption).foregroundStyle(.secondary) }
                    } else if block.kind == "system-notice", !block.text.isEmpty {
                        Text(block.text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: .infinity)
                    } else { GenericTranscriptBlock(block: block).frame(maxWidth: .infinity, alignment: .center) }
                }
            } else {
                if item.interrupted && !detailsOnly { Text(L("Interrupted", "已中断")).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { _, block in
                    switch block.kind {
                    case "text": MarkdownView(text: block.text).textSelection(.enabled)
                    case "reasoning": ThinkingView(text: block.text)
                    case "tool-call": ToolCard(block: block, api: api, sessionID: sessionID)
                    case "image", "file": HistoricalAttachmentView(block: block, api: api, sessionID: sessionID)
                    default: GenericTranscriptBlock(block: block)
                    }
                }
                if let usage { TurnUsageView(usage: usage) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContextTranscriptBlock: View {
    let block: TranscriptBlock
    var body: some View {
        DisclosureGroup {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(ChatTranscriptProjection.contextBody(block).rows.enumerated()), id: \.offset) { _, row in
                        if !row["label"].text.isEmpty { Text(row["label"].text).font(.caption.weight(.semibold)) }
                        Text(ChatTranscriptProjection.bounded(row["text"].text)).font(.caption).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
        } label: {
            let producer = block.raw["producer"].text
            let summary = ChatTranscriptProjection.contextBody(block).form == "notice" ? block.raw["source"]["summary"].text : ""
            let tools = ChatTranscriptProjection.contextBody(block).form == "tools"
            Label((tools ? L("Tools updated", "工具已更新") : block.raw["trigger"] == true ? L("Execution request", "执行请求") : block.raw["source"]["kind"] == "session-reference" ? L("Recall", "召回") : L("Inject", "注入")) + (producer.isEmpty ? "" : " · " + producer) + (summary.isEmpty ? "" : " · " + summary), systemImage: "text.badge.plus").font(.caption).foregroundStyle(.secondary)
        }.tint(.secondary)
    }
}

private struct GenericTranscriptBlock: View {
    let block: TranscriptBlock
    var body: some View {
        DisclosureGroup {
            ScrollView([.horizontal, .vertical]) {
                Text(block.text.isEmpty ? block.raw.formatted : block.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
            }.frame(maxHeight: 240)
        } label: {
            Label(block.kind == "unknown-surface" ? L("Unknown message", "未知消息") : block.kind, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct ThinkingView: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            HStack {
                Text(L("Thinking", "思考过程"))
                Text(text.split(separator: "\n").first.map(String.init) ?? "").lineLimit(1)
            }.font(.caption).foregroundStyle(Color.secondary)
        }
    }
}
