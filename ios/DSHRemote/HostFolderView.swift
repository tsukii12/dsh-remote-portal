import SwiftUI

struct HostFolderView: View {
    @ObservedObject var store: SidebarStore
    @Environment(\.dismiss) private var dismiss
    @State private var listing: JSON = [:]
    @State private var path = ""
    @State private var folderName = ""
    @State private var showingNewFolder = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(L("Absolute host path", "主机绝对路径"), text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(L("Browse path", "浏览路径")) { browse(path) }
                    Text(L("Folders are on the dsh host, not this iPhone.", "文件夹位于 dsh 主机上，而非此 iPhone。" )).font(.caption).foregroundStyle(.secondary)
                }
                if let error { StatusBanner(message: error, dismiss: { self.error = nil }) }
                if let parent = listing["parent"].string {
                    Button { browse(parent) } label: { Label(L("Parent folder", "上一级文件夹"), systemImage: "arrow.up") }
                }
                ForEach(Array(listing["roots"].array.enumerated()), id: \.offset) { _, root in
                    Button(root["name"].text) { browse(root["path"].text) }
                }
                Section(listing["path"].string ?? L("Host folders", "主机文件夹")) {
                    ForEach(Array(listing["entries"].array.enumerated()), id: \.offset) { _, entry in
                        Button { browse(entry["path"].text) } label: { Label(entry["name"].text, systemImage: "folder") }
                    }
                    if listing["entries"].array.isEmpty && !busy && listing != JSON.object([:]) { Text(L("No subfolders", "没有子文件夹")).foregroundStyle(.secondary) }
                    if listing["truncated"].boolean { Text(L("Only some folders are shown. Enter a path to browse further.", "仅显示部分文件夹，请输入路径以继续浏览。" )).font(.caption) }
                }
                Button { showingNewFolder = true } label: { Label(L("New folder", "新建文件夹"), systemImage: "folder.badge.plus") }.disabled(listing["path"].string == nil)
            }
            .disabled(busy)
            .navigationTitle(L("Add workspace", "添加工作区")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Use folder", "使用此文件夹")) {
                        perform { try await store.createWorkspace(path: path); dismiss() }
                    }.disabled(busy || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .task { browse("") }
            .alert(L("New host folder", "新建主机文件夹"), isPresented: $showingNewFolder) {
                TextField(L("Folder name", "文件夹名称"), text: $folderName)
                Button(L("Cancel", "取消"), role: .cancel) {}
                Button(L("Create", "创建")) {
                    let name = folderName; folderName = ""
                    perform {
                        let created = try await store.makeFolder(parent: listing["path"].text, name: name)
                        listing = try await store.folders(path: created["path"].text); path = listing["path"].text
                    }
                }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func browse(_ value: String) {
        perform { listing = try await store.folders(path: value); path = listing["path"].text }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
