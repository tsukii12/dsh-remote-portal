import SwiftUI

private struct BottomPosition: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatView: View {
    @StateObject private var chat: ChatStore
    let title: String
    @State private var draft = ""
    @State private var sending = false
    @State private var followingBottom = true
    @State private var loadingOlder = false
    @State private var actionError: String?
    @State private var dismissedError: String?
    @FocusState private var composerFocused: Bool
    init(chat: ChatStore, title: String) { _chat = StateObject(wrappedValue: chat); self.title = title }
    var body: some View {
        VStack(spacing: 0) {
            if let error = actionError ?? chat.error, error != dismissedError { StatusBanner(message: error, dismiss: { dismissedError = error; actionError = nil }) }
            transcript
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("DRP").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { VStack(spacing: 2) { Text("DRP").font(.headline); Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1) } } }
        .task {
            do { try await chat.start(); try await chat.loadModels() }
            catch { if !Task.isCancelled { actionError = error.localizedDescription } }
        }
        .onDisappear { chat.stop() }
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
                        ForEach(chat.transcript) { item in MessageView(item: item).id(item.id) }
                        if let message = chat.inProgress { MessageView(item: message).id(message.id) }
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
            HStack {
                modelMenu
                Spacer()
                if chat.running { Label(L("Working", "处理中"), systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField(L("Message DRP…", "发送消息给 DRP…"), text: $draft, axis: .vertical)
                    .lineLimit(1...6).focused($composerFocused).padding(.vertical, 12).padding(.leading, 14)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("chatComposer")
                Button {
                    if chat.running { perform { try await chat.cancel() } }
                    else { send() }
                } label: {
                    Image(systemName: chat.running ? "stop.fill" : "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(canSend || chat.running ? DRPStyle.accent : Color.gray.opacity(0.4), in: Circle())
                }
                .disabled(!chat.running && !canSend).padding(6)
                .accessibilityLabel(chat.running ? L("Stop", "停止") : L("Send", "发送")).accessibilityIdentifier("sendMessage")
            }.background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 22))
        }
        .padding(.horizontal, 16).padding(.bottom, 10).frame(maxWidth: 800).frame(maxWidth: .infinity).background(.bar)
    }
    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var modelMenu: some View {
        Menu {
            ForEach(Array(chat.catalog["groups"].array.enumerated()), id: \.offset) { _, group in
                Section(group["name"].text) {
                    ForEach(Array(group["models"].array.enumerated()), id: \.offset) { _, model in
                        Button(model["name"].string ?? model["id"].text) { perform { try await chat.selectModel(provider: group["id"].text, model: model["id"].text) } }
                    }
                }
            }
            if chat.catalog["groups"].array.isEmpty { Text(L("No models available", "没有可用模型")) }
            Button(L("Refresh models", "刷新模型")) { perform { try await chat.loadModels() } }
        } label: { Label(modelLabel, systemImage: "chevron.down").font(.caption.weight(.medium)).lineLimit(1) }
        .accessibilityLabel(L("Select model: ", "选择模型：") + modelLabel)
    }
    private var modelLabel: String {
        let selection = chat.selectedModel
        let model = selection["selected"]["model"].string ?? selection["next"]["model"].string ?? selection["lastUsed"]["model"].string ?? chat.catalog["default"]["model"].string
        return model ?? L("Choose model", "选择模型")
    }
    private func send() {
        guard canSend else { return }
        let text = draft; draft = ""; sending = true; followingBottom = true; composerFocused = false
        Task {
            do { try await chat.send(text) }
            catch { actionError = error.localizedDescription; if draft.isEmpty { draft = text } }
            sending = false
        }
    }
    private func perform(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { actionError = error.localizedDescription; dismissedError = nil } } }
}

private struct MessageView: View {
    let item: TranscriptItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.role == "user" {
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(item.text).textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 12)
                            .background(DRPStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
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
                    default: EmptyView()
                    }
                }
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
