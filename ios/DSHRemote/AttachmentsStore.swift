import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

struct DraftAttachment: Identifiable {
    let id: UUID
    let file: URL
    let name: String
    let mediaType: String?
    let bytes: Int
    var receipt: JSON = [:]
    var error: String?
    var uploading = true
    var ready: Bool { !uploading && error == nil && receipt["receiptId"].string != nil }
    var content: JSON { ["type": "file", "receiptId": receipt["receiptId"]] }
    var reference: JSON { ["type": mediaType == nil ? "file" : "image", "attachment": receipt[mediaType == nil ? "file" : "image"]] }
}

private final class DraftUploadFiles {
    var folders = Set<URL>()
    deinit { for folder in folders { try? FileManager.default.removeItem(at: folder) } }
}

@MainActor
final class AttachmentsStore: ObservableObject {
    @Published private(set) var items: [DraftAttachment] = []
    private let api: RPCServing
    private let sessionID: String
    private let directory: URL
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let storage = DraftUploadFiles()
    var ready: Bool { items.allSatisfy(\.ready) }
    init(api: RPCServing, sessionID: String, directory: URL? = nil) {
        self.api = api; self.sessionID = sessionID
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ComposerUploads", isDirectory: true)
    }
    func add(file source: URL, name: String? = nil, mediaType: String? = nil, limits: JSON) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try validate(bytes: bytes, mediaType: mediaType, limits: limits)
        if mediaType != nil {
            guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw PortalError.message(L("This image could not be read.", "无法读取此图片。"))
            }
            if let cap = limits["maxImageDimension"].int, max(width, height) > cap { throw PortalError.message(L("Image dimensions exceed the host limit.", "图片尺寸超出主机限制。")) }
            if let pixels = limits["maxImagePixels"].int, Double(width) * Double(height) > Double(pixels) { throw PortalError.message(L("Image resolution exceeds the host limit.", "图片分辨率超出主机限制。")) }
        }
        let id = UUID()
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let displayName = name ?? source.lastPathComponent
        let file = folder.appendingPathComponent((displayName as NSString).lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: file) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        storage.folders.insert(folder)
        items.append(DraftAttachment(id: id, file: file, name: displayName, mediaType: mediaType, bytes: bytes))
        retry(id)
    }
    func validate(bytes: Int, mediaType: String?, limits: JSON) throws {
        guard let mediaType else { return }
        guard limits["mediaTypes"].array.contains(.string(mediaType)) else { throw PortalError.message(L("This image format is not supported by the host.", "主机不支持此图片格式。")) }
        let images = items.filter { $0.mediaType != nil }
        if let count = limits["maxImagesPerMessage"].int, images.count + 1 > count { throw PortalError.message(L("Too many images for one message.", "单条消息中的图片过多。")) }
        if let cap = limits["maxImageBytes"].int, bytes > cap { throw PortalError.message(L("Image exceeds the host's per-image limit: ", "图片超出主机单张大小限制：") + ByteCountFormatter.string(fromByteCount: Int64(cap), countStyle: .file)) }
        if let cap = limits["maxMessageImageBytes"].int, images.reduce(bytes, { $0 + $1.bytes }) > cap { throw PortalError.message(L("Images exceed the host's total message limit.", "图片总大小超出主机单条消息限制。")) }
    }
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        tasks[id]?.cancel(); items[index].uploading = true; items[index].error = nil; items[index].receipt = [:]
        let item = items[index]
        tasks[id] = Task { [weak self, api, sessionID] in
            do {
                let value = try await api.upload(sessionID: sessionID, file: item.file, name: item.name, mediaType: item.mediaType)
                guard !Task.isCancelled, let self, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[index].receipt = value; self.items[index].uploading = false; self.tasks[id] = nil
            } catch {
                guard !Task.isCancelled, let self, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[index].error = error.localizedDescription; self.items[index].uploading = false; self.tasks[id] = nil
            }
        }
    }
    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        if let item = items.first(where: { $0.id == id }) {
            let folder = item.file.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: folder); storage.folders.remove(folder)
        }
        items.removeAll { $0.id == id }
    }
    func clear() { for id in items.map(\.id) { remove(id) } }
    deinit { tasks.values.forEach { $0.cancel() } }
}
