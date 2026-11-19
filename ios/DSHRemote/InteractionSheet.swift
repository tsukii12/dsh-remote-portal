import SwiftUI

enum InteractionPresentation {
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

struct InteractionSheet: View {
    @ObservedObject var events: RemoteEvents
    let item: PendingInteraction
    let sessionTitle: String
    @State private var draft = QuestionDraft()
    @State private var busy = false
    @State private var error: String?
    private var questions: [JSON] { item.request["questions"].array }
    var body: some View {
        NavigationStack {
            Group {
                if item.kind == "approval/request" { approval }
                else { questionForm }
            }
            .navigationTitle(item.kind == "approval/request" ? L("Permission required", "需要授权") : L("Your input", "请回答"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { if let error { StatusBanner(message: error, dismiss: { self.error = nil }) } }
        }
        .presentationDetents(item.kind == "approval/request" ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
    }
    private var approval: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(sessionTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Label(item.request["toolName"].text, systemImage: "terminal").font(.title3.weight(.semibold))
            ScrollView { Text(InteractionPresentation.reason(item.request)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack(spacing: 12) {
                Button(L("Reject", "拒绝")) { answer(allow: false) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button { answer(allow: true) } label: { HStack { if busy { ProgressView() }; Text(L("Allow once", "允许一次")) }.frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
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
