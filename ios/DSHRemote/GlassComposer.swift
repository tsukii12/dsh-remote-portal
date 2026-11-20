import SwiftUI

struct ChatComposer: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var attachments: AttachmentsStore
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    let sending: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onError: (String) -> Void
    let onModel: () -> Void
    let onMode: () -> Void
    let onUsage: () -> Void
    var onCancel: (() -> Void)?
    var onAccess: (() -> Void)?
    var steering: Binding<Bool>?
    private var preset: String { chat.projections["agentPreset"].string.map(ChatLabels.preset) ?? L("Default", "默认") }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.items.isEmpty { attachmentTray }
            HStack(alignment: .bottom, spacing: 8) {
                attachmentButton
                field
                if chat.running, let onCancel {
                    Button(action: onCancel) { Image(systemName: "stop.fill").frame(width: 44, height: 44) }.accessibilityLabel(L("Stop", "停止"))
                }
                Button(action: onSend) { Image(systemName: chat.running ? "text.badge.plus" : "paperplane.fill").frame(width: 44, height: 44) }
                    .disabled(!canSend).accessibilityLabel(chat.running ? L("Queue message", "消息排队") : L("Send", "发送")).accessibilityIdentifier("sendMessage")
            }
            HStack(spacing: 8) {
                if let onAccess {
                    Button(action: onAccess) { Label(ChatLabels.permission(chat.projections["permissions"]["currentValue"].text), systemImage: "checkmark.shield").font(.caption).lineLimit(1).frame(minHeight: 44) }
                }
                Spacer(minLength: 0)
                Menu {
                    Button(L("Choose model", "选择模型"), action: onModel)
                    Button(L("Mode & preset", "模式与预设"), action: onMode)
                    Button(L("Usage", "用量"), action: onUsage)
                    if chat.running, let steering { Toggle(L("Steer immediately instead of queue", "立即引导而不是排队"), isOn: steering) }
                } label: { Label(chat.modelName + " · " + preset, systemImage: "slider.horizontal.3").font(.caption).lineLimit(1).frame(minHeight: 44) }
                    .accessibilityIdentifier("modelOptions")
            }
            if let error = chat.imageInputError { Text(error).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10) }
        }.background(Color(uiColor: .systemBackground))
    }
    private var attachmentButton: some View {
        ComposerAttachmentsView(store: attachments, limits: chat.projections["imageLimits"], disabled: sending || (!chat.isDraft && !chat.loaded), imageInputError: chat.imageInputError, onError: onError, compact: true)
    }
    private var field: some View {
        TextField(L("Message DSH…", "给 DSH 发消息…"), text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...6).focused($focused)
            .textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 44).accessibilityIdentifier("chatComposer")
    }
    private var attachmentTray: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(attachments.items) { (item: DraftAttachment) in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).lineLimit(1)
                            Text(item.error ?? (item.uploading ? "\(item.sentBytes) / \(item.bytes) " + L("bytes", "字节") : item.ready ? L("Ready", "就绪") : L("Upload on send", "发送时上传"))).font(.caption2).foregroundStyle(item.error == nil ? Color.secondary : Color.red).lineLimit(2)
                        }.frame(maxWidth: 180, alignment: .leading)
                        if item.uploading { ProgressView().controlSize(.mini) }
                        if item.error != nil { Button { attachments.retry(item.id) } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel(L("Retry upload", "重试上传")) }
                        Button { attachments.remove(item.id) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel(L("Remove attachment", "移除附件"))
                    }.font(.caption).padding(.leading, 12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.disabled(sending)
    }
}
