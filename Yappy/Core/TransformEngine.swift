//
//  TransformEngine.swift
//  Yappy
//
//  Pure text-transform engine behind "Voice Edit Anywhere". A spoken instruction
//  is parsed into a `TransformOp`; deterministic ops (bullets, lists, case,
//  filler removal, line merge) are applied here with no model in the loop, so
//  the common edits are instant and fully unit-tested. Anything that isn't a
//  known deterministic intent becomes `.generative`, which the controller routes
//  to Apple Intelligence (macOS 26+) — `apply` returns nil for those, meaning
//  "needs generative". `sanitizeGenerative` is the pure accept/clean guard for a
//  model's reply, kept here so it's testable without a live model.
//

import Foundation

/// The edit intent parsed from a spoken instruction. Deterministic cases are
/// applied by `apply`; `.generative` carries the raw instruction through to the
/// on-device language model.
enum TransformOp: Equatable {
    case bullets
    case numberedList
    case joinLines          // collapse to a single line / paragraph
    case uppercase
    case lowercase
    case titleCase
    case removeFiller
    case generative(instruction: String)
}

enum TransformEngine {

    // MARK: - Parsing

    /// Classifies a spoken instruction into a `TransformOp`. Deterministic
    /// intents match a set of phrase fragments (chosen to cover natural spoken
    /// variants without over-firing); everything else falls through to
    /// `.generative`, the safe capable path. Misclassifying generative → a wrong
    /// deterministic op is worse than the reverse, so the fragments are specific.
    static func parse(_ instruction: String) -> TransformOp {
        let raw = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeInstruction(raw)
        guard !normalized.isEmpty else { return .generative(instruction: raw) }

        // Order matters: check the more specific intents first (a "numbered list"
        // must not be caught by the generic "list" fragment).
        if contains(normalized, anyOf: numberedNeedles) { return .numberedList }
        if contains(normalized, anyOf: bulletNeedles) { return .bullets }
        if contains(normalized, anyOf: joinNeedles) { return .joinLines }
        if contains(normalized, anyOf: uppercaseNeedles) { return .uppercase }
        if contains(normalized, anyOf: lowercaseNeedles) { return .lowercase }
        if contains(normalized, anyOf: titleCaseNeedles) { return .titleCase }
        if contains(normalized, anyOf: fillerNeedles) { return .removeFiller }
        return .generative(instruction: raw)
    }

    /// Applies a deterministic op to `text`. Returns nil ONLY for `.generative`,
    /// which signals the caller to route the transform to the language model.
    static func apply(_ op: TransformOp, to text: String) -> String? {
        switch op {
        case .generative:
            return nil
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .titleCase:
            // Matches VoiceEditCommand's "capitalize that" semantics.
            return text.capitalized
        case .removeFiller:
            return FillerWordRemover.remove(text)
        case .bullets:
            return list(from: text, numbered: false)
        case .numberedList:
            return list(from: text, numbered: true)
        case .joinLines:
            return joined(text)
        }
    }

    // MARK: - Deterministic transforms

    /// Splits `text` into list items using the most explicit structure present:
    /// existing line breaks first, then multiple sentences, then commas, and
    /// finally the whole thing as a single item. Sentence items drop their
    /// terminal punctuation; comma/line items are kept verbatim (trimmed).
    static func splitItems(_ text: String) -> [String] {
        let byNewline = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if byNewline.count > 1 { return byNewline }

        let bySentence = sentences(in: text)
        if bySentence.count > 1 { return bySentence }

        let byComma = text
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if byComma.count > 1 { return byComma }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    private static func list(from text: String, numbered: Bool) -> String {
        let items = splitItems(text)
        guard !items.isEmpty else { return text }
        if numbered {
            return items.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        }
        return items.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Collapses all runs of whitespace and newlines into single spaces.
    static func joined(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Sentences in `text`, split on `.`/`!`/`?`, terminators stripped, trimmed,
    /// non-empty. A single unterminated clause yields one item (so the caller
    /// falls through to comma splitting).
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    // MARK: - Generative accept/clean guard

    /// The pure accept/clean policy for a language model's transform reply.
    /// Returns the cleaned output to show in the preview, or nil to reject it.
    /// Rejects: empty output, and an identical echo of the input (a no-op the
    /// user shouldn't have to Replace). Strips a leaked meta-preamble ("Here is
    /// the formal version: …") the small on-device model sometimes prepends.
    static func sanitizeGenerative(_ output: String, original: String) -> String? {
        let stripped = stripLeadingPreamble(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        if stripped == original.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        return stripped
    }

    /// Removes a leading conversational preamble ("Here is …", "Sure, here's …")
    /// the model sometimes emits despite being told not to. Conservative: only
    /// strips when the text plainly OPENS with such a phrase, cutting through the
    /// first colon on the opening line (or the first line break) to the real
    /// content. Leaves everything else untouched.
    static func stripLeadingPreamble(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard preamblePrefixes.contains(where: { lower.hasPrefix($0) }) else { return text }

        let firstNewline = trimmed.firstIndex(of: "\n")
        if let colon = trimmed.firstIndex(of: ":"),
           firstNewline == nil || colon < firstNewline! {
            let rest = trimmed[trimmed.index(after: colon)...]
                .drop(while: { $0 == " " || $0 == "\n" })
            if !rest.isEmpty { return String(rest) }
        }
        if let newline = firstNewline {
            let rest = trimmed[trimmed.index(after: newline)...]
                .drop(while: { $0 == "\n" || $0 == " " })
            if !rest.isEmpty { return String(rest) }
        }
        return text
    }

    // MARK: - Matching internals

    /// Lowercased, trimmed, trailing sentence punctuation removed, internal
    /// whitespace collapsed. Deliberately does NOT strip filler words (unlike
    /// `SpokenPhraseNormalizer`) — an instruction ABOUT fillers ("remove the
    /// ums") must survive normalization intact.
    static func normalizeInstruction(_ raw: String) -> String {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".,!?;:".contains(last) {
            text.removeLast()
        }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func contains(_ haystack: String, anyOf needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static let numberedNeedles = [
        "numbered list", "number list", "ordered list", "numbered",
        "number these", "number this", "as numbers",
    ]
    private static let bulletNeedles = [
        "bullet", "a list", "list this", "list these",
        "into a list", "as a list", "in a list", "make a list",
    ]
    private static let joinNeedles = [
        "one line", "single line", "on one line",
        "one paragraph", "single paragraph", "into one paragraph", "as one paragraph",
        "join these", "join the line", "join lines",
        "merge these", "merge the line", "merge lines", "combine into one",
    ]
    private static let uppercaseNeedles = [
        "uppercase", "upper case", "all caps", "capital letters",
        "in caps", "to caps", "make it caps", "make this caps",
    ]
    private static let lowercaseNeedles = [
        "lowercase", "lower case", "no caps", "all lower",
    ]
    private static let titleCaseNeedles = [
        "title case", "titlecase", "capitalize", "capitalise",
        "capital case", "start case",
    ]
    private static let fillerNeedles = [
        "filler", "remove the ums", "ums and uhs", "remove ums",
        "take out the ums", "get rid of the ums",
    ]

    private static let preamblePrefixes = [
        "here is", "here's", "here are", "here you go",
        "sure, here", "sure! here", "sure here",
        "certainly, here", "certainly here", "okay, here", "ok, here",
    ]
}
