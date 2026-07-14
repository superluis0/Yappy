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
        "i'll ", "i will ",
        "i'm checking", "i'm looking", "i'm searching", "context is",
    ]

    /// The subset safe to match at SENTENCE granularity inside the first line.
    /// Bare "checking "/"finding "/"looking for" are excluded here: as sentence
    /// openers they collide with real prose ("Checking the weather is easy.")
    /// far more often than as whole standalone lines. "I'll …" matches
    /// WHOLESALE: enumerating retrieval verbs (look/check/pull/grab/fetch…)
    /// lost that game in the field, and a first-person-future opening sentence
    /// of a voice ANSWER is meta by nature — the ≤90-char cap and the
    /// content-must-follow guard bound the blast radius.
    private static let sentenceNarrationOpeners = [
        "searching for", "searching the", "looking up", "looking into",
        "let me ", "one moment", "one sec",
        "i'll ", "i will ",
        "i'm checking", "i'm looking", "i'm searching", "context is",
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
        var output = text
        var lines = output.components(separatedBy: "\n")
        if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           firstLineIsNarration(lines, at: firstIndex) {
            let rest = lines[(firstIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                lines.removeSubrange(...firstIndex)
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.removeFirst()
                }
                output = lines.joined(separator: "\n")
            }
        }
        return strippingLeadingNarrationSentences(output)
    }

    /// Sentence-granular pass for narration FUSED into the first content line
    /// ("I'll look up the schedule. Context is mid-July. Next up: …") — models
    /// sometimes glue their working preamble straight onto the answer, where
    /// the whole-line pass can't reach it. Strips at most three leading
    /// sentences; each must start with a known sentence-safe opener and stay
    /// short, and the answer is never reduced to nothing.
    private static func strippingLeadingNarrationSentences(_ text: String) -> String {
        var output = text
        for _ in 0..<3 {
            let trimmed = output.drop(while: { $0 == " " || $0 == "\n" })
            let lowered = trimmed.lowercased()
            guard sentenceNarrationOpeners.contains(where: { lowered.hasPrefix($0) }) else { break }
            // The narration sentence must END within 90 characters at a real
            // boundary: terminator + space, preceded by a lowercase letter or
            // digit (so "U.S." initialisms and "3.5" decimals never cut).
            var boundary: Substring.Index?
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex,
                  trimmed.distance(from: trimmed.startIndex, to: index) <= 90 {
                let character = trimmed[index]
                if ".!?".contains(character) {
                    let next = trimmed.index(after: index)
                    let previous = trimmed[trimmed.index(before: index)]
                    if next < trimmed.endIndex, trimmed[next] == " ",
                       previous.isLowercase || previous.isNumber {
                        boundary = next
                        break
                    }
                }
                index = trimmed.index(after: index)
            }
            guard let boundary else { break }
            let remainder = String(trimmed[boundary...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { break }
            output = remainder
        }
        return output
    }

    /// Repairs sentences a model streamed GLUED together — no space after the
    /// terminator ("…the next matches.Context is…"). That one defect defeats
    /// sentence splitting, narration stripping, and the citation-trailer
    /// anchors all at once, so the repair happens at the source, as deltas
    /// append. A space is inserted after `.!?` only when preceded by a
    /// lowercase letter or digit AND followed by an uppercase letter, so
    /// initialisms ("U.S.A"), domains ("FIFA.com"), decimals ("3.5"), and
    /// identifiers ("Node.js") never match. `previous` is the text already
    /// accumulated: the same 3-character window is checked across the join, so
    /// repairing delta-by-delta produces byte-identical output to repairing
    /// the concatenated whole (which keeps codex's authoritative full-text
    /// replace consistent with its streamed deltas).
    static func repairGluedSentences(previous: String, delta: String) -> String {
        guard !delta.isEmpty else { return delta }
        var repaired = delta
        if let regex = try? NSRegularExpression(pattern: #"([a-z0-9][.!?])(?=[A-Z])"#) {
            let range = NSRange(repaired.startIndex..<repaired.endIndex, in: repaired)
            repaired = regex.stringByReplacingMatches(in: repaired, range: range, withTemplate: "$1 ")
        }
        if let last = previous.last, ".!?".contains(last),
           let beforeTerminator = previous.dropLast().last,
           beforeTerminator.isLowercase || beforeTerminator.isNumber,
           let first = repaired.first, first.isUppercase {
            repaired = " " + repaired
        }
        return repaired
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

    /// Renders an Ask answer as text optimized for local speech synthesis:
    /// prose and list items only, no code/tables/images, with each segment
    /// shaped like a sentence for cleaner chunking.
    static func speakableText(from markdown: String) -> String {
        let blocks = droppingTrailingCitationBlocks(parse(strippingLeadingNarration(markdown)))
        let segments = blocks
            .flatMap(speakableTextSegments)
            .map(ensureTerminalPunctuation)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let output = finalizeSpeakableOutput(from: segments)
        // An all-code answer has no speakable prose — say where the answer
        // lives instead of dead air. (Streaming-prefix safe: the stream emits
        // nothing for code blocks, and "" is a prefix of anything.)
        if output.isEmpty,
           blocks.contains(where: { if case .code = $0 { return true } else { return false } }) {
            return "The answer is a code block on screen."
        }
        return output
    }

    /// Prefix of the eventual `speakableText` that is already safe to speak while
    /// an answer is still streaming in. Monotone under append-only input and
    /// convergent to `speakableText` once every block has closed.
    ///
    /// - Parameter allowLeadingClause: When `true`, the first emission may end
    ///   mid-sentence at a clause boundary (`, ` / `; ` / `: `) if no full
    ///   sentence is yet available. Callers must only pass `true` while nothing
    ///   has been emitted yet (first emission). MONOTONE and PREFIX guarantees
    ///   still hold for any subsequent call with either flag value: a clause
    ///   emission is always a prefix of later non-empty results and of the
    ///   final `speakableText`.
    static func stableSpeakablePrefix(
        fromStreaming accumulated: String,
        allowLeadingClause: Bool = false
    ) -> String {
        guard !isNarrationOnly(accumulated) else { return "" }
        let stripped = strippingLeadingNarration(accumulated)
        guard !stripped.isEmpty else { return "" }

        let blocks = droppingTrailingCitationBlocks(parse(stripped))
        guard !blocks.isEmpty else { return "" }

        var segments: [String] = []
        var emissionStopped = false
        for (index, block) in blocks.dropLast().enumerated() {
            // STOP at the first unsafe block — never skip past one. Skipping a
            // withheld middle block while emitting later ones would make the
            // streamed output a non-prefix of the eventual speakableText, which
            // corrupts the completion handoff's consumed-prefix arithmetic.
            // Stopping keeps both guarantees: still monotone, and always a
            // prefix of the full result (the handoff speaks the rest).
            guard blockSafeForStreamingEmission(block, blocks: blocks, at: index) else {
                emissionStopped = true
                break
            }
            segments.append(contentsOf: finalizedSpeakableSegments(for: block))
        }
        if !emissionStopped, let last = blocks.last {
            segments.append(contentsOf: stableSpeakableSegmentsFromGrowingLastBlock(
                last,
                rawAccumulated: accumulated
            ))
        }
        let sentenceLevel = finalizeSpeakableOutput(from: segments)
        // Clause emission is strictly subordinate to sentences: never replace
        // or reorder an available full-sentence result.
        if allowLeadingClause, sentenceLevel.isEmpty,
           let clause = stableLeadingClauseSegment(from: blocks, rawAccumulated: accumulated) {
            return finalizeSpeakableOutput(from: [clause])
        }
        return sentenceLevel
    }

    /// Opt-in first-chunk clause for a single growing plain paragraph when no
    /// sentence is ready yet. Returns the strip-transformed clause without
    /// `ensureTerminalPunctuation` (which would break PREFIX).
    private static func stableLeadingClauseSegment(
        from blocks: [AskAnswerBlock],
        rawAccumulated: String
    ) -> String? {
        guard blocks.count == 1, case .paragraph(let text) = blocks[0] else { return nil }
        guard !growingBlockFirstLineBlocksStreamingEmission(text) else { return nil }
        if isCitationHeaderLine(text.components(separatedBy: "\n").first ?? "") { return nil }
        guard let clauseRaw = extractStableLeadingClause(from: text, inRawAccumulated: rawAccumulated) else {
            return nil
        }
        guard isMarkdownStableClauseFragment(clauseRaw) else { return nil }
        let transformed = stripInlineMarkdown(
            clauseRaw,
            linkStyle: .labelOnly,
            droppingBareURLs: true,
            droppingCitations: true
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return transformed.isEmpty ? nil : transformed
    }

    /// Leading clause whose boundary (`, ` / `; ` / `: ` after a letter/digit)
    /// has at least one more streamed character after the following space.
    /// Candidate is paragraph-start through the punctuation inclusive, ≥ 60
    /// characters. Uses the last qualifying boundary.
    private static func extractStableLeadingClause(
        from text: String,
        inRawAccumulated rawAccumulated: String
    ) -> String? {
        guard let textRange = rawAccumulated.range(of: text, options: .backwards) else { return nil }

        func absoluteIndex(in text: String, at local: String.Index) -> String.Index {
            let offset = text.distance(from: text.startIndex, to: local)
            return rawAccumulated.index(textRange.lowerBound, offsetBy: offset)
        }

        func hasMoreStreamContent(after absolute: String.Index) -> Bool {
            rawAccumulated.index(after: absolute) < rawAccumulated.endIndex
        }

        var lastBoundaryEnd: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if (character == "," || character == ";" || character == ":"),
               next < text.endIndex,
               text[next] == " ",
               index > text.startIndex {
                let previous = text[text.index(before: index)]
                if previous.isLetter || previous.isNumber {
                    // Lookahead past the space after the clause punctuation —
                    // without it the boundary may still be mid-token in the stream.
                    let absSpace = absoluteIndex(in: text, at: next)
                    if hasMoreStreamContent(after: absSpace) {
                        // Inclusive of punctuation; exclusive of the following space.
                        lastBoundaryEnd = next
                    }
                }
            }
            index = next
        }

        guard let end = lastBoundaryEnd else { return nil }
        let candidate = String(text[text.startIndex..<end])
        guard candidate.count >= 60 else { return nil }
        return candidate
    }


    /// Rejects clause fragments where `stripInlineMarkdown` of the span alone
    /// could diverge from the same span stripped inside the full sentence.
    ///
    /// Deliberately blunt: the fragment must contain NO inline-markdown
    /// delimiter characters at all. Three review rounds of span-closure
    /// scanning each leaked a false ACCEPT (even-count unclosed openers,
    /// adjacent empty pairs, emphasis characters hiding inside code spans whose
    /// literal content the strip regexes keep), because "closed here" cannot
    /// prove "strips the same once the rest of the sentence arrives". With no
    /// delimiter characters inside the fragment, no strip regex can begin a
    /// match inside it, so the emitted prefix is stable by construction.
    /// Markdown-flavored openings simply fall back to the full-sentence wait.
    private static func isMarkdownStableClauseFragment(_ text: String) -> Bool {
        if text.contains(where: { "`*_~[]".contains($0) }) { return false }
        if text.filter({ $0 == "(" }).count != text.filter({ $0 == ")" }).count { return false }
        if text.contains("http") || text.contains("www.") { return false }
        return true
    }

    /// Paragraphs that still look like an opening table/list/heading line can
    /// reflow when more lines arrive, even when the parser temporarily closed
    /// them because another block followed. Tables wait until the next block is
    /// equally stable — a pipe-line "paragraph" between rows is not enough.
    /// Lists withhold when the following block is a partial list marker (`2.`,
    /// `-`) that will rejoin the list once the rest of the item streams in —
    /// otherwise a temporarily-closed list would emit then shrink (MONOTONE).
    private static func blockSafeForStreamingEmission(
        _ block: AskAnswerBlock,
        blocks: [AskAnswerBlock],
        at index: Int
    ) -> Bool {
        switch block {
        case .paragraph(let text), .heading(_, let text):
            return !growingBlockFirstLineBlocksStreamingEmission(text)
        case .table:
            guard index + 1 < blocks.count else { return false }
            return blockSafeForStreamingEmission(blocks[index + 1], blocks: blocks, at: index + 1)
        case .list:
            guard index + 1 < blocks.count else { return true }
            if case .paragraph(let text) = blocks[index + 1], looksLikePartialListMarker(text) {
                return false
            }
            return blockSafeForStreamingEmission(blocks[index + 1], blocks: blocks, at: index + 1)
        case .code, .image:
            return true
        }
    }

    /// Digits / `N.` / lone bullet markers that are not yet a full list item line
    /// (`listItem` requires `"N. "` or `"- "`). Mid-stream these appear as tiny
    /// paragraphs that close the preceding list, then rejoin it.
    private static func looksLikePartialListMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
        if trimmed == "-" || trimmed == "*" || trimmed == "•" { return true }
        if trimmed.allSatisfy(\.isNumber) { return true }
        if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex {
            let num = trimmed[trimmed.startIndex..<dot]
            let rest = trimmed[trimmed.index(after: dot)...]
            if !num.isEmpty, num.allSatisfy(\.isNumber), rest.isEmpty || rest.allSatisfy(\.isWhitespace) {
                return true
            }
        }
        return false
    }

    private static func finalizeSpeakableOutput(from segments: [String]) -> String {
        collapseExcessNewlines(
            segments
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func finalizedSpeakableSegments(for block: AskAnswerBlock) -> [String] {
        speakableTextSegments(block)
            .map(ensureTerminalPunctuation)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Emits nothing from a still-growing final block unless it is closed prose
    /// with leading sentences that are already stable in the raw stream.
    private static func stableSpeakableSegmentsFromGrowingLastBlock(
        _ block: AskAnswerBlock,
        rawAccumulated: String
    ) -> [String] {
        switch block {
        case .paragraph(let text), .heading(_, let text):
            guard !growingBlockFirstLineBlocksStreamingEmission(text) else { return [] }
            // "Sources\n- …" is one growing paragraph until the list line completes;
            // newline sentence extraction would otherwise speak "Sources." which
            // final speakableText drops via citation-trailer stripping (PREFIX).
            if isCitationHeaderLine(text.components(separatedBy: "\n").first ?? "") {
                return []
            }
            guard let stable = stableLeadingProseSegment(from: text, inRawAccumulated: rawAccumulated) else {
                return []
            }
            let segment = ensureTerminalPunctuation(stable)
            return segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [segment]
        case .table, .code, .list, .image:
            return []
        }
    }

    /// A lone `|…|`, fence opener, heading marker, or list item line can still
    /// reflow into a different block type once more lines arrive.
    private static func growingBlockFirstLineBlocksStreamingEmission(_ blockText: String) -> Bool {
        let firstLine = blockText.components(separatedBy: "\n").first ?? ""
        if firstLine.hasPrefix("|") { return true }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return true }
        if trimmed.hasPrefix("#") { return true }
        if firstLine.hasPrefix("- ") || firstLine.hasPrefix("* ") || firstLine.hasPrefix("• ") {
            return true
        }
        if listItem(trimmed, ordered: true) != nil { return true }
        if listItem(firstLine, ordered: false) != nil { return true }
        return false
    }

    private static func stableLeadingProseSegment(
        from text: String,
        inRawAccumulated rawAccumulated: String
    ) -> String? {
        var sentences = extractStableCompleteSentences(from: text, inRawAccumulated: rawAccumulated)
        while !sentences.isEmpty {
            let stableRaw = sentences.reduce(into: "") { $0 += $1 }
            let transformed = stripInlineMarkdown(
                stableRaw,
                linkStyle: .labelOnly,
                droppingBareURLs: true,
                droppingCitations: true
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transformed.isEmpty else { return nil }
            // Strip-stability oracle: emphasis/code delimiters surviving the
            // strip mean an inline span is still OPEN across the cut — e.g. a
            // bold span covering two sentences ("**First. Second.**") whose
            // closer hasn't streamed yet. Emitting now would speak the literal
            // asterisks AND make the same region strip differently once the
            // closer arrives, breaking the streamed prefix's MONOTONE
            // guarantee. Withhold the trailing sentence(s) until the strip
            // comes out clean; a final text that legitimately keeps a
            // delimiter simply waits for the completion handoff.
            // (Underscores are deliberately not in the oracle: snake_case
            // identifiers are common prose here and would withhold forever.)
            if transformed.contains("*") || transformed.contains("`") {
                sentences.removeLast()
                continue
            }
            return transformed
        }
        return nil
    }

    /// Leading sentences whose terminators are not at the very end of the stream.
    /// Mirrors `AskController.speechChunks` boundary intuition locally.
    private static func extractStableCompleteSentences(
        from text: String,
        inRawAccumulated rawAccumulated: String
    ) -> [String] {
        guard let textRange = rawAccumulated.range(of: text, options: .backwards) else { return [] }

        func absoluteIndex(in text: String, at local: String.Index) -> String.Index {
            let offset = text.distance(from: text.startIndex, to: local)
            return rawAccumulated.index(textRange.lowerBound, offsetBy: offset)
        }

        func hasMoreStreamContent(after absolute: String.Index) -> Bool {
            rawAccumulated.index(after: absolute) < rawAccumulated.endIndex
        }

        var sentences: [String] = []
        var start = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if character == "\n" {
                let absNewline = absoluteIndex(in: text, at: index)
                guard hasMoreStreamContent(after: absNewline) else { break }
                sentences.append(String(text[start..<next]))
                start = next
                index = start
                continue
            }

            if character == "." || character == "!" || character == "?" {
                let absPunctuation = absoluteIndex(in: text, at: index)
                if next < text.endIndex, text[next] == " " {
                    guard hasMoreStreamContent(after: absPunctuation) else { break }
                    let boundary = text.index(after: next)
                    sentences.append(String(text[start..<boundary]))
                    start = boundary
                    index = start
                    continue
                }
                if next == text.endIndex {
                    guard hasMoreStreamContent(after: absPunctuation) else { break }
                    sentences.append(String(text[start..<next]))
                    start = next
                    index = start
                    continue
                }
            }

            index = next
        }

        return sentences
    }

    /// Sources are terminal: once a standalone "Sources" / "References" /
    /// "Citations" heading or lone label line appears, everything after it is
    /// citation apparatus. Drop from there so speech ends on the last real
    /// sentence. Inline "Source: …" clauses tacked onto content are handled
    /// separately (stripped in `stripInlineMarkdown` with `droppingCitations`).
    private static func droppingTrailingCitationBlocks(_ blocks: [AskAnswerBlock]) -> [AskAnswerBlock] {
        let cut = blocks.firstIndex { block in
            switch block {
            case .heading(_, let text), .paragraph(let text): isCitationHeaderLine(text)
            default: false
            }
        }
        guard let cut else { return blocks }
        return Array(blocks.prefix(cut))
    }

    private static let citationHeaderMarkers: Set<String> = [
        "sources", "source", "references", "reference",
        "citations", "citation", "further reading",
    ]

    /// True when `text` is a bare citation-section label (optionally wrapped in
    /// markdown emphasis). Multi-line paragraphs are judged on the full string
    /// so `"Sources\n-"` does not match here — use the first-line form for that.
    private static func isCitationHeaderLine(_ text: String) -> Bool {
        let bare = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " *:_"))
        return citationHeaderMarkers.contains(bare)
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
                .map { row in row.map { stripInlineMarkdown($0) }.joined(separator: "\t") }
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

    private static func speakableTextSegments(_ block: AskAnswerBlock) -> [String] {
        switch block {
        case .paragraph(let text), .heading(_, let text):
            return [stripInlineMarkdown(text, linkStyle: .labelOnly, droppingBareURLs: true, droppingCitations: true)]
        case .list(let items, _):
            return items.map { stripInlineMarkdown($0, linkStyle: .labelOnly, droppingBareURLs: true, droppingCitations: true) }
        case .table(let header, let rows):
            // A table can't be spoken as a grid, so each row is linearized into
            // a sentence instead of dropped. Long tables aren't recited in
            // full: past the cap the listener has stopped tracking rows, so
            // speech hands off to the on-screen card.
            let spoken = rows.compactMap { speakableTableRow($0, header: header) }
            if spoken.count > maxSpokenTableRows + 1 {
                let remaining = spoken.count - maxSpokenTableRows
                return Array(spoken.prefix(maxSpokenTableRows))
                    + ["Plus \(remaining) more rows in the table."]
            }
            return spoken
        case .code, .image:
            return []
        }
    }

    /// Rows spoken in full before a long table hands off to the card.
    private static let maxSpokenTableRows = 6

    /// Natural spoken list join: "a", "a and b", "a, b, and c" — commas alone
    /// read as a robotic monotone.
    private static func naturalJoin(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }

    /// Turns one table row into a spoken sentence: the first cell is the subject,
    /// and each following value is labeled by its column header ("Apple M4: CPU
    /// cores up to 10 and Memory bandwidth 120 GB/s"). A header-less table reads
    /// its non-empty cells left to right. Returns nil for a fully empty row.
    private static func speakableTableRow(_ row: [String], header: [String]?) -> String? {
        func clean(_ text: String) -> String {
            stripInlineMarkdown(text, linkStyle: .labelOnly, droppingBareURLs: true, droppingCitations: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cells = row.map(clean)
        guard cells.contains(where: { !$0.isEmpty }) else { return nil }

        let labels = header?.map(clean)
        // Without a usable multi-column header, just read the cells in order.
        guard let labels, labels.count > 1 else {
            return naturalJoin(cells.filter { !$0.isEmpty })
        }

        let subject = cells.first ?? ""
        var parts: [String] = []
        for index in 1..<cells.count where !cells[index].isEmpty {
            let label = index < labels.count ? labels[index] : ""
            parts.append(label.isEmpty ? cells[index] : "\(label) \(cells[index])")
        }
        if subject.isEmpty { return parts.isEmpty ? nil : naturalJoin(parts) }
        return parts.isEmpty ? subject : "\(subject): \(naturalJoin(parts))"
    }

    private enum LinkStyle {
        case labelAndURL
        case labelOnly
    }

    private static func stripInlineMarkdown(
        _ text: String,
        linkStyle: LinkStyle = .labelAndURL,
        droppingBareURLs: Bool = false,
        droppingCitations: Bool = false
    ) -> String {
        var output = text
        if droppingCitations {
            output = strippingCitations(output)
        }
        output = replace(
            output,
            pattern: #"\[([^\]]+)\]\(([^)]+)\)"#,
            template: linkStyle == .labelOnly ? "$1" : "$1 ($2)"
        )
        output = replace(output, pattern: #"`([^`]+)`"#, template: "$1")
        output = replace(output, pattern: #"\*\*([^*\n]+)\*\*"#, template: "$1")
        output = replace(output, pattern: #"__([^_\n]+)__"#, template: "$1")
        output = replace(output, pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, template: "$1")
        output = replace(output, pattern: #"(?<!_)_([^_\n]+)_(?!_)"#, template: "$1")
        if droppingBareURLs {
            output = replace(output, pattern: #"\bhttps?://\S+"#, template: "")
            output = replace(output, pattern: #"[ \t]{2,}"#, template: " ")
        }
        return output
    }

    /// Removes source-citation apparatus from text bound for speech, keeping the
    /// prose grammatical. A model tends to append "Source: …" / "Sources: …" to
    /// the last sentence or on its own line; the content before the marker is
    /// kept and the citation dropped. Also clears inline "(source: …)" /
    /// "(citing …)" parentheticals and bare numeric footnote markers. Ordinary
    /// prose is safe — a marker requires a following colon or citation parens,
    /// and the trailing form only fires at a line start or after sentence-ending
    /// punctuation, so "the source of the Nile" is never touched.
    private static func strippingCitations(_ text: String) -> String {
        var output = text
        output = replace(output, pattern: #"(?im)(?:^|(?<=[.!?]))[ \t]*\*{0,2}sources?\*{0,2}[ \t]*:.*$"#, template: "")
        output = replace(output, pattern: #"(?i)[ \t]*\((?:sources?[ \t]*:|citing\b)[^)]*\)"#, template: "")
        // Grok-style citation cluster: a parenthetical whose entire content is just
        // markdown-link sources with no keyword, e.g. "([Wikipedia](u); [Palmer](u))".
        // (Composer used "Source: …"/"(citing …)", handled above; Grok 4.5 omits the
        // keyword, so match the shape instead.) Runs before the link→label conversion
        // so the whole cluster is removed. Any non-link text inside the parens fails
        // the match, so real parentheticals like "(see [fig 2](u) below)" are kept.
        output = replace(output, pattern: #"[ \t]*\((?:[ \t]*\[[^\]]+\]\((?:[^()]|\([^()]*\))*\)[ \t]*[;,]?)+[ \t]*\)"#, template: "")
        // Grok-style trailing pointer: a "<phrase>: [link](u)" clause ending the line,
        // e.g. "Full fixtures and results: [FIFA](u)." — a citation with no "Source:"
        // keyword. Requires the colon to be followed only by markdown link(s), so an
        // ordinary "Note: bring an umbrella." (no link after the colon) is left alone.
        output = replace(output, pattern: #"(?im)(?:^|(?<=[.!?]))[ \t]*[^\n.!?]*?:[ \t]*(?:\[[^\]]+\]\((?:[^()]|\([^()]*\))*\)[ \t;,]*)+\.?[ \t]*$"#, template: "")
        output = replace(output, pattern: #"\[\^?\d{1,3}\]"#, template: "")
        output = replace(output, pattern: #"[ \t]+([.,;:!?])"#, template: "$1")
        output = replace(output, pattern: #"[ \t]{2,}"#, template: " ")
        return output
    }

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let last = trimmed.last, ".!?:;".contains(last) else {
            return trimmed + "."
        }
        return trimmed
    }

    private static func collapseExcessNewlines(_ text: String) -> String {
        replace(text, pattern: #"\n{3,}"#, template: "\n\n")
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
