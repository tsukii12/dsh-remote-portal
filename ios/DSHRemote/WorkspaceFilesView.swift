import SwiftUI
import Combine
import UIKit

enum WorkspacePathPolicy {
    static func isPrivate(_ path: String) -> Bool {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains { $0.lowercased() == ".dsh" }
    }
}

@MainActor
final class WorkspaceFilesStore: ObservableObject {
    let api: RPCServing
    let sessionID: String
    @Published private(set) var listing: JSON = [:]
    @Published private(set) var path = "."
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published var query = ""
    @Published private(set) var searchResult: JSON = [:]
    @Published private(set) var searching = false
    @Published private(set) var searchError: String?
    @Published private(set) var watchError: String?
    private var generation = 0
    private var searchGeneration = 0
    private var watch: Task<Void, Never>?
    private var reload: Task<Void, Never>?
    private var watchID = UUID()
    var searchActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    init(api: RPCServing, sessionID: String) { self.api = api; self.sessionID = sessionID }
    func start() async {
        if watch == nil {
            let run = UUID(); watchID = run
            watchError = nil
            watch = Task { [weak self, api, sessionID] in
                do {
                    for try await event in api.stream("workspaceFiles/changes", args: ["workspaceFileScopeId": .string(sessionID), "path": "."]) {
                        guard !Task.isCancelled else { return }
                        self?.receiveChange(event)
                    }
                    if !Task.isCancelled { self?.watchError = L("File watching stopped. Pull to refresh.", "文件监视已停止，请下拉刷新。") }
                } catch { if !Task.isCancelled { self?.watchError = error.localizedDescription } }
                if self?.watchID == run { self?.watch = nil }
            }
        }
        await refresh()
    }
    func stop() { generation += 1; searchGeneration += 1; watchID = UUID(); reload?.cancel(); reload = nil; watch?.cancel(); watch = nil }
    func refresh() async {
        await list(path)
        if searchActive { await search(query) }
    }
    func receiveChange(_ event: JSON) {
        guard event["kind"] == "change" || event["type"] == "connection-reset" else { return }
        reload?.cancel()
        reload = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000); try Task.checkCancellation() }
            catch { return }
            await self?.refresh()
        }
    }
    func search(_ query: String) async {
        searchGeneration += 1; let ticket = searchGeneration
        self.query = query; searchResult = [:]; searchError = nil; searching = searchActive
        guard searchActive else { return }
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            let result = try await api.rpc("workspaceFiles/search", args: ["workspaceFileScopeId": .string(sessionID), "request": ["query": .string(query), "excludedPaths": [], "includeHidden": false, "respectGitignore": true]])
            guard ticket == searchGeneration, !Task.isCancelled else { return }
            searchResult = result
            searchResult["matches"] = .array(result["matches"].array.filter { !WorkspacePathPolicy.isPrivate($0["path"].text) })
            searching = false
        } catch {
            guard ticket == searchGeneration, !Task.isCancelled else { return }
            searchError = error.localizedDescription; searching = false
        }
    }
    func list(_ path: String = ".") async {
        generation += 1; let ticket = generation
        self.path = path; loading = true; loaded = false; error = nil; listing = [:]
        guard !WorkspacePathPolicy.isPrivate(path) else {
            error = L("Private dsh files are hidden.", "已隐藏 dsh 私密文件。"); loading = false; return
        }
        do {
            let value = try await api.rpc("workspaceFiles/list", args: ["workspaceFileScopeId": .string(sessionID), "path": .string(path)])
            guard ticket == generation, !Task.isCancelled else { return }
            listing = value
            listing["entries"] = .array(value["entries"].array.filter { !WorkspacePathPolicy.isPrivate(path + "/" + $0["name"].text) })
            loaded = true; loading = false
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
    func child(_ name: String) -> String { let parent = listing["path"].text; return parent.isEmpty ? name : parent + "/" + name }
    var parent: String { let parts = path.split(separator: "/").dropLast(); return parts.isEmpty ? "." : parts.joined(separator: "/") }
    deinit { watch?.cancel(); reload?.cancel() }
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
    private var detectedImage = false
    var isImage: Bool { detectedImage || ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"].contains((path as NSString).pathExtension.lowercased()) }
    init(api: RPCServing, sessionID: String, path: String) { self.api = api; self.sessionID = sessionID; self.path = path }
    func load(reload: Bool = false) async {
        guard !loading else { return }
        guard !WorkspacePathPolicy.isPrivate(path) else { error = L("Private dsh files are hidden.", "已隐藏 dsh 私密文件。"); return }
        if reload { text = ""; imageData = nil; loaded = false; eof = false; nextLine = 1; version = .null; detectedImage = false }
        loading = true; error = nil
        defer { loading = false }
        do {
            var args: JSON = ["workspaceFileScopeId": .string(sessionID), "path": .string(path)]
            if !loaded, !isImage, (path as NSString).pathExtension.isEmpty {
                let probe = try await api.rpc("workspaceFiles/readBytes", args: ["workspaceFileScopeId": .string(sessionID), "path": .string(path), "options": ["range": ["offset": 0, "length": 32]]])
                guard let data = Data(base64Encoded: probe["data"].text) else { throw APIError.invalidResponse }
                detectedImage = Self.hasImageSignature(data)
            }
            if isImage {
                try await loadImage()
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
        } catch APIError.remote(let code, _) where code == "workspace-file/not-text" {
            do { try await loadImage(); loaded = true } catch { self.error = error.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }
    private func loadImage() async throws {
        let value = try await api.rpc("workspaceFiles/readBytes", args: ["workspaceFileScopeId": .string(sessionID), "path": .string(path), "options": [:]])
        guard let data = Data(base64Encoded: value["data"].text), UIImage(data: data) != nil else { throw PortalError.message(L("This file cannot be previewed as text or an image.", "此文件无法作为文本或图片预览。")) }
        detectedImage = true; imageData = data; eof = true
    }
    static func hasImageSignature(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) || data.starts(with: [0xff, 0xd8, 0xff]) || data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) || (data.count >= 12 && data.prefix(4).elementsEqual("RIFF".utf8) && data.dropFirst(8).prefix(4).elementsEqual("WEBP".utf8))
    }
}

struct WorkspaceFilesView: View {
    @StateObject private var store: WorkspaceFilesStore
    @Environment(\.dismiss) private var dismiss
    @State private var previewPath: String?
    private let onMention: ((String) -> Void)?
    init(api: RPCServing, sessionID: String, onMention: ((String) -> Void)? = nil) { _store = StateObject(wrappedValue: WorkspaceFilesStore(api: api, sessionID: sessionID)); self.onMention = onMention }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(store.path == "." ? L("Session workspace", "会话工作区") : store.path).font(.caption.monospaced()).textSelection(.enabled)
                    if store.path != "." { Button { Task { await store.list(store.parent) } } label: { Label(L("Parent folder", "上级文件夹"), systemImage: "arrow.up") } }
                } footer: { Text(L("Read-only. Files are read from this session's host workspace.", "只读：文件来自此会话的主机工作区。")) }
                if store.loading || store.searching { ProgressView(L("Loading files…", "正在加载文件…")) }
                if let error = store.searchActive ? store.searchError : store.error { Section { Text(error).foregroundStyle(.red); Button(L("Retry", "重试")) { Task { await store.refresh() } } } }
                if let error = store.watchError { Text(error).font(.caption).foregroundStyle(.secondary) }
                if store.searchActive && !store.searching && store.searchError == nil && store.searchResult["matches"].array.isEmpty { Text(L("No matching files", "没有匹配的文件")).foregroundStyle(.secondary) }
                if !store.searchActive && store.loaded && store.listing["entries"].array.isEmpty { Text(L("This folder is empty.", "此文件夹为空。")).foregroundStyle(.secondary) }
                ForEach(Array((store.searchActive ? store.searchResult["matches"] : store.listing["entries"]).array.enumerated()), id: \.offset) { _, entry in
                    let path = store.searchActive ? entry["path"].text : store.child(entry["name"].text)
                    HStack {
                      Button {
                        if entry["type"] == "directory" { store.query = ""; Task { await store.list(path) } }
                        else { previewPath = path }
                    } label: {
                        HStack {
                            Label(store.searchActive ? path : entry["name"].text, systemImage: entry["type"] == "directory" ? "folder" : "doc")
                            Spacer()
                            if let size = entry["size"].int { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain).disabled(entry["type"] == "other")
                        if entry["type"] == "file", let onMention {
                            Button { onMention(path) } label: { Image(systemName: "at") }
                                .buttonStyle(.borderless).accessibilityLabel(L("Mention file", "提及文件"))
                                .disabled(FileMentionToken.insertingFile(path, into: "") == nil)
                        }
                    }
                }
                if (store.searchActive ? store.searchResult : store.listing)["truncated"].boolean || store.searchResult["incomplete"].boolean { Text(L("The host limited these results. Narrow your search or open a subfolder.", "主机限制了结果数量，请缩小搜索范围或打开子文件夹。")).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(L("Files", "文件")).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $store.query, prompt: L("Search names or paths", "搜索名称或路径"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done", "完成")) { dismiss() } } }
            .navigationDestination(isPresented: Binding(get: { previewPath != nil }, set: { if !$0 { previewPath = nil } })) {
                if let previewPath { WorkspacePreviewView(api: store.api, sessionID: store.sessionID, path: previewPath, onMention: onMention).id(previewPath) }
            }
            .task { await store.start() }
            .task(id: store.query) { await store.search(store.query) }
            .onDisappear { store.stop() }
            .refreshable { await store.start() }
        }
    }
}

private struct WorkspacePreviewView: View {
    @StateObject private var store: WorkspacePreviewStore
    private let onMention: ((String) -> Void)?
    init(api: RPCServing, sessionID: String, path: String, onMention: ((String) -> Void)? = nil) { _store = StateObject(wrappedValue: WorkspacePreviewStore(api: api, sessionID: sessionID, path: path)); self.onMention = onMention }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let onMention { Button(L("@ Mention", "@ 提及")) { onMention(store.path) }.disabled(FileMentionToken.insertingFile(store.path, into: "") == nil) }
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
