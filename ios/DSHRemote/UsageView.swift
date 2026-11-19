import SwiftUI

enum UsagePresentation {
    static let buckets = ["uncachedInputTokens", "cacheReadTokens", "cacheWriteTokens", "outputTokens"]
    static func total(_ usage: JSON) -> Int? {
        var total = 0
        for key in buckets {
            guard let count = usage[key].int, count >= 0 else { return nil }
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { return nil }; total = sum.partialValue
        }
        return total
    }
    static func context(_ pressure: JSON) -> (used: Int, capacity: Int, percent: Int)? {
        guard let used = pressure["projectedTokens"].int ?? pressure["pressureTokens"].int, used >= 0,
              let capacity = pressure["contextWindow"].int, capacity > 0 else { return nil }
        return (used, capacity, min(100, Int((min(Double(used) / Double(capacity), 1) * 100).rounded())))
    }
}

struct UsageView: View {
    let usage: JSON
    let pressure: JSON
    @State private var expanded = false
    var body: some View {
        if UsagePresentation.total(usage) != nil || UsagePresentation.context(pressure) != nil {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if let context = UsagePresentation.context(pressure) {
                        ProgressView(value: min(Double(context.used) / Double(context.capacity), 1))
                        Text(L("Approximate next-request context: ", "预计下次请求的上下文：") + "~\(context.used.formatted()) / \(context.capacity.formatted()) tok").foregroundStyle(.secondary)
                    }
                    if let total = UsagePresentation.total(usage) {
                        LabeledContent(L("Session tokens", "会话令牌"), value: total.formatted())
                        LabeledContent(L("Uncached input", "未缓存输入"), value: usage["uncachedInputTokens"].int!.formatted())
                        LabeledContent(L("Cache read", "缓存读取"), value: usage["cacheReadTokens"].int!.formatted())
                        LabeledContent(L("Cache write", "缓存写入"), value: usage["cacheWriteTokens"].int!.formatted())
                        LabeledContent(L("Output (includes reasoning)", "输出（含推理）"), value: usage["outputTokens"].int!.formatted())
                    }
                    Text(L("Provider-reported tokens, not monetary cost. Context is an estimate and may lag model changes.", "令牌数由提供方报告，并非金额；上下文为估算值，切换模型后可能暂时滞后。")).foregroundStyle(.secondary)
                }.padding(.top, 6).textSelection(.enabled)
            } label: {
                HStack(spacing: 10) {
                    if let context = UsagePresentation.context(pressure) { Label(L("Context ", "上下文 ") + "\(context.percent)%", systemImage: "chart.pie") }
                    if let total = UsagePresentation.total(usage) { Text(L("Usage ", "用量 ") + "\(total.formatted()) tok") }
                }.foregroundStyle(.secondary).frame(minHeight: 44)
            }.font(.caption).accessibilityIdentifier("usageDetails")
        }
    }
}

struct TurnUsageView: View {
    let usage: JSON
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                ForEach([(key: "uncachedInputTokens", label: L("Uncached input", "未缓存输入")), (key: "cacheReadTokens", label: L("Cache read", "缓存读取")), (key: "cacheWriteTokens", label: L("Cache write", "缓存写入")), (key: "outputTokens", label: L("Output", "输出")), (key: "reasoningTokens", label: L("Reasoning (included in output)", "推理（包含于输出）"))], id: \.key) { row in
                    if let count = usage[row.key].int { LabeledContent(row.label, value: count.formatted()) }
                }
                ForEach(Array(usage["routes"].array.enumerated()), id: \.offset) { _, route in Text(route["provider"].text + "/" + route["model"].text).font(.caption2.monospaced()) }
            }.padding(.top, 5).textSelection(.enabled)
        } label: { Label(L("Turn usage: ", "本轮用量：") + (usage["totalTokens"].int?.formatted() ?? "") + " tok", systemImage: "cylinder.split.1x2") }.font(.caption).foregroundStyle(.secondary)
    }
}
