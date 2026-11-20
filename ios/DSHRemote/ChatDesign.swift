import SwiftUI

struct ChatBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: scheme == .dark ? [Color(red: 0.08, green: 0.13, blue: 0.24), Color(red: 0.07, green: 0.08, blue: 0.13)] : [Color(red: 0.84, green: 0.89, blue: 1), Color(red: 0.95, green: 0.95, blue: 0.98)], startPoint: .topTrailing, endPoint: .bottomLeading).ignoresSafeArea()
    }
}

struct GlassCircle: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.title3).frame(width: 44, height: 44).background(.regularMaterial, in: Circle()).overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1)).shadow(color: .black.opacity(0.06), radius: 10, y: 5) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct ChatTitlePill: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.bold()).lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.horizontal, 15).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
    }
}

struct PixelWhale: View {
    private let pixels = ["                    bb  ", "                   bB b ", "    bbbbbbbb       bBbb ", "  bbBBBBBBBBbb     bBb  ", " bBBBBBBBBBBBBb   bBb   ", "bBBBBBBBBBBBBBBbbbBb    ", "bBBbBBBBBBBBbBBBBBb     ", "bBBbBBBBBBBBbBBBBBb     ", " bBBBBBWWWWBBBBBBb      ", " bBBWWWWWWWWBBBBb       ", "  bWWWWWWWWWWWbb        ", "   bbbbbbbbbbb          "]
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 24, size.height / 12)
            for (y, row) in pixels.enumerated() {
                for (x, pixel) in row.enumerated() where pixel != " " {
                    let color: Color = pixel == "W" ? .white : pixel == "B" ? Color(red: 0.3, green: 0.45, blue: 0.95) : Color(red: 0.12, green: 0.2, blue: 0.48)
                    context.fill(Path(CGRect(x: Double(x) * scale, y: Double(y) * scale, width: scale, height: scale)), with: .color(color))
                }
            }
        }.frame(width: 64, height: 32).accessibilityHidden(true)
    }
}

struct ContextUsageRing: View {
    let pressure: JSON
    let action: () -> Void
    var body: some View {
        let percent = UsagePresentation.context(pressure)?.percent
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.18), lineWidth: 3)
                    Circle().trim(from: 0, to: Double(percent ?? 0) / 100).stroke(DRPStyle.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                }.frame(width: 17, height: 17)
                Text(percent.map { "\($0)%" } ?? "—").font(.caption).monospacedDigit()
            }.frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel(L("Context usage", "上下文用量")).accessibilityValue(percent.map { "\($0)%" } ?? L("Unavailable", "暂无数据"))
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
    var outcome: String? { items.flatMap(\.blocks).first { $0.kind == "turn/end" }?.raw["event"]["data"]["reason"]["kind"].string }
    var detailItems: [TranscriptItem] { items.filter { !Self.visibleFinal($0, finalID: final?.id) } }
    var final: TranscriptItem? { items.last { $0.role == "assistant" && $0.blocks.contains { ["text", "image", "file"].contains($0.kind) } } }
    private static func visibleFinal(_ item: TranscriptItem, finalID: String?) -> Bool { item.role == "user" || item.id == finalID }
    static func group(_ items: [TranscriptItem]) -> [TranscriptTurn] {
        var groups: [TranscriptTurn] = []
        for item in items {
            if let index = groups.indices.last {
                let previousTurn = groups[index].items.compactMap(\.turn).last
                let newTurn = item.turn != nil && previousTurn != nil && item.turn != previousTurn
                let newUser = item.role == "user" && groups[index].items.contains { $0.role == "user" || $0.role == "assistant" }
                if !newTurn && !newUser { groups[index].items.append(item); continue }
            }
            groups.append(TranscriptTurn(id: item.id, items: [item]))
        }
        return groups
    }
}
