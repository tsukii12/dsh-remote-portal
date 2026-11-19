import SwiftUI
import Combine
import UIKit

@MainActor
final class WorkspaceFilesStore: ObservableObject {
    let api: RPCServing
    let sessionID: String
    @Published private(set) var listing: JSON = [:]
    @Published private(set) var path = "."
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    private var generation = 0
    init(api: RPCServing, sessionID: String) { self.api = api; self.sessionID = sessionID }
    func list(_ path: String = ".") async {
        generation += 1; let ticket = generation
        self.path = path; loading = true; loaded = false; error = nil; listing = [:]
        do {
            let value = try await api.rpc("workspaceFiles/list", args: ["workspaceFileScopeId": .string(sessionID), "path": .string(path)])
            guard ticket == generation, !Task.isCancelled else { return }
            listing = value; loaded = true; loading = false
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
    func child(_ name: String) -> String { let parent = listing["path"].text; return parent.isEmpty ? name : parent + "/" + name }
    var parent: String { let parts = path.split(separator: "/").dropLast(); return parts.isEmpty ? "." : parts.joined(separator: "/") }
}

@MainActor
final class WorkspacePreviewStore: ObservableObject {
    let api: RPCServing
    let sessionID: String
    let path: String
    @Published private(set) var text = ""
    @Published private(set) var imageData: Data?
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var eof = false
    @Published private(set) var error: String?
    private var nextLine = 1
    private var version: JSON = .null
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"].contains((path as NSString).pathExtension.lowercased()) }
    init(api: RPCServing, sessionID: String, path: String) { self.api = api; self.sessionID = sessionID; self.path = path }
    func load(reload: Bool = false) async {
        guard !loading else { return }
        if reload { text = ""; imageData = nil; loaded = false; eof = false; nextLine = 1; version = .null }
        loading = true; error = nil
        defer { loading = false }
        do {
            var args: JSON = ["workspaceFileScopeId": .string(sessionID), "path": .string(path)]
            if isImage {
                args["options"] = [:]
                let value = try await api.rpc("workspaceFiles/readBytes", args: args)
                guard let data = Data(base64Encoded: value["data"].text), UIImage(data: data) != nil else { throw PortalError.message(L("This image format cannot be previewed.", "无法预览此图片格式。")) }
                imageData = data; eof = true
            } else {
                args["range"] = ["offset": .int(nextLine), "limit": 200]
                let value = try await api.rpc("workspaceFiles/read", args: args)
                guard let page = value["text"].string, let lines = value["lines"].int, lines >= 0 else { throw APIError.invalidResponse }
                guard version == .null || version == value["version"] else { throw PortalError.message(L("The file changed. Reload it before continuing.", "文件已更改，请重新加载后继续。")) }
                version = value["version"]
                text += (nextLine > 1 && lines > 0 ? "\n" : "") + page
                nextLine += lines; eof = value["eof"].boolean
                if lines == 0 && !eof { throw APIError.invalidResponse }
            }
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
}

struct WorkspaceFilesView: View {
    @StateObject private var store: WorkspaceFilesStore
    @Environment(\.dismiss) private var dismiss
    @State private var previewPath: String?
    init(api: RPCServing, sessionID: String) { _store = StateObject(wrappedValue: WorkspaceFilesStore(api: api, sessionID: sessionID)) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(store.path == "." ? L("Session workspace", "会话工作区") : store.path).font(.caption.monospaced()).textSelection(.enabled)
                    if store.path != "." { Button { Task { await store.list(store.parent) } } label: { Label(L("Parent folder", "上级文件夹"), systemImage: "arrow.up") } }
                } footer: { Text(L("Read-only. Files are read from this session's host workspace.", "只读：文件来自此会话的主机工作区。")) }
                if store.loading { ProgressView(L("Loading files…", "正在加载文件…")) }
                if let error = store.error { Section { Text(error).foregroundStyle(.red); Button(L("Retry", "重试")) { Task { await store.list(store.path) } } } }
                if store.loaded && store.listing["entries"].array.isEmpty { Text(L("This folder is empty.", "此文件夹为空。")).foregroundStyle(.secondary) }
                ForEach(Array(store.listing["entries"].array.enumerated()), id: \.offset) { _, entry in
                    Button {
                        let path = store.child(entry["name"].text)
                        if entry["type"] == "directory" { Task { await store.list(path) } }
                        else { previewPath = path }
                    } label: {
                        HStack {
                            Label(entry["name"].text, systemImage: entry["type"] == "directory" ? "folder" : "doc")
                            Spacer()
                            if let size = entry["size"].int { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(entry["type"] == "other")
                }
                if store.listing["truncated"].boolean { Text(L("The host limited this directory listing. Open a subfolder to see more.", "主机限制了此目录的列表数量，请打开子文件夹查看更多内容。")).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(L("Files", "文件")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done", "完成")) { dismiss() } } }
            .navigationDestination(isPresented: Binding(get: { previewPath != nil }, set: { if !$0 { previewPath = nil } })) {
                if let previewPath { WorkspacePreviewView(api: store.api, sessionID: store.sessionID, path: previewPath).id(previewPath) }
            }
            .task { await store.list() }
            .refreshable { await store.list(store.path) }
        }
    }
}

private struct WorkspacePreviewView: View {
    @StateObject private var store: WorkspacePreviewStore
    init(api: RPCServing, sessionID: String, path: String) { _store = StateObject(wrappedValue: WorkspacePreviewStore(api: api, sessionID: sessionID, path: path)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let data = store.imageData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(store.path) }
                else if !store.text.isEmpty {
                    ScrollView(.horizontal) { Text(store.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(12) }
                        .background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 8))
                } else if store.loaded { Text(L("Empty file", "空文件")).foregroundStyle(.secondary) }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.red); Button(L("Reload file", "重新加载文件")) { Task { await store.load(reload: true) } } }
                if store.loading { ProgressView(L("Loading preview…", "正在加载预览…")) }
                else if store.loaded && !store.eof { Button(L("Load more lines", "加载更多行")) { Task { await store.load() } } }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle((store.path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { Task { await store.load(reload: true) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(L("Reload file", "重新加载文件")) }
            .task { await store.load() }
    }
}
