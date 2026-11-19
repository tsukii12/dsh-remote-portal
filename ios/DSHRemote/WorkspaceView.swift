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
    @State private var selection: String?
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var actionError: String?
    @State private var hasConnected = false
    init(connection: NativeConnection, serverName: String, addressLabel: String, onSwitch: @escaping () -> Void, onLogout: @escaping () async throws -> Void) {
        self.connection = connection; self.serverName = serverName; self.onSwitch = onSwitch; self.onLogout = onLogout
        self.addressLabel = addressLabel
        sidebar = connection.sidebar; events = connection.events
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
            SidebarView(store: sidebar, selection: selection, serverName: serverName, addressLabel: addressLabel, onSelect: { selection = $0; compactColumn = .detail }, onCreate: create, onSwitch: onSwitch, onLogout: onLogout)
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            if let selection {
                ChatView(chat: connection.chat(selection), title: sidebar.sessions[selection]?.title ?? L("New chat", "新对话"))
                    .id(selection)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "sparkle").font(.system(size: 42)).foregroundStyle(DRPStyle.accent)
                    Text(L("What can we work on?", "今天一起做点什么？")).font(.title2.bold())
                    Text(L("Choose a conversation or start a new chat.", "选择对话，或开始新的聊天。")).foregroundStyle(.secondary)
                    Button(L("New chat", "新对话")) { create(sidebar.workspaces.first?.id) }.buttonStyle(.borderedProminent)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle("DRP")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .top, spacing: 0) {
            if events.clientID == nil {
                StatusBanner(message: hasConnected ? L("Connection lost. Reconnecting…", "连接已断开，正在重新连接…") : L("Connecting…", "正在连接…"), reconnecting: true)
            }
            if let actionError { StatusBanner(message: actionError, dismiss: { self.actionError = nil }) }
        }
        .onChange(of: events.clientID, initial: true) { _, id in if id != nil { hasConnected = true } }
        .sheet(item: Binding(get: { events.pending.first }, set: { _ in })) { item in
            InteractionSheet(events: events, api: connection.api, item: item, sessionTitle: sidebar.sessions[item.agentID]?.title ?? L("Conversation", "对话"))
                .id(item.id).interactiveDismissDisabled()
        }
    }
    private func create(_ workspaceID: String?) {
        Task {
            do { selection = try await sidebar.createSession(workspaceID: workspaceID); compactColumn = .detail }
            catch { actionError = error.localizedDescription }
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var store: SidebarStore
    let selection: String?
    let serverName: String
    let addressLabel: String
    let onSelect: (String) -> Void
    let onCreate: (String?) -> Void
    let onSwitch: () -> Void
    let onLogout: () async throws -> Void
    @State private var renaming = false
    @State private var renameID = ""
    @State private var renameText = ""
    @State private var actionError: String?
    var body: some View {
        List {
            if let actionError { StatusBanner(message: actionError, dismiss: { self.actionError = nil }).listRowInsets(EdgeInsets()) }
            ForEach(store.groups) { group in
                if !group.sessions.isEmpty || !["pinned", "ungrouped"].contains(group.id) {
                    Section {
                        ForEach(group.sessions) { row in
                            Button { onSelect(row.id) } label: {
                                HStack(spacing: 10) {
                                    if row.running { ProgressView().controlSize(.mini).accessibilityLabel(L("Running", "运行中")) }
                                    else { Image(systemName: "bubble.left").font(.caption).foregroundStyle(.secondary) }
                                    Text(row.title).lineLimit(2).font(.subheadline).foregroundStyle(.primary)
                                }.padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selection == row.id ? DRPStyle.accent.opacity(0.1) : Color(uiColor: .secondarySystemGroupedBackground))
                            .contextMenu { actions(row) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { perform { try await store.archive(row.id) } } label: { Label(L("Archive", "归档"), systemImage: "archivebox") }
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
                        }
                    }
                }
            }
            if store.sessions.isEmpty && store.loaded { Text(L("No conversations yet", "还没有对话")).foregroundStyle(.secondary) }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden).background(DRPStyle.sidebar)
        .navigationTitle("DRP")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { onCreate(store.workspaces.first?.id) } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel(L("New chat", "新对话")) } }
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
                    Button { perform { try await onLogout() } } label: { Label(L("Log out", "退出"), systemImage: "rectangle.portrait.and.arrow.right") }
                }.font(.caption)
            }.padding(.horizontal, 20).padding(.bottom, 12).background(DRPStyle.sidebar)
        }
        .refreshable { do { try await store.refresh() } catch { actionError = error.localizedDescription } }
        .alert(L("Rename conversation", "重命名对话"), isPresented: $renaming) {
            TextField(L("Title", "标题"), text: $renameText)
            Button(L("Cancel", "取消"), role: .cancel) {}
            Button(L("Save", "保存")) { perform { try await store.rename(renameID, title: renameText) } }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    @ViewBuilder private func actions(_ row: SessionRow) -> some View {
        Button { beginRename(row) } label: { Label(L("Rename", "重命名"), systemImage: "pencil") }
        Button { togglePin(row.id) } label: { Label(store.pinnedIDs.contains(row.id) ? L("Unpin", "取消置顶") : L("Pin", "置顶"), systemImage: "pin") }
        Button(role: .destructive) { perform { try await store.archive(row.id) } } label: { Label(L("Archive", "归档"), systemImage: "archivebox") }
    }
    private func beginRename(_ row: SessionRow) { renameID = row.id; renameText = row.title; renaming = true }
    private func togglePin(_ id: String) { perform { try await store.pin(id, pinned: !store.pinnedIDs.contains(id)) } }
    private func perform(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { actionError = error.localizedDescription } } }
}
