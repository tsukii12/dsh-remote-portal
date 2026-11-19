import SwiftUI

enum InteractionPresentation {
    static func input(_ request: JSON, records: [JSON]) -> String? {
        guard let callID = request["callId"].string, !callID.isEmpty,
              let call = records.map({ $0["event"] }).last(where: { $0["type"] == "tool/call" && $0["data"]["callId"].string == callID }),
              let arguments = call["data"]["arguments"].string else { return nil }
        guard let value = try? JSONDecoder().decode(JSON.self, from: Data(arguments.utf8)) else { return arguments }
        if request["toolName"] == "bash", let command = value["command"].string { return command }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? arguments
    }
    static func reason(_ request: JSON, languages: [String] = Locale.preferredLanguages) -> String {
        let locale = languages.first?.split(separator: "-").first.map(String.init) ?? "en"
        return request["displayReason"][locale].string ?? request["displayReason"]["en"].string ?? request["reason"].text
    }
}

struct QuestionDraft {
    var selected: [String: Set<String>] = [:]
    var custom: [String: String] = [:]
    mutating func toggle(_ option: String, question: JSON) {
        let id = question["id"].text
        if question["multiSelect"].boolean {
            if selected[id, default: []].contains(option) { selected[id]?.remove(option) } else { selected[id, default: []].insert(option) }
        } else { selected[id] = [option]; custom[id] = "" }
    }
    mutating func setCustom(_ text: String, question: JSON) {
        custom[question["id"].text] = text
        if !question["multiSelect"].boolean && !text.isEmpty { selected[question["id"].text] = [] }
    }
    func answers(_ questions: [JSON]) -> [JSON] {
        questions.map { question in
            let id = question["id"].text
            let labels = question["options"].array.map { $0["label"].text }.filter { selected[id, default: []].contains($0) }
            var answer: JSON = ["id": .string(id), "selected": .array(labels.map(JSON.string))]
            let text = custom[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && question["intent"]["kind"] != "approval" { answer["custom"] = .string(text) }
            return answer
        }
    }
    func canSubmit(_ questions: [JSON]) -> Bool { !questions.isEmpty && answers(questions).allSatisfy { !$0["selected"].array.isEmpty || !$0["custom"].text.isEmpty } }
}

@MainActor
final class ApprovalInputLoader: ObservableObject {
    @Published private(set) var input: String?
    @Published var error: String?
    @Published private(set) var isLoading = false
    var canAllow: Bool { !isLoading && input != nil }
    private let api: RPCServing
    private let item: PendingInteraction
    init(api: RPCServing, item: PendingInteraction) { self.api = api; self.item = item }
    func load() async {
        guard !isLoading else { return }
        isLoading = true; input = nil; error = nil
        defer { isLoading = false }
        do {
            let page = try await api.rpc("session/events", args: ["request": ["address": ["kind": "session", "sessionId": .string(item.agentID)], "maxMessages": 50]])
            input = InteractionPresentation.input(item.request, records: page["records"].array)
            if input == nil { error = L("Tool input is unavailable. Retry before allowing this operation.", "无法获取工具输入。请重试后再允许此操作。") }
        } catch { self.error = error.localizedDescription }
    }
}

struct InteractionSheet: View {
    @ObservedObject var events: RemoteEvents
    @StateObject private var inputLoader: ApprovalInputLoader
    let item: PendingInteraction
    let sessionTitle: String
    @State private var draft = QuestionDraft()
    @State private var busy = false
    @State private var error: String?
    init(events: RemoteEvents, api: RPCServing, item: PendingInteraction, sessionTitle: String) {
        self.events = events; self.item = item; self.sessionTitle = sessionTitle
        _inputLoader = StateObject(wrappedValue: ApprovalInputLoader(api: api, item: item))
    }
    private var questions: [JSON] { item.request["questions"].array }
    var body: some View {
        NavigationStack {
            Group {
                if item.kind == "approval/request" { approval }
                else { questionForm }
            }
            .navigationTitle(item.kind == "approval/request" ? L("Permission required", "需要授权") : L("Your input", "请回答"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { if let error = error ?? inputLoader.error { StatusBanner(message: error, dismiss: { self.error = nil; inputLoader.error = nil }) } }
        }
        .presentationDetents(item.kind == "approval/request" ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
        .task(id: item.id) { if item.kind == "approval/request" { await inputLoader.load() } }
    }
    private var approval: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(sessionTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Label(item.request["toolName"].text, systemImage: "terminal").font(.title3.weight(.semibold))
            ScrollView { Text(InteractionPresentation.reason(item.request)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            if let toolInput = inputLoader.input {
                ScrollView([.horizontal, .vertical]) {
                    Text(toolInput).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true).padding(12)
                }.frame(minHeight: 44, maxHeight: 140).background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Button(L("Load tool input", "加载工具输入")) { Task { await inputLoader.load() } }.font(.footnote).disabled(inputLoader.isLoading)
            }
            HStack(spacing: 12) {
                Button(L("Reject", "拒绝")) { answer(allow: false) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button { answer(allow: true) } label: { HStack { if busy { ProgressView() }; Text(L("Allow once", "允许一次")) }.frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(!inputLoader.canAllow)
            }.controlSize(.large).disabled(busy)
        }.padding(24)
    }
    private var questionForm: some View {
        Form {
            Section { Text(sessionTitle).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                Section {
                    Text(question["question"].text).font(.headline)
                    if !question["detail"].text.isEmpty { MarkdownView(text: question["detail"].text) }
                    ForEach(Array(question["options"].array.enumerated()), id: \.offset) { _, option in
                        Button { draft.toggle(option["label"].text, question: question) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: draft.selected[question["id"].text, default: []].contains(option["label"].text) ? "checkmark.circle.fill" : "circle").foregroundStyle(DRPStyle.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option["label"].text).foregroundStyle(.primary)
                                    if !option["description"].text.isEmpty { Text(option["description"].text).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if question["intent"]["kind"] != "approval" {
                        TextField(L("Or write your answer…", "或输入你的回答…"), text: Binding(get: { draft.custom[question["id"].text, default: ""] }, set: { draft.setCustom($0, question: question) }), axis: .vertical).lineLimit(2...5)
                    }
                } header: { Text(question["header"].text) } footer: { if question["multiSelect"].boolean { Text(L("Choose one or more options.", "可选择多个选项。")) } }
            }
            Button { submitQuestions() } label: { HStack { Spacer(); if busy { ProgressView() }; Text(L("Submit answers", "提交回答")); Spacer() } }.disabled(busy || !draft.canSubmit(questions))
        }
    }
    private func answer(allow: Bool) { perform { try await events.answerApproval(item.id, allow: allow) } }
    private func submitQuestions() { perform { try await events.answerQuestions(item.id, answers: draft.answers(questions)) } }
    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task { do { try await action() } catch { self.error = error.localizedDescription }; busy = false }
    }
}
