import SwiftUI
import PhotosUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct ComposerAttachmentsView: View {
    @ObservedObject var store: AttachmentsStore
    let limits: JSON
    let disabled: Bool
    let imageInputError: String?
    let onError: (String) -> Void
    var compact = false
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var showingFiles = false
    @State private var photo: PhotosPickerItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.items.isEmpty && !compact {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: item.mediaType == nil ? "doc" : "photo")
                                    Text(item.name).lineLimit(1)
                                    if item.uploading { ProgressView().controlSize(.mini) }
                                    Button { store.remove(item.id) } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(L("Remove attachment", "移除附件"))
                                }
                                if let error = item.error {
                                    Text(error).foregroundStyle(.red).lineLimit(2)
                                    Button(L("Retry upload", "重试上传")) { store.retry(item.id) }
                                } else {
                                    Text(item.uploading ? L("Uploading · ", "正在上传 · ") + "\(item.sentBytes) / \(item.bytes) " + L("bytes", "字节") : (item.ready ? L("Ready · ", "就绪 · ") : L("Upload on send · ", "发送时上传 · ")) + ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).foregroundStyle(.secondary)
                                }
                            }.font(.caption).frame(maxWidth: 240, alignment: .leading).padding(8).background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.disabled(disabled)
            }
            Menu {
                Button { showingPhotos = true } label: { Label(L("Photos", "照片"), systemImage: "photo.on.rectangle") }.disabled(imageInputError != nil)
                Button { showingCamera = true } label: { Label(L("Camera", "相机"), systemImage: "camera") }.disabled(imageInputError != nil || !UIImagePickerController.isSourceTypeAvailable(.camera))
                Button { showingFiles = true } label: { Label(L("Files", "文件"), systemImage: "folder") }
            } label: {
                if compact { Image(systemName: "plus").font(.title2).frame(width: 44, height: 44) }
                else { Label(L("Attach", "添加附件"), systemImage: "paperclip").font(.subheadline.weight(.medium)).frame(minHeight: 44) }
            }.disabled(disabled).accessibilityIdentifier("attachFiles").accessibilityLabel(L("Add attachment", "添加附件"))
            if let imageInputError, !compact { Text(imageInputError).font(.caption2).foregroundStyle(.secondary) }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photo, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw PortalError.message(L("The photo could not be loaded.", "无法加载照片。")) }
                    try addImage(data)
                } catch { onError(error.localizedDescription) }
                photo = nil
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() {
                    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    let mediaType = (limits["mediaTypes"] == .null && type?.hasPrefix("image/") == true) || limits["mediaTypes"].array.contains(.string(type ?? "")) ? type : nil
                    if type?.hasPrefix("image/") == true, let imageInputError { throw PortalError.message(imageInputError) }
                    try store.add(file: url, mediaType: mediaType, limits: limits)
                }
            } catch { onError(error.localizedDescription) }
        }
        .sheet(isPresented: $showingCamera) {
            CameraCapture { image in
                showingCamera = false
                guard let image else { return }
                do {
                    guard let data = image.jpegData(compressionQuality: 0.9) else { throw APIError.invalidResponse }
                    try addImage(data)
                } catch { onError(error.localizedDescription) }
            }.ignoresSafeArea()
        }
    }
    private func addImage(_ original: Data) throws {
        if let imageInputError { throw PortalError.message(imageInputError) }
        var data = original
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let identifier = CGImageSourceGetType(source) else { throw PortalError.message(L("This image could not be read.", "无法读取此图片。")) }
        var type = UTType(identifier as String)
        if !limits["mediaTypes"].array.contains(.string(type?.preferredMIMEType ?? "")) {
            guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) else { throw APIError.invalidResponse }
            data = jpeg; type = .jpeg
        }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PickedPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(type?.preferredFilenameExtension ?? "jpg")
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: file) }
        try store.add(file: file, name: L("Photo", "照片") + "." + file.pathExtension, mediaType: type?.preferredMIMEType, limits: limits)
    }
}

private struct CameraCapture: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.cameraCaptureMode = .photo; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(_ completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion(info[.originalImage] as? UIImage) }
    }
}

private struct AttachmentViewportHeight: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var attachmentViewportHeight: CGFloat {
        get { self[AttachmentViewportHeight.self] }
        set { self[AttachmentViewportHeight.self] = newValue }
    }
}

struct HistoricalAttachmentView: View {
    let block: TranscriptBlock
    let api: RPCServing
    let sessionID: String
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = false
    @State private var visible = false
    @Environment(\.attachmentViewportHeight) private var viewportHeight
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(block.attachment["name"].string ?? L("Image", "图片"), systemImage: block.kind == "image" ? "photo" : "doc")
                .font(.caption).textSelection(.enabled)
            if let bytes = block.attachment["bytes"].int { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 260).accessibilityLabel(block.attachment["name"].string ?? L("Attached image", "附加图片")) }
            else if block.kind == "image" {
                if loading || error == nil { ProgressView().frame(width: 160, height: 120).accessibilityLabel(L("Loading image", "正在加载图片")) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if error != nil { Button(L("Retry image", "重试图片")) { Task { await load() } }.frame(minHeight: 44).disabled(loading) }
            }
        }.padding(10).background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
            .onGeometryChange(for: Bool.self) { proxy in
                let frame = proxy.frame(in: .named("chatScroll"))
                return viewportHeight > 0 && frame.maxY > 0 && frame.minY < viewportHeight
            } action: { visible = $0 }
            .task(id: visible) { if visible && block.kind == "image" && image == nil && error == nil { await load() } }
            .onDisappear { image = nil }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let loaded = try await AttachmentReader.image(api: api, sessionID: sessionID, reference: block.attachment)
            try Task.checkCancellation()
            image = loaded
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
enum AttachmentReader {
    static let thumbnailPixelLimit = 640
    static let maximumBytes = 20 * 1024 * 1024
    static func image(api: RPCServing, sessionID: String, reference: JSON) async throws -> UIImage {
        guard (reference["bytes"].int ?? 0) <= maximumBytes else { throw PortalError.message(L("Image is too large to preview.", "图片过大，无法预览。")) }
        let value = try await api.rpc("session/attachment", args: ["request": ["sessionId": .string(sessionID), "attachment": reference]])
        let encoded = value["data"].text
        guard encoded.utf8.count <= (maximumBytes + 2) / 3 * 4, let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= maximumBytes else { throw APIError.invalidResponse }
        let pixelLimit = thumbnailPixelLimit
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixelLimit, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw APIError.invalidResponse }
            return UIImage(cgImage: thumbnail)
        }.value
    }
}
