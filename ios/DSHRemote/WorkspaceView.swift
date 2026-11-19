import SwiftUI

enum DRPStyle {
    static let accent = Color(red: 65 / 255, green: 118 / 255, blue: 230 / 255)
    static let sidebar = Color(uiColor: .secondarySystemBackground)
}

struct StatusBanner: View {
    let message: String
    var reconnecting = false
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            if reconnecting { ProgressView().controlSize(.small) }
            else { Image(systemName: "exclamationmark.circle") }
            Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.accessibilityLabel(L("Dismiss", "关闭")) }
        }
        .padding(12).foregroundStyle(.primary)
        .background(reconnecting ? DRPStyle.accent.opacity(0.09) : Color.orange.opacity(0.12))
    }
}

struct WorkspaceView: View {
    let connection: NativeConnection
    let serverName: String
    let addressLabel: String
    let onSwitch: () -> Void
    let onLogout: () async throws -> Void
    @ObservedObject private var sidebar: SidebarStore
    @ObservedObject private var events: RemoteEvents
    @StateObject private var chatSelection: ChatSelection
    private var selection: String? { chatSelection.chat?.sessionID }
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var actionError: String?
    @State private var hasConnected = false
    @State private var showingSettings = false
    @State private var interactions = InteractionRouting()
    init(connection: NativeConnection, serverName: String, addressLabel: String, onSwitch: @escaping () -> Void, onLogout: @escaping () async throws -> Void) {
        self.connection = connection; self.serverName = serverName; self.onSwitch = onSwitch; self.onLogout = onLogout
        self.addressLabel = addressLabel
        sidebar = connection.sidebar; events = connection.events
        _chatSelection = StateObject(wrappedValue: ChatSelection(makeChat: connection.chat))
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
            SidebarView(store: sidebar, events: events, selection: selection, serverName: serverName, addressLabel: addressLabel, onSelect: openChat, onReview: review, onCreate: create, onSwitch: onSwitch, onLogout: onLogout, onSettings: { showingSettings = true })
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
                .safeAreaInset(edge: .top, spacing: 0) { pendingBanner }
        } detail: {
            Group {
                if let chat = chatSelection.chat {
                    ChatView(chat: chat, title: sidebar.sessions[chat.sessionID]?.title ?? L("New chat", "新对话"))
                        .id(chat.sessionID)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "sparkle").font(.system(size: 42)).foregroundStyle(DRPStyle.accent)
                        Text(L("What can we work on?", "今天一起做点什么？")).font(.title2.bold())
                        Text(L("Choose a conversation or start a new chat.", "选择对话，或开始新的聊天。")).foregroundStyle(.secondary)
                        Button(L("New chat", "新对话")) { create(sidebar.workspaces.first?.id) }.buttonStyle(.borderedProminent)
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle("DRP")
                }
            }.safeAreaInset(edge: .top, spacing: 0) { pendingBanner }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { chatSelection.resume() }
        .onDisappear { chatSelection.stop() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if events.clientID == nil {
                StatusBanner(message: hasConnected ? L("Connection lost. Reconnecting…", "连接已断开，正在重新连接…") : L("Connecting…", "正在连接…"), reconnecting: true)
            }
            if let actionError { StatusBanner(message: actionError, dismiss: { self.actionError = nil }) }
        }
        .onChange(of: events.clientID, initial: true) { _, id in if id != nil { hasConnected = true } }
        .onChange(of: events.pending, initial: true) { _, pending in interactions.reconcile(pending, openSessionID: selection) }
        .onChange(of: selection) { _, id in interactions.reconcile(events.pending, openSessionID: id) }
        .sheet(isPresented: $showingSettings) { HostSettingsView(api: connection.api) }
        .sheet(item: Binding(get: { events.pending.first { $0.id == interactions.presentedID } }, set: { if $0 == nil { interactions.dismiss() } })) { item in
            InteractionSheet(events: events, api: connection.api, item: item, sessionTitle: sidebar.sessions[item.agentID]?.title ?? L("Conversation", "对话"))
                .id(item.id)
        }
    }
    @ViewBuilder private var pendingBanner: some View {
        if let item = events.pending.first {
            Button { review(item) } label: {
                Label(InteractionRouting.label(events.pending), systemImage: "exclamationmark.bubble")
                    .font(.subheadline).frame(maxWidth: .infinity).padding(12)
            }.background(DRPStyle.accent.opacity(0.1)).background(.background)
        }
    }
    private func review(_ item: PendingInteraction) {
        interactions.review(item)
        if let id = InteractionRouting.sessionID(item, knownSessionIDs: Set(sidebar.sessions.keys)) {
            openChat(id)
        }
    }
    private func openChat(_ sessionID: String) {
        chatSelection.select(sessionID); compactColumn = .detail
    }
    private func create(_ workspaceID: String?) {
        Task {
            do { openChat(try await sidebar.createSession(workspaceID: workspaceID)) }
            catch { actionError = error.localizedDescription }
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var store: SidebarStore
    @ObservedObject var events: RemoteEvents
    let selection: String?
    let serverName: String
    let addressLabel: String
    let onSelect: (String) -> Void
    let onReview: (PendingInteraction) -> Void
    let onCreate: (String?) -> Void
    let onSwitch: () -> Void
    let onLogout: () async throws -> Void
    let onSettings: () -> Void
    @State private var renaming = false
    @State private var renameID = ""
    @State private var renameText = ""
    @State private var actionError: String?
    @State private var showingFolders = false
    @State private var renamingWorkspace = false
    @State private var deletingWorkspace: WorkspaceRow?
    @State private var contentSearch = false
    var body: some View {
        List {
            if let actionError { StatusBanner(message: actionError, dismiss: { self.actionError = nil }).listRowInsets(EdgeInsets()) }
            if !store.loaded {
                HStack { Spacer(); ProgressView(L("Loading conversations…", "正在加载对话…")); Spacer() }
            }
            ForEach(store.groups) { group in
                if !group.sessions.isEmpty || !["pinned", "ungrouped"].contains(group.id) {
                    Section {
                        ForEach(group.sessions) { row in
                            HStack(spacing: 10) {
                                Button { onSelect(row.id) } label: {
                                    HStack(spacing: 10) {
                                        if row.running { ProgressView().controlSize(.mini).accessibilityLabel(L("Running", "运行中")) }
                                        else { Image(systemName: "bubble.left").font(.caption).foregroundStyle(.secondary) }
                                        Text(row.title).lineLimit(2).font(.subheadline).foregroundStyle(.primary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                                }
                                let pending = InteractionRouting.forSession(events.pending, sessionID: row.id)
                                if let item = pending.first {
                                    Button { onReview(item) } label: {
                                        Text("\(pending.count)").font(.caption.bold()).padding(6)
                                            .background(DRPStyle.accent.opacity(0.15), in: Capsule())
                                    }.accessibilityLabel(InteractionRouting.label(pending))
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selection == row.id ? DRPStyle.accent.opacity(0.1) : Color(uiColor: .secondarySystemGroupedBackground))
                            .contextMenu { actions(row) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { perform { if store.archivedOnly { try await store.unarchive(row.id) } else { try await store.archive(row.id) } } } label: { Label(store.archivedOnly ? L("Unarchive", "取消归档") : L("Archive", "归档"), systemImage: "archivebox") }
                                Button { beginRename(row) } label: { Label(L("Rename", "重命名"), systemImage: "pencil") }.tint(.gray)
                            }
                            .swipeActions(edge: .leading) {
                                Button { togglePin(row.id) } label: { Label(store.pinnedIDs.contains(row.id) ? L("Unpin", "取消置顶") : L("Pin", "置顶"), systemImage: store.pinnedIDs.contains(row.id) ? "pin.slash" : "pin") }.tint(DRPStyle.accent)
                            }
                        }
                    } header: {
                        HStack {
                            Label(group.title, systemImage: group.id == "pinned" ? "pin" : group.id == "ungrouped" ? "bubble.left.and.bubble.right" : "folder")
                                .lineLimit(1).textCase(nil)
                            Spacer()
                            if !["pinned", "ungrouped"].contains(group.id) {
                                Button { onCreate(group.id) } label: { Image(systemName: "plus") }
                                    .accessibilityLabel(L("New chat in ", "在此工作区新建对话：") + group.title)
                            }
                            if let workspace = store.workspaces.first(where: { $0.id == group.id }) {
                                Menu {
                                    Button(L("Rename workspace", "重命名工作区")) { renameID = workspace.id; renameText = workspace.title; renamingWorkspace = true; renaming = true }
                                    Button(L("Remove workspace", "移除工作区"), role: .destructive) { deletingWorkspace = workspace }
                                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel(L("Workspace actions", "工作区操作"))
                            }
                        }
                    }
                }
            }
            if store.sessions.isEmpty && store.loaded { Text(L("No conversations yet", "还没有对话")).foregroundStyle(.secondary) }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden).background(DRPStyle.sidebar)
        .navigationTitle("DeepSeek Remote")
        .searchable(text: $store.searchText, prompt: L("Search sessions", "搜索会话"))
        .onChange(of: contentSearch) { _, _ in store.clearSearchResults() }
        .task(id: store.searchText + String(contentSearch)) {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                if contentSearch { try await store.search(store.searchText) }
            } catch { if !Task.isCancelled { actionError = L("Content search unavailable; showing name matches. ", "内容搜索不可用，正在显示名称匹配。") + error.localizedDescription } }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Toggle(L("Archived sessions", "已归档会话"), isOn: $store.archivedOnly)
                    Toggle(L("Search message content", "搜索消息内容"), isOn: $contentSearch)
                    Button(L("Add workspace", "添加工作区")) { showingFolders = true }
                } label: { Label(store.archivedOnly ? L("Archived", "已归档") : L("View options", "视图选项"), systemImage: store.archivedOnly ? "archivebox.fill" : "line.3.horizontal.decrease.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) { Button { onCreate(store.workspaces.first?.id) } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel(L("New chat", "新对话")) }
        }
        .sheet(isPresented: $showingFolders) { HostFolderView(store: store) }
        .confirmationDialog(L("Remove workspace?", "移除工作区？"), isPresented: Binding(get: { deletingWorkspace != nil }, set: { if !$0 { deletingWorkspace = nil } }), titleVisibility: .visible) {
            Button(L("Remove workspace", "移除工作区"), role: .destructive) {
                if let workspace = deletingWorkspace { perform { try await store.deleteWorkspace(workspace.id) } }; deletingWorkspace = nil
            }
        } message: { Text(L("Removes the workspace registration, not the host folder or its files.", "仅移除工作区记录，不会删除主机文件夹或其中的文件。")) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Divider()
                HStack {
                    Image(systemName: "network").foregroundStyle(DRPStyle.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(serverName).font(.subheadline).lineLimit(1)
                        Text(addressLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                }
                HStack {
                    Button(action: onSwitch) { Label(L("Servers", "服务器"), systemImage: "arrow.left.arrow.right") }
                    Spacer()
                    Button(action: onSettings) { Label(L("Settings", "设置"), systemImage: "gearshape") }.accessibilityIdentifier("hostSettings")
                    Spacer()
                    Button { perform { try await onLogout() } } label: { Label(L("Log out", "退出"), systemImage: "rectangle.portrait.and.arrow.right") }
                }.font(.caption)
            }.padding(.horizontal, 20).padding(.bottom, 12).background(DRPStyle.sidebar)
        }
        .refreshable { do { try await store.refresh() } catch { actionError = error.localizedDescription } }
        .alert(renamingWorkspace ? L("Rename workspace", "重命名工作区") : L("Rename conversation", "重命名对话"), isPresented: $renaming) {
            TextField(L("Title", "标题"), text: $renameText)
            Button(L("Cancel", "取消"), role: .cancel) {}
            Button(L("Save", "保存")) {
                let workspace = renamingWorkspace
                perform { if workspace { try await store.renameWorkspace(renameID, title: renameText) } else { try await store.rename(renameID, title: renameText) } }
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    @ViewBuilder private func actions(_ row: SessionRow) -> some View {
        Button { beginRename(row) } label: { Label(L("Rename", "重命名"), systemImage: "pencil") }
        Button { togglePin(row.id) } label: { Label(store.pinnedIDs.contains(row.id) ? L("Unpin", "取消置顶") : L("Pin", "置顶"), systemImage: "pin") }
        if store.archivedIDs.contains(row.id) {
            Button { perform { try await store.unarchive(row.id) } } label: { Label(L("Unarchive", "取消归档"), systemImage: "archivebox") }
        } else {
            Button(role: .destructive) { perform { try await store.archive(row.id) } } label: { Label(L("Archive", "归档"), systemImage: "archivebox") }
        }
    }
    private func beginRename(_ row: SessionRow) { renameID = row.id; renameText = row.title; renamingWorkspace = false; renaming = true }
    private func togglePin(_ id: String) { perform { try await store.pin(id, pinned: !store.pinnedIDs.contains(id)) } }
    private func perform(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { actionError = error.localizedDescription } } }
}
