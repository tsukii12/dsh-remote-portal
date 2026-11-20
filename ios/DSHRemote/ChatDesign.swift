import SwiftUI

struct ChatNavigationTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}

enum ChatGreeting {
    static func text(hour: Int) -> String {
        if (5..<12).contains(hour) { return L("Good morning", "早上好") }
        if (12..<18).contains(hour) { return L("Good afternoon", "下午好") }
        return L("Good evening", "晚上好")
    }
}

struct TranscriptTurn: Identifiable {
    let id: String
    var items: [TranscriptItem]
    var toolCount: Int { items.flatMap(\.blocks).filter { $0.kind == "tool-call" }.count }
    var messageCount: Int { items.filter { $0.role == "assistant" || $0.role == "user" }.count }
    var countsLabel: String { L(" · \(toolCount) tool \(toolCount == 1 ? "call" : "calls") · \(messageCount) \(messageCount == 1 ? "message" : "messages")", " · \(toolCount) 次工具调用 · \(messageCount) 条消息") }
    var outcome: String? { items.compactMap(\.turnOutcome).last }
    var canCollapse: Bool {
        guard outcome == "completed", let first = items.firstIndex(where: { $0.role == "assistant" || $0.role == "tool" }) else { return false }
        return !items.dropFirst(first + 1).contains { $0.role == "user" }
    }
    func independent(_ item: TranscriptItem) -> Bool {
        if item.role == "user" || item.role == "trigger" { return true }
        if item.role == "command" { return item.turn == nil }
        return item.role == "notice" && item.blocks.contains { ["system-notice", "compaction"].contains($0.kind) }
    }
    var detailItems: [TranscriptItem] { items.filter { $0.role != "notice" && !Self.visibleFinal($0, finalID: final?.id) } }
    var final: TranscriptItem? { items.last { $0.role == "assistant" && $0.blocks.contains { ["text", "image", "file"].contains($0.kind) } } }
    private static func visibleFinal(_ item: TranscriptItem, finalID: String?) -> Bool { item.role == "user" || item.id == finalID }
    static func group(_ items: [TranscriptItem]) -> [TranscriptTurn] {
        var groups: [TranscriptTurn] = []
        for item in items {
            if let index = groups.indices.last {
                let previousTurn = groups[index].items.compactMap(\.turn).last
                let newTurn = item.turn != nil && previousTurn != nil && item.turn != previousTurn
                let newUser = item.role == "user" && !item.steering && (item.turn == nil || previousTurn == nil) && groups[index].items.contains { $0.role == "user" || $0.role == "assistant" }
                if !newTurn && !newUser { groups[index].items.append(item); continue }
            }
            groups.append(TranscriptTurn(id: item.id, items: [item]))
        }
        return groups
    }
}
