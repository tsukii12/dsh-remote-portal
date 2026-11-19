import Foundation
import Combine

struct FileMentionToken: Equatable {
    let prefix: String
    let query: String
    let quoted: Bool
    static func active(in text: String) -> FileMentionToken? {
        for (pattern, quoted) in [("(?:^|\\s)(@\"([^\"]*))$", true), ("(?:^|\\s)(@([^\\s]*))$", false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let prefix = Range(match.range(at: 1), in: text), let query = Range(match.range(at: 2), in: text) else { continue }
            return FileMentionToken(prefix: String(text[prefix]), query: String(text[query]), quoted: quoted)
        }
        return nil
    }
    func inserting(_ candidate: JSON, into text: String) -> String? {
        if let mention = candidate["mention"].string {
            guard !quoted, !mention.isEmpty, text.hasSuffix(prefix) else { return nil }
            return String(text.dropLast(prefix.count)) + mention + " "
        }
        let path = candidate["path"].text
        guard text.hasSuffix(prefix), !path.isEmpty, !WorkspacePathPolicy.isPrivate(path), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 34 }) else { return nil }
        let directory = candidate["kind"] == "directory"
        let value = path + (directory ? "/" : "")
        let needsQuotes = quoted || value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let mention = needsQuotes ? "@\"" + value + (directory ? "" : "\"") : "@" + value
        return String(text.dropLast(prefix.count)) + mention + (directory ? "" : " ")
    }
    static func insertingFile(_ path: String, into text: String) -> String? {
        let token = active(in: text) ?? FileMentionToken(prefix: "", query: "", quoted: false)
        let prefix = token.prefix.isEmpty && !text.isEmpty && text.last?.isWhitespace == false ? text + " " : text
        return token.inserting(["path": .string(path), "kind": "file"], into: prefix)
    }
}

@MainActor
final class FileMentions: ObservableObject {
    @Published private(set) var candidates: [JSON] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private let api: RPCServing
    private let sessionID: String
    private var generation = 0
    init(api: RPCServing, sessionID: String) { self.api = api; self.sessionID = sessionID }
    func load(_ text: String) async {
        generation += 1; let ticket = generation
        candidates = []; error = nil; loading = false
        guard let token = FileMentionToken.active(in: text) else { return }
        loading = true
        do {
            try await Task.sleep(nanoseconds: 180_000_000)
            let args: JSON = ["agentId": .string(sessionID), "query": .string(token.query)]
            async let files = lookup("fileReferences/list", args: args)
            async let sessions: ([JSON], String?) = token.quoted ? ([], nil) : lookup("sessionReferenceResolver/candidates", args: args)
            let (fileResult, sessionResult) = await (files, sessions)
            guard ticket == generation, !Task.isCancelled else { return }
            candidates = fileResult.0.filter { !WorkspacePathPolicy.isPrivate($0["path"].text) } + sessionResult.0.filter { $0["mention"].string?.isEmpty == false }
            error = fileResult.1 ?? sessionResult.1; loading = false
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
    private func lookup(_ method: String, args: JSON) async -> ([JSON], String?) {
        do { return (try await api.rpc(method, args: args).array, nil) }
        catch { return ([], error.localizedDescription) }
    }
}
