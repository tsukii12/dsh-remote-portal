import Foundation

enum TurnUsage {
    private static let maximumCount = 9_007_199_254_740_991
    private enum State { case idle, open, finishClosed, message, retry }
    private static func count(_ value: JSON) -> Int? {
        guard let count = value.int, count >= 0, count <= maximumCount else { return nil }
        return count
    }
    private static func sum(_ counts: [Int]) -> Int? {
        var result = 0
        for count in counts { let next = result.addingReportingOverflow(count); guard !next.overflow, next.partialValue <= maximumCount else { return nil }; result = next.partialValue }
        return result
    }
    private static func normalize(_ sample: JSON, route: JSON?) -> JSON? {
        guard let input = count(sample["inputTokens"]), let output = count(sample["outputTokens"]) else { return nil }
        for key in ["cacheReadTokens", "cacheWriteTokens", "reasoningTokens", "totalTokens"] where sample[key] != .null {
            guard count(sample[key]) != nil else { return nil }
        }
        guard (count(sample["reasoningTokens"]) ?? 0) <= output,
              let prompt = sum([input, count(sample["cacheReadTokens"]) ?? 0, count(sample["cacheWriteTokens"]) ?? 0]) else { return nil }
        let total: Int
        if let exact = count(sample["totalTokens"]) {
            guard exact >= output, exact - output >= prompt else { return nil }
            if sample["cacheReadTokens"] != .null && sample["cacheWriteTokens"] != .null && exact - output != prompt { return nil }
            total = exact
        } else {
            guard sample["cacheReadTokens"] != .null, sample["cacheWriteTokens"] != .null, let exact = sum([prompt, output]) else { return nil }
            total = exact
        }
        var normalized = sample
        normalized["uncachedInputTokens"] = .int(input); normalized["totalTokens"] = .int(total)
        if let route { normalized["route"] = route }
        return normalized
    }
    static func derive(_ events: [JSON]) -> JSON? {
        var state = State.idle
        var turn: Int?
        var step: Int?
        var sample: JSON = .null
        var ended = false
        var attempts: [JSON] = []
        func streamSample(_ event: JSON) -> JSON? { CompactStream.expand(event["data"]["stream"].array).last(where: { $0["type"] == "usage" })?["usage"] }
        func close(_ route: JSON? = nil) -> Bool {
            guard state == .open, let value = normalize(sample, route: route) else { return false }
            attempts.append(value); return true
        }
        for event in events {
            let type = event["type"].text; let data = event["data"]
            if type == "turn/start" { guard turn == nil, state == .idle, let number = data["turn"].int else { return nil }; turn = number; continue }
            guard let turn else { return nil }
            if type == "turn/end" { guard data["turn"].int == turn, state == .idle, !ended else { return nil }; ended = true; continue }
            guard !ended else { return nil }
            if type == "step/start" { guard data["turn"].int == turn, state == .idle, let number = data["step"].int else { return nil }; step = number; state = .open; sample = .null; continue }
            guard ["llm/retry-started", "assistant/attempt", "assistant/message", "llm/retry", "step/end"].contains(type) else { continue }
            guard data["turn"].int == turn, data["step"].int == step else { return nil }
            switch type {
            case "llm/retry-started": guard state == .retry else { return nil }; state = .open; sample = .null
            case "assistant/attempt":
                guard state == .open else { return nil }; sample = streamSample(event) ?? sample
                guard close() else { return nil }; state = .finishClosed
            case "assistant/message":
                guard state == .open else { return nil }
                sample = data["usage"] != .null ? data["usage"] : streamSample(event) ?? sample
                let source = data["message"]["source"]
                let route: JSON? = source["provider"].text.isEmpty || source["model"].text.isEmpty ? nil : ["provider": source["provider"], "model": source["model"]]
                guard close(route) else { return nil }; state = .message
            case "llm/retry":
                guard state == .finishClosed || (state == .open && close()) else { return nil }; state = .retry
            case "step/end":
                guard state != .idle, state != .open || close() else { return nil }; state = .idle
            default: break
            }
        }
        guard ended, state == .idle, !attempts.isEmpty else { return nil }
        var result: JSON = [:]
        for key in ["uncachedInputTokens", "outputTokens", "totalTokens", "cacheReadTokens", "cacheWriteTokens", "reasoningTokens"] {
            let values = attempts.compactMap { count($0[key]) }
            guard values.count == attempts.count else { if ["uncachedInputTokens", "outputTokens", "totalTokens"].contains(key) { return nil }; continue }
            guard let value = sum(values) else { return nil }; result[key] = .int(value)
        }
        let routes = attempts.compactMap { $0["route"] == .null ? nil : $0["route"] }
        if routes.count == attempts.count { var seen = Set<String>(); result["routes"] = .array(routes.filter { seen.insert($0["provider"].text + "\0" + $0["model"].text).inserted }) }
        return result
    }
    static func byTurn(_ events: [JSON]) -> [Int: JSON] {
        var result: [Int: JSON] = [:]
        var pending: [JSON] = []
        for event in events {
            if event["type"] == "turn/start" { pending = [event] }
            else if !pending.isEmpty { pending.append(event) }
            if event["type"] == "turn/end" {
                if let turn = event["data"]["turn"].int, let usage = derive(pending) { result[turn] = usage }
                pending = []
            }
        }
        return result
    }
}
