//
//  AskAnswerBlocks.swift
//  Yappy
//
//  Lightweight block-level markdown parser for Ask answers. SwiftUI's
//  AttributedString(markdown:) only handles INLINE syntax — tables, fenced
//  code, lists, and images arrive as raw text. This splits an answer into
//  typed blocks the pill can render properly (Grid for tables, mono box for
//  code, bullet rows, AsyncImage), leaving inline styling (bold, links) to
//  AttributedString per block.
//
//  Deliberately small: line-based, no nesting, tolerant of the half-finished
//  blocks that appear mid-stream (an unterminated code fence renders as code).
//

import Foundation

enum AskAnswerBlock: Equatable {
    case paragraph(String)
    /// A markdown heading: `## Title` → level 2.
    case heading(level: Int, text: String)
    /// Fenced code (``` … ```). `language` is the info string, if any.
    case code(language: String?, text: String)
    /// A markdown pipe table. `header` is nil when no |---| separator followed
    /// the first row.
    case table(header: [String]?, rows: [[String]])
    /// A run of bullet ("- ", "* ") or numbered ("1. ") list items.
    case list(items: [String], ordered: Bool)
    /// A standalone image line: ![alt](url)
    case image(alt: String, url: URL)

    /// Content-derived suffix for positional identity — paired with parse index.
    var contentID: String {
        switch self {
        case .paragraph(let text): "p:\(text.hashValue)"
        case .heading(let level, let text): "h\(level):\(text.hashValue)"
        case .code(_, let text): "c:\(text.hashValue)"
        case .table(let header, let rows): "t:\(header?.joined().hashValue ?? 0):\(rows.count):\(rows.first?.joined().hashValue ?? 0)"
        case .list(let items, _): "l:\(items.count):\(items.first?.hashValue ?? 0)"
        case .image(_, let url): "i:\(url.absoluteString)"
        }
    }

    /// Position-prefixed identity for ForEach — earlier indexes stay stable
    /// while later blocks stream in.
    func id(at index: Int) -> String { "\(index):\(contentID)" }

    private static let narrationOpeners = [
        "searching for", "searching the", "looking for", "looking up",
        "looking into", "let me check", "let me look", "let me search",
        "let me find", "checking ", "finding ", "one moment", "one sec",
    ]

    /// True when the first non-empty line reads as process narration.
    private static func firstLineIsNarration(_ lines: [String], at index: Int) -> Bool {
        let first = lines[index].trimmingCharacters(in: .whitespaces).lowercased()
        return first.count <= 90 && narrationOpeners.contains(where: { first.hasPrefix($0) })
    }

