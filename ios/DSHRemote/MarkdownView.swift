import SwiftUI
import UIKit

enum MarkdownBlock: Equatable {
    case paragraph(String), heading(Int, String), list(String, String), code(String, String)
    case table([String], [[String]], [TableAlignment])
}

enum TableAlignment: Equatable { case leading, center, trailing }

enum MarkdownParser {
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []; var cell = ""; var escaped = false; var code = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                if character == "|" { cell.append(character); escaped = false; continue }
                cell.append("\\"); escaped = false
            }
            if character == "\\" { escaped = true; continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if cells.first == "" { cells.removeFirst() }; if cells.last == "" { cells.removeLast() }
        return cells
    }
    static func blocks(_ text: String) -> [MarkdownBlock] {
        guard !text.isEmpty else { return [] }
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: Character?
        var fenceLength = 0
        var language = ""
        func flush() {
            var index = 0; var plain: [String] = []
            func flushPlain() { if !plain.isEmpty { result.append(.paragraph(plain.joined(separator: "\n"))); plain = [] } }
            while index < paragraph.count {
                if index + 1 < paragraph.count, paragraph[index].contains("|") {
                    let header = cells(paragraph[index]); let rules = cells(paragraph[index + 1])
                    if !header.isEmpty, rules.count == header.count, rules.allSatisfy({ $0.filter { $0 == "-" }.count >= 3 && $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                        flushPlain(); index += 2
                        var rows: [[String]] = []
                        while index < paragraph.count, paragraph[index].contains("|") { rows.append(cells(paragraph[index])); index += 1 }
                        result.append(.table(header, rows, rules.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .trailing) : .leading })); continue
                    }
                }
                plain.append(paragraph[index]); index += 1
            }
            flushPlain(); paragraph = []
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= fenceLength && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(.code(language, code.joined(separator: "\n"))); code = []; fence = nil
                } else { code.append(line) }
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= 3 { flush(); fence = marker; fenceLength = count; language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces); continue }
            }
            if trimmed.isEmpty { flush(); continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush(); result.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1)))); continue
            }
            if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                flush(); result.append(.list("•", String(trimmed.dropFirst(2)))); continue
            }
            let digits = trimmed.prefix(while: { $0.isNumber })
            if !digits.isEmpty && trimmed.dropFirst(digits.count).hasPrefix(". ") {
                flush(); result.append(.list(String(digits) + ".", String(trimmed.dropFirst(digits.count + 2)))); continue
            }
            paragraph.append(line)
        }
        if fence != nil { result.append(.code(language, code.joined(separator: "\n"))) }
        flush()
        return result
    }
}

struct MarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): inline(text).lineSpacing(4)
                case .heading(let level, let text): inline(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).padding(.top, 5)
                case .list(let bullet, let text): HStack(alignment: .firstTextBaseline, spacing: 10) { Text(bullet).foregroundStyle(.secondary); inline(text).frame(maxWidth: .infinity, alignment: .leading) }
                case .table(let header, let rows, let alignments):
                    ScrollView(.horizontal) {
                        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(Array(([header] + rows).enumerated()), id: \.offset) { rowIndex, row in
                                GridRow {
                                    ForEach(0..<max(header.count, rows.map(\.count).max() ?? 0), id: \.self) { column in
                                        let alignment: Alignment = column < alignments.count && alignments[column] == .trailing ? .trailing : column < alignments.count && alignments[column] == .center ? .center : .leading
                                        inline(column < row.count ? row[column] : "").fontWeight(rowIndex == 0 ? .semibold : .regular).frame(minWidth: 120, maxWidth: 260, minHeight: 30, alignment: alignment).padding(10).background(.secondary.opacity(rowIndex == 0 ? 0.08 : 0.02)).overlay(Rectangle().stroke(.secondary.opacity(0.2), lineWidth: 0.5))
                                    }
                                }
                            }
                        }.textSelection(.enabled)
                    }.accessibilityLabel(L("Table", "表格"))
                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? L("Code", "代码") : language).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { UIPasteboard.general.string = code } label: { Image(systemName: "doc.on.doc").font(.caption).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(L("Copy code", "复制代码"))
                        }.padding(12)
                        Divider()
                        ScrollView(.horizontal) { Text(code.isEmpty ? " " : code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(12) }
                    }.background(DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ text: String) -> Text {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true { attributed[run.range].font = .system(.body, design: .monospaced) }
        return Text(attributed)
    }
}

enum ToolPresentation {
    static func summary(_ arguments: String) -> String {
        guard let value = try? JSONDecoder().decode(JSON.self, from: Data(arguments.utf8)) else { return arguments }
        return value["command"].string ?? arguments
    }
    static func result(_ value: JSON) -> String {
        let content = value["message"]["content"].array.map { block in
            if block["type"] == "text" || block["type"] == .null, let text = block["text"].string { return text }
            if block["type"] == "image" || block["type"] == "file" { return "" }
            return block.formatted
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        return content.isEmpty ? value["error"]["message"].string ?? value.formatted : content
    }
}

struct ToolCard: View {
    let block: TranscriptBlock
    let api: RPCServing
    let sessionID: String
    @State private var expanded = false
    @ScaledMetric(relativeTo: .caption) private var resultLineHeight = 18
    private var failed: Bool { block.result?["message"]["isError"].boolean == true || (block.result?["error"] ?? .null) != .null }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView([.horizontal, .vertical]) { Text(block.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 180)
            if let result = block.result {
                ForEach(Array(result["message"]["content"].array.enumerated()), id: \.offset) { _, content in
                    if content["type"] == "image" || content["type"] == "file" { HistoricalAttachmentView(block: TranscriptBlock(content), api: api, sessionID: sessionID) }
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(ToolPresentation.result(result)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }.frame(height: min(CGFloat(max(1, ToolPresentation.result(result).components(separatedBy: .newlines).count)) * resultLineHeight + 10, 220))
            } else { Text(L("Waiting for result…", "正在等待结果…")).font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "terminal")
                    Text(block.name).font(.system(.subheadline, design: .monospaced).weight(.medium))
                    Spacer()
                    if failed { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                    else if block.result != nil { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                    else { ProgressView().controlSize(.mini) }
                }
                Text(ToolPresentation.summary(block.arguments)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }.foregroundStyle(Color.primary)
        }
        .padding(12).background(failed ? Color.red.opacity(0.08) : DRPStyle.sidebar, in: RoundedRectangle(cornerRadius: 12))
    }
}
