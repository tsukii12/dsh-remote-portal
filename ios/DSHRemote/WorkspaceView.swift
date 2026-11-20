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
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(L("Dismiss", "关闭")) }
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
    @State private var terminalSessionID: String?
    @State private var interactions = InteractionRouting()
    @State private var draftID = UUID()
    @State private var draftWorkspaceID: String?
    @State private var focusChatID: String?
    @State private var fileSessionID: String?
    init(connection: NativeConnection, serverName: String, addressLabel: String, onSwitch: @escaping () -> Void, onLogout: @escaping () async throws -> Void) {
        self.connection = connection; self.serverName = serverName; self.onSwitch = onSwitch; self.onLogout = onLogout
        self.addressLabel = addressLabel
        sidebar = connection.sidebar; events = connection.events
        _chatSelection = StateObject(wrappedValue: ChatSelection(makeChat: connection.chat))
    }
    var body: some View {
        AdaptiveWorkspace(visibility: $visibility, column: $compactColumn) {
            SidebarView(store: sidebar, events: events, selection: selection, serverName: serverName, addressLabel: addressLabel, onSelect: openChat, onReview: review, onCreate: create, onSwitch: { Task { await leaveServer() } }, onLogout: {
                if let selection { try await sidebar.abandonEmptyCreated(selection) }
                try await onLogout()
            }, onSettings: { showingSettings = true }, onTerminals: { terminalSessionID = $0 }, onFiles: { fileSessionID = $0 })
                .navigationSplitViewColumnWidth(min: 340, ideal: 360, max: 440)
                .safeAreaInset(edge: .top, spacing: 0) { pendingBanner }
        } detail: {
            Group {
                if let chat = chatSelection.chat {
                    ChatView(chat: chat, title: sidebar.sessions[chat.sessionID]?.title ?? L("New chat", "新对话"), serverName: serverName, workspaceName: sidebar.workspaces.first { $0.sessionIDs.contains(chat.sessionID) }?.title ?? "", agents: sidebar.sessions.values.filter { $0.parentID == chat.sessionID }.sorted { $0.title < $1.title }, focusOnOpen: focusChatID == chat.sessionID, onMenu: { visibility = .all; compactColumn = .sidebar }, onNew: { create(sidebar.workspaces.first { $0.sessionIDs.contains(chat.sessionID) }?.id) }, onAgent: openChat)
                        .id(chat.sessionID)
                } else {
                    NewChatView(api: connection.api, sidebar: sidebar, workspaceID: draftWorkspaceID ?? sidebar.workspaces.first?.id, serverName: serverName, base: connection.api.base, events: events, onMenu: { visibility = .all; compactColumn = .sidebar }, onOpen: { chat in focusChatID = chat.sessionID; chatSelection.adopt(chat); openChat(chat.sessionID) }).id(draftID)
                }
            }.safeAreaInset(edge: .top, spacing: 0) { pendingBanner }
        }
        .sheet(isPresented: Binding(get: { fileSessionID != nil }, set: { if !$0 { fileSessionID = nil } })) { if let fileSessionID { WorkspaceFilesView(api: connection.api, sessionID: fileSessionID) } }
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
        .onChange(of: selection) { old, id in
            interactions.reconcile(events.pending, openSessionID: id)
            if let old { abandon(old) }
        }
        .onChange(of: compactColumn) { _, column in if column == .sidebar, let selection { abandon(selection) } }
        .sheet(isPresented: $showingSettings) { HostSettingsView(api: connection.api) }
        .sheet(isPresented: Binding(get: { terminalSessionID != nil }, set: { if !$0 { terminalSessionID = nil } })) { if let terminalSessionID { TerminalsView(api: connection.api, sessionID: terminalSessionID) } }
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
    private func abandon(_ id: String) {
        Task {
            do {
                try await sidebar.abandonEmptyCreated(id)
                if sidebar.archivedIDs.contains(id), selection == id { chatSelection.select(nil) }
            }
            catch { actionError = error.localizedDescription }
        }
    }
    private func leaveServer() async {
        do {
            if let selection { try await sidebar.abandonEmptyCreated(selection) }
            onSwitch()
        } catch { actionError = error.localizedDescription }
    }
    private func create(_ workspaceID: String?) {
        draftWorkspaceID = workspaceID; draftID = UUID(); chatSelection.select(nil); compactColumn = .detail
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
    let onTerminals: (String) -> Void
    let onFiles: (String) -> Void
    @State private var renaming = false
    @State private var renameID = ""
    @State private var renameText = ""
    @State private var actionError: String?
    @State private var showingFolders = false
    @State private var renamingWorkspace = false
    @State private var deletingWorkspace: WorkspaceRow?
    @State private var contentSearch = false
    @State private var cleaningEmpty = false
    @State private var workspaceFilter: String?
    @State private var chosenWorkspace = false
    @State private var filter = 0
    @StateObject private var read = SidebarReadState()
    private var activeWorkspace: WorkspaceRow? { store.workspaces.first { $0.id == workspaceFilter } ?? (chosenWorkspace ? nil : store.workspaces.first) }
    private var allRows: [SessionRow] { Array(Dictionary(store.groups.flatMap(\.sessions).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values) }
    private var timeline: [SessionGroup] {
        let rows = allRows.filter { row in
            (activeWorkspace == nil || activeWorkspace!.sessionIDs.contains(row.id)) && (filter == 0 || (filter == 1 && row.running) || (filter == 2 && !InteractionRouting.forSession(events.pending, sessionID: row.id).isEmpty) || (filter == 3 && read.unread(row)))
        }
        return SessionTimeline.groups(rows, pinned: store.pinnedIDs)
    }
    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
        List {
            if let actionError { StatusBanner(message: actionError, dismiss: { self.actionError = nil }).listRowInsets(EdgeInsets()) }
            if !store.loaded {
                HStack { Spacer(); ProgressView(L("Loading conversations…", "正在加载对话…")); Spacer() }
            }
            ForEach(timeline) { group in
                if !group.sessions.isEmpty || !["pinned", "ungrouped"].contains(group.id) {
                    Section {
                        ForEach(group.sessions) { row in
                            HStack(spacing: 10) {
                                Button { read.mark(row); onSelect(row.id) } label: {
                                    HStack(spacing: 10) {
                                        Text(row.title).lineLimit(1).font(.subheadline).foregroundStyle(.primary)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
                            .listRowBackground(selection == row.id ? DRPStyle.accent.opacity(0.1) : .clear)
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
                            Text(group.title).lineLimit(1).textCase(nil).font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            if timeline.isEmpty && store.loaded { Text(L("No matching conversations", "没有匹配的对话")).foregroundStyle(.secondary).listRowBackground(Color.clear) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        sidebarFooter
        }.background(.ultraThinMaterial).toolbar(.hidden, for: .navigationBar)
        .onAppear { if store.loaded { read.baseline(allRows, server: serverName) } }
        .onChange(of: store.loaded) { _, loaded in if loaded { read.baseline(allRows, server: serverName) } }
        .onChange(of: selection) { _, id in if let id, let row = store.sessions[id] { read.mark(row) } }
        .onChange(of: contentSearch) { _, _ in store.clearSearchResults() }
        .task(id: store.searchText + String(contentSearch)) {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                if contentSearch { try await store.search(store.searchText) }
            } catch { if !Task.isCancelled { actionError = L("Content search unavailable; showing name matches. ", "内容搜索不可用，正在显示名称匹配。") + error.localizedDescription } }
        }
        .sheet(isPresented: $showingFolders) { HostFolderView(store: store) }
        .confirmationDialog(L("Archive empty conversations?", "归档空对话？"), isPresented: $cleaningEmpty, titleVisibility: .visible) {
            Button(L("Archive empty conversations", "归档空对话")) { perform { try await store.cleanEmptySessions() } }
        } message: { Text(L("Only idle conversations marked empty by the host are archived. No messages are deleted.", "仅归档主机标记为空的空闲对话，不会删除消息。")) }
        .confirmationDialog(L("Remove workspace?", "移除工作区？"), isPresented: Binding(get: { deletingWorkspace != nil }, set: { if !$0 { deletingWorkspace = nil } }), titleVisibility: .visible) {
            Button(L("Remove workspace", "移除工作区"), role: .destructive) {
                if let workspace = deletingWorkspace { perform { try await store.deleteWorkspace(workspace.id) } }; deletingWorkspace = nil
            }
        } message: { Text(L("Removes the workspace registration, not the host folder or its files.", "仅移除工作区记录，不会删除主机文件夹或其中的文件。")) }
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
    private var sidebarHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                PixelWhale().scaleEffect(0.5).frame(width: 32, height: 28)
                ViewThatFits(in: .horizontal) { Text(serverName).font(.headline); Text("DSH").font(.headline) }.lineLimit(1)
                Spacer(minLength: 0)
                workspacePicker(symbolOnly: true)
                GlassCircle(symbol: "arrow.left.arrow.right", label: L("Switch server", "切换服务器"), action: onSwitch)
                Button { onCreate(activeWorkspace?.id) } label: {
                    Label(L("New chat", "新对话"), systemImage: "square.and.pencil").font(.caption.bold()).fixedSize().padding(.horizontal, 12).frame(minHeight: 44).foregroundStyle(.white).background(DRPStyle.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search conversations", "搜索对话"), text: $store.searchText).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 44)
                if !store.searchText.isEmpty { Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel(L("Clear search", "清空搜索")) }
            }.padding(.leading, 14).padding(.trailing, 4).background(.regularMaterial, in: Capsule())
            HStack {
                workspacePicker(symbolOnly: false)
                Spacer(minLength: 0)
                Menu {
                    if let workspace = activeWorkspace {
                        Button(L("Rename workspace", "重命名工作区")) { renameID = workspace.id; renameText = workspace.title; renamingWorkspace = true; renaming = true }
                        Button(L("Remove workspace", "移除工作区"), role: .destructive) { deletingWorkspace = workspace }
                    }
                    Toggle(L("Archived sessions", "已归档会话"), isOn: $store.archivedOnly)
                    Toggle(L("Search message content", "搜索消息内容"), isOn: $contentSearch)
                    Button(L("Add workspace", "添加工作区")) { showingFolders = true }
                    Button(L("Archive empty conversations…", "归档空对话…")) { cleaningEmpty = true }
                    Button(L("Log out", "退出")) { perform { try await onLogout() } }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel(L("Workspace & view options", "工作区与视图选项"))
            }
            HStack(spacing: 6) {
                ForEach(Array([L("All", "全部"), L("Running", "运行中"), L("Pending", "待确认"), L("Unread", "未读")].enumerated()), id: \.offset) { index, title in
                    Button { filter = index } label: { Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 44).background(filter == index ? Color.primary : Color.secondary.opacity(0.07), in: Capsule()).foregroundStyle(filter == index ? Color(uiColor: .systemBackground) : .primary) }.accessibilityAddTraits(filter == index ? .isSelected : [])
                }
            }
        }.buttonStyle(.plain).padding(12)
    }
    private func workspacePicker(symbolOnly: Bool) -> some View {
        Menu {
            Button(L("All workspaces", "全部工作区")) { chosenWorkspace = true; workspaceFilter = nil }
            ForEach(store.workspaces) { row in Button(row.title) { chosenWorkspace = true; workspaceFilter = row.id } }
            Button(L("Add workspace", "添加工作区")) { showingFolders = true }
        } label: {
            if symbolOnly { Image(systemName: "square.3.layers.3d").font(.title3).frame(width: 44, height: 44).background(.regularMaterial, in: Circle()) }
            else { Label((activeWorkspace?.title ?? L("All workspaces", "全部工作区")) + " ⌄", systemImage: "folder").font(.subheadline.weight(.semibold)).lineLimit(1).frame(minHeight: 44) }
        }.accessibilityLabel(L("Choose workspace", "选择工作区"))
    }
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button(action: onSwitch) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").font(.title3).frame(width: 44, height: 44).background(DRPStyle.accent.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(serverName).font(.subheadline.bold()).lineLimit(1)
                        HStack(spacing: 5) { Circle().fill(.green).frame(width: 6, height: 6); Text(addressLabel.components(separatedBy: " · ").first ?? "").font(.caption).foregroundStyle(.secondary) }
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.accessibilityLabel(L("Switch server: ", "切换服务器：") + serverName)
            Menu {
                if let id = selection ?? allRows.first?.id {
                    Button { onFiles(id) } label: { Label(L("Workspace files", "工作区文件"), systemImage: "folder") }
                    Button { onTerminals(id) } label: { Label(L("Terminals", "终端"), systemImage: "terminal") }
                } else { Text(L("Send a message to open workspace tools.", "发送消息后可打开工作区工具。")) }
            } label: { Image(systemName: "square.grid.3x3").font(.title3).frame(width: 44, height: 44).background(.regularMaterial, in: Circle()) }.accessibilityLabel(L("Files & terminals", "文件与终端"))
            GlassCircle(symbol: "gearshape", label: L("Settings", "设置"), action: onSettings).accessibilityIdentifier("hostSettings")
        }.buttonStyle(.plain).padding(12)
    }
    @ViewBuilder private func actions(_ row: SessionRow) -> some View {
        Button { onTerminals(row.id) } label: { Label(L("Terminals", "终端"), systemImage: "terminal") }
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