    /// True when the text is NOTHING BUT a narration line so far — used while
    /// streaming, where showing "Searching for …" duplicates the pill's own
    /// animated search indicator.
    static func isNarrationOnly(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              firstLineIsNarration(lines, at: firstIndex) else {
            return false
        }
        let rest = lines[(firstIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty
    }

    /// Drops a single leading process-narration line ("Searching for …",
    /// "Let me check …") when real content follows it. Models sometimes open
    /// with narration despite instructions; the pill already shows a live
    /// search indicator, so the line is pure noise. Conservative: only the
    /// FIRST line, only known narration openers, only when more content
    /// exists — a whole answer is never reduced to nothing.
    static func strippingLeadingNarration(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              firstLineIsNarration(lines, at: firstIndex) else {
            return text
        }
        let rest = lines[(firstIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return text }

        lines.removeSubrange(...firstIndex)
        while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [AskAnswerBlock] {
        var blocks: [AskAnswerBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        var tableLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushList() {
            if !listItems.isEmpty { blocks.append(.list(items: listItems, ordered: listOrdered)) }
            listItems = []
        }
        func flushTable() {
            if let table = Self.makeTable(tableLines) { blocks.append(table) }
            else { paragraph.append(contentsOf: tableLines); flushParagraph() }
            tableLines = []
        }
        func flushAll() {
            flushParagraph(); flushList(); flushTable()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if inCode {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushAll()
                let info = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = info.isEmpty ? nil : info
                inCode = true
                continue
            }

            if line.isEmpty {
                flushAll()
                continue
            }

            // Standalone image: ![alt](url)
            if let image = Self.makeImage(line) {
                flushAll()
                blocks.append(image)
                continue
            }

            // Heading: 1–6 #'s followed by a space.
            if let heading = Self.makeHeading(line) {
                flushAll()
                blocks.append(heading)
                continue
            }

            // Table row: starts and ends with a pipe (the common model output).
            if line.hasPrefix("|") && line.hasSuffix("|") && line.count > 1 {
                flushParagraph(); flushList()
                tableLines.append(line)
                continue
            } else if !tableLines.isEmpty {
                flushTable()
            }

            // List item?
            if let item = Self.listItem(line, ordered: false) {
                flushParagraph(); flushTable()
                if !listItems.isEmpty, listOrdered { flushList() }
                listOrdered = false
                listItems.append(item)
                continue
            }
            if let item = Self.listItem(line, ordered: true) {
                flushParagraph(); flushTable()
                if !listItems.isEmpty, !listOrdered { flushList() }
                listOrdered = true
                listItems.append(item)
                continue
            }
            if !listItems.isEmpty { flushList() }

            paragraph.append(rawLine)
        }

        // Stream-tolerant tails: an unterminated fence renders as code.
        if inCode, !codeLines.isEmpty {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    /// Parsed blocks with position-prefixed identity for SwiftUI rendering.
    struct Identified: Identifiable, Equatable {
        let index: Int
        let block: AskAnswerBlock
        var id: String { block.id(at: index) }
    }

    static func identified(_ text: String) -> [Identified] {
        parse(text).enumerated().map { Identified(index: $0.offset, block: $0.element) }
    }

    /// Renders an Ask answer as clean text for explicit insertion at the user's
    /// cursor. This follows the same block parser used by the pill, then removes
    /// common inline markdown so pasted answers read naturally in plain editors.
    static func plainText(from markdown: String) -> String {
        parse(strippingLeadingNarration(markdown))
            .compactMap(plainTextBlock)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private static func plainTextBlock(_ block: AskAnswerBlock) -> String? {
        switch block {
        case .paragraph(let text):
            return stripInlineMarkdown(text)
        case .heading(_, let text):
            return stripInlineMarkdown(text)
        case .code(_, let text):
            return text
        case .table(let header, let rows):
            let tableRows = (header.map { [$0] } ?? []) + rows
            return tableRows
                .map { row in row.map(stripInlineMarkdown).joined(separator: "\t") }
                .joined(separator: "\n")
        case .list(let items, let ordered):
            return items.enumerated()
                .map { index, item in
                    let prefix = ordered ? "\(index + 1). " : "- "
                    return prefix + stripInlineMarkdown(item)
                }
                .joined(separator: "\n")
        case .image(let alt, _):
            let text = stripInlineMarkdown(alt).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private static func stripInlineMarkdown(_ text: String) -> String {
        var output = text
        output = replace(output, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, template: "$1 ($2)")
        output = replace(output, pattern: #"`([^`]+)`"#, template: "$1")
        output = replace(output, pattern: #"\*\*([^*\n]+)\*\*"#, template: "$1")
        output = replace(output, pattern: #"__([^_\n]+)__"#, template: "$1")
        output = replace(output, pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, template: "$1")
        output = replace(output, pattern: #"(?<!_)_([^_\n]+)_(?!_)"#, template: "$1")
        return output
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: - Piece parsers

    private static func listItem(_ line: String, ordered: Bool) -> String? {
        if ordered {
            // "1. text" / "12. text"
            guard let dot = line.firstIndex(of: "."), dot != line.startIndex,
                  line[line.startIndex..<dot].allSatisfy(\.isNumber) else { return nil }
            let rest = line[line.index(after: dot)...]
            guard rest.hasPrefix(" ") else { return nil }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func makeHeading(_ line: String) -> AskAnswerBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    private static func makeImage(_ line: String) -> AskAnswerBlock? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let altEnd = line.range(of: "]("),
              let url = URL(string: String(line[altEnd.upperBound..<line.index(before: line.endIndex)])),
              let scheme = url.scheme?.lowercased(), scheme == "https" else {
            return nil
        }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        return .image(alt: alt, url: url)
    }

    private static func makeTable(_ lines: [String]) -> AskAnswerBlock? {
        guard !lines.isEmpty else { return nil }
        func cells(_ line: String) -> [String] {
            line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSeparator(_ line: String) -> Bool {
            let inner = cells(_: line)
            guard !inner.isEmpty else { return false }
            return inner.allSatisfy { cell in
                !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
            }
        }

        var header: [String]?
        var rows: [[String]] = []
        var body = lines[...]
        if lines.count >= 2, isSeparator(lines[1]) {
            header = cells(lines[0])
            body = lines[2...]
        }
        for line in body where !isSeparator(line) {
            rows.append(cells(line))
        }
        // A one-line "table" with no separator is more likely a stray pipe.
        if header == nil && rows.count < 2 { return nil }
        guard header != nil || !rows.isEmpty else { return nil }
        return .table(header: header, rows: rows)
    }
}
