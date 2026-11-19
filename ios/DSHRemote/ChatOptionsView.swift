import SwiftUI

enum ChatLabels {
    static func permission(_ id: String) -> String {
        switch id {
        case "read-only": return L("Read Only", "只读")
        case "workspace-write": return L("Workspace Write", "工作区写入")
        case "danger-full-access": return L("Full access", "完全访问")
        default: return id
        }
    }
    static func preset(_ id: String) -> String {
        switch id {
        case "standard": return L("Standard", "标准")
        case "ptc": return L("PTC", "PTC")
        case "minimal": return L("Minimal", "精简")
        case "cordis": return L("Creator", "创造者")
        default: return id
        }
    }
}

struct ChatOptionsView: View {
    @ObservedObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var confirmAccess = false
    var body: some View {
        NavigationStack {
            List {
                if let error { StatusBanner(message: error, dismiss: { self.error = nil }) }
                ForEach(Array(chat.catalog["groups"].array.enumerated()), id: \.offset) { _, group in
                    Section(group["name"].text) {
                        ForEach(Array(group["models"].array.enumerated()), id: \.offset) { _, model in
                            Button { perform { try await chat.selectModel(provider: group["id"].text, model: model["id"].text) } } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model["name"].string ?? model["id"].text)
                                        if let description = model["description"].string { Text(description).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if chat.currentModel["provider"] == group["id"] && chat.currentModel["model"] == model["id"] { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                if chat.catalog["groups"].array.isEmpty { Text(L("No models available", "没有可用模型")) }
                ForEach(Array(chat.catalog["failures"].array.enumerated()), id: \.offset) { _, failure in
                    Text(failure["message"].string ?? failure["error"]["message"].string ?? failure["provider"].text).font(.caption).foregroundStyle(.red)
                }
                if !chat.modelDefinition["reasoning"]["efforts"].array.isEmpty {
                    Section(L("Thinking effort", "思考强度")) {
                        Button { selectEffort(nil) } label: { checked(L("Default", "默认"), chat.currentModel["reasoningEffort"] == .null) }
                        ForEach(Array(chat.modelDefinition["reasoning"]["efforts"].array.enumerated()), id: \.offset) { _, effort in
                            Button { selectEffort(effort["id"].text) } label: { checked(effort["name"].text, effort["id"] == chat.currentModel["reasoningEffort"]) }
                        }
                    }
                }
                Section {
                    ForEach(Array(chat.permissionCatalog["options"].array.enumerated()), id: \.offset) { _, option in
                        let id = option["value"].text
                        Button {
                            if id == "danger-full-access" { confirmAccess = true }
                            else { perform { try await chat.selectPermission(id) } }
                        } label: { checked(ChatLabels.permission(id), chat.projections["permissions"]["currentValue"].text == id) }
                    }
                } header: { Text(L("Access mode", "访问模式")) } footer: { Text(L("Applies to this session, not the default for new sessions.", "仅适用于当前会话，不影响新会话的默认设置。")) }
                Section {
                    Button { perform { try await chat.executeCommand(chat.planEnabled ? "/plan off" : "/plan") } } label: {
                        checked(L("Plan mode", "计划模式"), chat.planEnabled)
                    }.disabled(chat.projections["plan"]["pending"].boolean)
                    ForEach(Array(chat.presetCatalog["presets"].array.enumerated()), id: \.offset) { _, preset in
                        Button { perform { try await chat.selectPreset(preset["id"].text) } } label: {
                            checked(ChatLabels.preset(preset["id"].text), chat.projections["agentPreset"] == preset["id"])
                        }.disabled(chat.sessionStarted || preset["broken"].string != nil)
                    }
                } header: { Text(L("Plan & agent preset", "计划与代理预设")) } footer: { Text(L("Choose the agent preset before the first message. Plan mode can be changed later.", "请在第一条消息前选择代理预设。计划模式可稍后切换。")) }
                Button(L("Refresh options", "刷新选项")) { perform { try await chat.loadModels(); try await chat.loadControls() } }
            }
            .buttonStyle(.plain).disabled(busy)
            .navigationTitle(L("Chat options", "聊天选项")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } } }
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .confirmationDialog(L("Allow full host access?", "允许完全访问主机？"), isPresented: $confirmAccess, titleVisibility: .visible) {
                Button(L("Full access", "完全访问"), role: .destructive) { perform { try await chat.selectPermission("danger-full-access") } }
            } message: { Text(L("Tools may run outside the workspace without the usual sandbox restrictions.", "工具可在工作区之外运行，不受通常的沙箱限制。")) }
        }
    }
    private func checked(_ label: String, _ selected: Bool) -> some View {
        HStack { Text(label); Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(DRPStyle.accent) } }
    }
    private func selectEffort(_ effort: String?) {
        perform { try await chat.selectModel(provider: chat.currentModel["provider"].text, model: chat.currentModel["model"].text, reasoningEffort: effort, useDefaultEffort: effort == nil) }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
