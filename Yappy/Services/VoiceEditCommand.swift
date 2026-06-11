//
//  VoiceEditCommand.swift
//  Yappy
//

import Foundation

/// A spoken instruction to edit the text Yappy just inserted — said as its own
/// utterance after a dictation ("scratch that", "all caps that").
enum VoiceEditCommand: Equatable {
    case deleteLast          // remove the whole last insertion
    case deleteLastWord
    case deleteLastSentence
    case deleteLastLine
    case capitalizeThat      // title-case the last insertion
    case allCapsThat
    case lowercaseThat
}

/// Classifies a *whole utterance* as an edit command, or returns nil so the
/// words are dictated normally. Conservative by design: only an exact match of
/// the entire normalized utterance counts — "scratch that idea" is prose, not a
/// command. Mirrors SpokenCommandFormatter's anchored-only philosophy.
enum VoiceEditCommandParser {

    /// Exact normalized phrase → command. Synonyms are listed explicitly; no
    /// substring or in-sentence matching.
    private static let phrases: [String: VoiceEditCommand] = [
        "scratch that": .deleteLast,
        "scratch this": .deleteLast,
        "delete that": .deleteLast,
        "delete this": .deleteLast,
        "remove that": .deleteLast,

        "delete the last word": .deleteLastWord,
        "delete last word": .deleteLastWord,

        "delete the last sentence": .deleteLastSentence,
        "delete last sentence": .deleteLastSentence,

        "delete the last line": .deleteLastLine,
        "delete last line": .deleteLastLine,

        "capitalize that": .capitalizeThat,
        "capitalize this": .capitalizeThat,

        "all caps that": .allCapsThat,
        "all caps this": .allCapsThat,
        "uppercase that": .allCapsThat,
        "make that uppercase": .allCapsThat,
        "make that all caps": .allCapsThat,

        "lowercase that": .lowercaseThat,
        "lowercase this": .lowercaseThat,
        "make that lowercase": .lowercaseThat,
    ]

    static func parse(_ raw: String) -> VoiceEditCommand? {
        phrases[normalize(raw)]
    }

    /// Lowercased, fillers removed, surrounding punctuation/whitespace stripped,
    /// internal whitespace collapsed to single spaces.
    private static func normalize(_ raw: String) -> String {
        let deFilled = FillerWordRemover.remove(raw).lowercased()
        let edgeTrimmed = deFilled.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return edgeTrimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Case transforms

    /// The rewritten chunk for a case-change command, or nil for delete commands
    /// (which don't transform text).
    static func transform(_ command: VoiceEditCommand, applyingTo chunk: String) -> String? {
        switch command {
        case .capitalizeThat: return chunk.capitalized
        case .allCapsThat: return chunk.uppercased()
        case .lowercaseThat: return chunk.lowercased()
        case .deleteLast, .deleteLastWord, .deleteLastSentence, .deleteLastLine: return nil
        }
    }
}

/// Trailing-substring math for granular deletes, operating on the text Yappy
/// last inserted. Each function returns the number of trailing characters to
/// remove. Pure and unit-tested independently of keystroke synthesis.
enum TextEditMath {
    private static let terminators: Set<Character> = [".", "!", "?"]

    /// The last word plus the whitespace that separates it from the prior word.
    static func trailingWordLength(of text: String) -> Int {
        let chars = Array(text)
        var i = chars.count
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }          // trailing whitespace
        let afterWord = i
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 }          // the word itself
        guard afterWord != i else { return chars.count - i }        // (no word found)
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }           // separating whitespace
        return chars.count - i
    }

    /// The last sentence plus its leading separator. If there's no prior
    /// terminator, the whole text is one sentence.
    static func trailingSentenceLength(of text: String) -> Int {
        let chars = Array(text)
        var boundary: Int? = nil   // index of the terminator ending the PREVIOUS sentence
        for (k, ch) in chars.enumerated() where terminators.contains(ch) {
            let hasContentAfter = chars[(k + 1)...].contains {
                !$0.isWhitespace && !terminators.contains($0)
            }
            if hasContentAfter { boundary = k }
        }
        guard let boundary else { return chars.count }
        return chars.count - (boundary + 1)
    }

    /// The last line plus its leading newline. If there's no newline, the whole
    /// text is one line.
    static func trailingLineLength(of text: String) -> Int {
        let chars = Array(text)
        guard let lastNewline = chars.lastIndex(of: "\n") else { return chars.count }
        return chars.count - lastNewline
    }
}
