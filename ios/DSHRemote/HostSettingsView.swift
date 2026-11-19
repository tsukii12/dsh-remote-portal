import SwiftUI
import Combine

@MainActor
final class HostSettingsStore: ObservableObject {
    let api: RPCServing
    @Published private(set) var descriptor: JSON = [:]
    @Published private(set) var catalog: JSON = [:]
    @Published private(set) var permissions: JSON = [:]
    @Published private(set) var status: JSON = [:]
    @Published private(set) var devices: [JSON] = []
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var portalError: String?
    init(api: RPCServing) { self.api = api }
    func namespace(_ name: String) -> JSON { descriptor["namespaces"].array.first { $0["ns"].text == name } ?? .null }
    var defaultModel: JSON { namespace("agent-default-model")["value"] }
    var modelDefinition: JSON { catalog["groups"].array.first { $0["id"] == defaultModel["provider"] }?["models"].array.first { $0["id"] == defaultModel["model"] } ?? .null }
    var defaultPermission: String { namespace("permission")["value"]["defaultPreset"].string ?? permissions["defaultPreset"].text }
    var writable: Bool { loaded && descriptor["writable"].boolean && !busy }
    private func refresh() async throws {
        let descriptor = try await api.rpc("settings/describe", args: [:])
        let catalog = try await api.rpc("session/modelCatalog", args: [:])
        let permissions = try await api.rpc("permissionPresets/catalog", args: [:])
        self.descriptor = descriptor; self.catalog = catalog; self.permissions = permissions; loaded = true
    }
    func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { try await refresh() } catch { self.error = error.localizedDescription }
        await loadPortal()
    }
    func loadPortal() async {
        portalError = nil
        do {
            let response = try await api.portal("status", query: [], body: nil)
            status = response["status"]
            devices = try await api.portal("devices", query: [], body: nil)["devices"].array
        } catch { portalError = error.localizedDescription }
    }
    func mutate(_ ns: String, ops: [JSON]) async throws {
        guard writable, let revision = namespace(ns)["revision"].int else { throw PortalError.message(L("These host settings are read-only or unavailable.", "这些主机设置为只读或不可用。")) }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await api.rpc("settings/mutate", args: ["ns": .string(ns), "ops": .array(ops), "expectedRevision": .int(revision)])
            try await refresh()
        } catch APIError.remote(let code, _) where code == "settings/conflict" {
            try await refresh()
            throw PortalError.message(L("Settings changed in another client. Review the refreshed values and try again.", "设置已被其他客户端更改，请检查刷新后的值并重试。"))
        }
    }
    func setDefaultModel(provider: String, model: String, effort: String?) async throws {
        var ops: [JSON] = [["op": "set", "path": ["provider"], "value": .string(provider)], ["op": "set", "path": ["model"], "value": .string(model)]]
        if let effort { ops.append(["op": "set", "path": ["reasoningEffort"], "value": .string(effort)]) }
        else { ops.append(["op": "unset", "path": ["reasoningEffort"]]) }
        try await mutate("agent-default-model", ops: ops)
    }
    func setDefaultPermission(_ value: String) async throws { try await mutate("permission", ops: [["op": "set", "path": ["defaultPreset"], "value": .string(value)]]) }
    func revoke(_ id: String) async throws {
        guard !busy, !id.isEmpty else { return }
        busy = true; defer { busy = false }
        _ = try await api.portal("devices/revoke", query: [], body: ["id": .string(id)])
        await loadPortal()
    }
}

