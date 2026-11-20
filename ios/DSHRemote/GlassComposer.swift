import SwiftUI

struct GlassComposer: View {
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
    private var preset: String { chat.projections["agentPreset"].string.map(ChatLabels.preset) ?? L("Default", "默认") }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.items.isEmpty { attachmentTray }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if !focused { attachmentButton }
                    field
                    if !focused { trailing }
                }.padding(6)
                if focused {
                    HStack(spacing: 8) {
                        attachmentButton
                        Menu {
                            Button(L("Choose model", "选择模型"), action: onModel)
                            Button(L("Mode & preset", "模式与预设"), action: onMode)
                        } label: {
                            Text(chat.modelName + " · " + preset).font(.caption).lineLimit(1).padding(.horizontal, 12).frame(minHeight: 44).background(.secondary.opacity(0.08), in: Capsule())
                        }.accessibilityIdentifier("modelOptions")
                        Spacer(minLength: 0)
                        trailing
                    }.padding(6)
                }
            }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: focused ? 26 : 32))
                .overlay(RoundedRectangle(cornerRadius: focused ? 26 : 32).stroke(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
            if let error = chat.imageInputError { Text(error).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10) }
        }
    }
    private var attachmentButton: some View {
        ComposerAttachmentsView(store: attachments, limits: chat.projections["imageLimits"], disabled: sending || (!chat.isDraft && !chat.loaded), imageInputError: chat.imageInputError, onError: onError, compact: true)
    }
    @ViewBuilder private var trailing: some View {
        ContextUsageRing(pressure: chat.projections["contextPressure"], action: onUsage)
        if chat.running, let onCancel { GlassCircle(symbol: "stop.fill", label: L("Stop", "停止"), action: onCancel) }
        if !text.isEmpty || !attachments.items.isEmpty {
            Button(action: onSend) {
                Image(systemName: chat.running ? "text.badge.plus" : "arrow.up").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44).background(canSend ? DRPStyle.accent : .gray.opacity(0.4), in: Circle())
            }.disabled(!canSend).accessibilityLabel(chat.running ? L("Queue message", "消息排队") : L("Send", "发送")).accessibilityIdentifier("sendMessage")
        }
    }
    private var field: some View {
        TextField(L("Message DSH…", "给 DSH 发消息…"), text: $text, axis: .vertical).lineLimit(1...6).focused($focused)
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
                    }.font(.caption).padding(.leading, 12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }.disabled(sending)
    }
}