struct HostSettingsView: View {
    @StateObject private var store: HostSettingsStore
    @State private var error: String?
    @State private var confirmFullAccess = false
    @State private var revoking: JSON?
    @Environment(\.dismiss) private var dismiss
    init(api: RPCServing) { _store = StateObject(wrappedValue: HostSettingsStore(api: api)) }
    var body: some View {
        NavigationStack {
            Form {
                if store.loading || store.busy { ProgressView() }
                if let message = error ?? store.error { Section { Text(message).foregroundStyle(.red); Button(L("Reload settings", "重新加载设置")) { Task { error = nil; await store.load() } } } }
                if store.loaded {
                    Section {
                        NavigationLink {
                            modelPicker
                        } label: { LabeledContent(L("Default model", "默认模型"), value: store.modelDefinition["name"].string ?? store.defaultModel["model"].text) }
                        Picker(L("Thinking effort", "思考强度"), selection: Binding(get: { store.defaultModel["reasoningEffort"].string ?? "__default__" }, set: { effort in
                            perform { try await store.setDefaultModel(provider: store.defaultModel["provider"].text, model: store.defaultModel["model"].text, effort: effort == "__default__" ? nil : effort) }
                        })) {
                            Text(L("Default", "默认")).tag("__default__")
                            ForEach(Array(store.modelDefinition["reasoning"]["efforts"].array.enumerated()), id: \.offset) { _, effort in Text(effort["name"].text).tag(effort["id"].text) }
                        }.disabled(!store.writable || store.namespace("agent-default-model") == .null)
                        Picker(L("Default access", "默认访问权限"), selection: Binding(get: { store.defaultPermission }, set: { value in
                            if value == "danger-full-access" { confirmFullAccess = true }
                            else { perform { try await store.setDefaultPermission(value) } }
                        })) {
                            ForEach(Array(store.permissions["defaultOptions"].array.enumerated()), id: \.offset) { _, option in Text(ChatLabels.permission(option["value"].text)).tag(option["value"].text) }
                        }.disabled(!store.writable || store.namespace("permission") == .null)
                    } header: { Text(L("New conversation defaults", "新对话默认设置")) } footer: { Text(L("Saved on the host, shared with the official UI. Existing conversations keep their own selections.", "保存在主机上，与官方界面共享；已有对话保留各自的选择。")) }
                    Section(L("Providers", "模型提供方")) {
                        ForEach(Array(store.catalog["groups"].array.enumerated()), id: \.offset) { _, group in
                            DisclosureGroup(group["name"].string ?? group["id"].text) {
                                LabeledContent(L("Status", "状态"), value: store.catalog["routableProviders"].array.contains(group["id"]) ? L("Routable", "可路由") : L("Not routable", "不可路由"))
                                ForEach(Array(group["models"].array.enumerated()), id: \.offset) { _, model in Text(model["name"].string ?? model["id"].text).font(.caption) }
                            }
                        }
                        if store.catalog["groups"].array.isEmpty { Text(L("No provider models are available.", "没有可用的提供方模型。")) }
                        ForEach(Array(store.catalog["failures"].array.enumerated()), id: \.offset) { _, failure in Text(failure["message"].string ?? failure["error"]["message"].string ?? failure["provider"].text).foregroundStyle(.red).font(.caption) }
                        Text(L("Status is reported by the host catalog, not a paid generation test. Provider credentials are never displayed or edited here.", "状态来自主机目录，并非付费生成测试；此处不会显示或编辑提供方凭据。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                remoteAccess
            }
            .navigationTitle(L("Settings", "设置")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done", "完成")) { dismiss() } }; ToolbarItem(placement: .primaryAction) { Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(L("Reload settings", "重新加载设置")) } }
            .task { await store.load() }.refreshable { await store.load() }
            .confirmationDialog(L("Default to full access? Future conversations can run commands without normal sandbox restrictions.", "默认使用完全访问？今后的对话将可在常规沙盒限制之外运行命令。"), isPresented: $confirmFullAccess, titleVisibility: .visible) {
                Button(L("Use full access", "使用完全访问"), role: .destructive) { perform { try await store.setDefaultPermission("danger-full-access") } }
            }
            .confirmationDialog(L("Revoke this device? Its sessions will be signed out. If this is your current device, you may lose this connection.", "撤销此设备？其会话将退出登录；如果这是当前设备，你可能会断开连接。"), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
                Button(L("Revoke device", "撤销设备"), role: .destructive) { if let id = revoking?["id"].string { perform { try await store.revoke(id) } }; revoking = nil }
            }
        }
    }
    private var modelPicker: some View {
        List {
            ForEach(Array(store.catalog["groups"].array.enumerated()), id: \.offset) { _, group in
                Section(group["name"].string ?? group["id"].text) {
                    ForEach(Array(group["models"].array.enumerated()), id: \.offset) { _, model in
                        Button {
                            let same = store.defaultModel["provider"] == group["id"] && store.defaultModel["model"] == model["id"]
                            perform { try await store.setDefaultModel(provider: group["id"].text, model: model["id"].text, effort: same ? store.defaultModel["reasoningEffort"].string : model["reasoning"]["defaultEffort"].string) }
                        } label: { HStack { Text(model["name"].string ?? model["id"].text); Spacer(); if store.defaultModel["provider"] == group["id"] && store.defaultModel["model"] == model["id"] { Image(systemName: "checkmark") } } }.disabled(!store.writable || store.namespace("agent-default-model") == .null)
                    }
                }
            }
        }.navigationTitle(L("Default model", "默认模型"))
    }
    private var remoteAccess: some View {
        Section {
            if let error = store.portalError { Text(error).foregroundStyle(.red).font(.caption); Button(L("Retry Portal status", "重试门户状态")) { Task { await store.loadPortal() } } }
            if store.status != .null && !store.status.object.isEmpty {
                LabeledContent(L("Service", "服务"), value: store.status["running"].boolean ? L("Running", "运行中") : L("Stopped", "已停止"))
                LabeledContent(L("Authentication", "认证"), value: store.status["authMode"].text)
                ForEach(store.status["lanUrls"].array.compactMap(\.string), id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                LabeledContent(L("Public access", "公网访问"), value: store.status["public"]["state"].text)
                if let url = store.status["public"]["url"].string, !url.isEmpty { Text(url).font(.caption.monospaced()).textSelection(.enabled) }
                ForEach(Array(store.devices.enumerated()), id: \.offset) { _, device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device["label"].string ?? L("Device", "设备"))
                        Text(device["ip"].text).font(.caption).foregroundStyle(.secondary)
                        if let seen = device["lastSeenAt"].int { Text(Date(timeIntervalSince1970: Double(seen) / 1000), style: .relative).font(.caption).foregroundStyle(.secondary) }
                        Button(L("Revoke device", "撤销设备"), role: .destructive) { revoking = device }.font(.caption).disabled(store.busy)
                    }
                }
                if store.devices.isEmpty { Text(L("No saved devices", "没有已保存设备")).foregroundStyle(.secondary) }
            }
        } header: { Text(L("Remote access & devices", "远程访问与设备")) } footer: { Text(L("Listener, password and relay configuration stay on the host to avoid disconnecting this client. Device revocation requires confirmation.", "监听器、密码和中继配置仍在主机端管理，以免断开当前客户端；撤销设备需要确认。")) }
    }
    private func perform(_ action: @escaping () async throws -> Void) { Task { error = nil; do { try await action() } catch { self.error = error.localizedDescription } } }
}
