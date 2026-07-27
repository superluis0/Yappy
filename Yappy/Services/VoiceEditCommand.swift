//
//  VoiceEditCommand.swift
//  Yappy
//

import Foundation

/// A spoken instruction to edit the text Yappy just inserted — said as its own
/// utterance after a dictation ("scratch that", "all caps that").
enum VoiceEditCommand: Equatable {
    case deleteLast // remove the whole last insertion
    case deleteLastWord
    case deleteLastSentence
    case deleteLastLine
    case capitalizeThat // title-case the last insertion
    case allCapsThat
    case lowercaseThat
    case useRawTranscript // revert the last insertion to the pre-cleanup words
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
        "cap that": .capitalizeThat,
        "cap this": .capitalizeThat,

        "all caps that": .allCapsThat,
        "all caps this": .allCapsThat,
        "uppercase that": .allCapsThat,
        "make that uppercase": .allCapsThat,
        "make that all caps": .allCapsThat,

        "lowercase that": .lowercaseThat,
        "lowercase this": .lowercaseThat,
        "make that lowercase": .lowercaseThat,

        "use what i said": .useRawTranscript,
        "use what i actually said": .useRawTranscript,
        "undo the cleanup": .useRawTranscript,
        "undo that cleanup": .useRawTranscript
    ]

    static func parse(_ raw: String) -> VoiceEditCommand? {
        phrases[normalize(raw)]
    }

    /// Lowercased, fillers removed, surrounding punctuation/whitespace stripped,
    /// internal whitespace collapsed to single spaces.
    private static func normalize(_ raw: String) -> String {
        SpokenPhraseNormalizer.normalize(raw)
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
        // Not a string transform: reverting to the raw transcript is handled in
        // AppDelegate, which holds the pre-cleanup words.
        case .useRawTranscript: return nil
        }
    }
}

/// Detects a trailing "press enter" / "press return" — Wispr Flow's and Dragon's
/// gesture for submitting after dictation (it sends a real Return so a message,
/// search box, or cell commits). Returns the dictation with the command stripped
/// and whether to send Return. Conservative: only matches the phrase as the whole
/// utterance or at the very end, set off by a space — so "press enter to continue",
/// dictated as prose, is left intact because it isn't trailing.
enum SubmitCommandParser {
    private static let triggers = ["press enter", "press return", "hit enter", "hit return"]

    static func parse(_ raw: String) -> (text: String, submit: Bool) {
        // Match against a copy with trailing sentence punctuation and spaces removed.
        let core = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let lower = core.lowercased()
        for trigger in triggers {
            if lower == trigger {
                return ("", true)
            }
            if lower.hasSuffix(" " + trigger) {
                let kept = String(core.dropLast(trigger.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
                return (kept, true)
            }
        }
        return (raw, false)
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
        while i > 0, chars[i - 1].isWhitespace { i -= 1 } // trailing whitespace
        let afterWord = i
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 } // the word itself
        guard afterWord != i else { return chars.count - i } // (no word found)
        while i > 0, chars[i - 1].isWhitespace { i -= 1 } // separating whitespace
        return chars.count - i
    }

    /// The last sentence plus its leading separator. If there's no prior
    /// terminator, the whole text is one sentence.
    static func trailingSentenceLength(of text: String) -> Int {
        let chars = Array(text)
        var boundary: Int? // index of the terminator ending the PREVIOUS sentence
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

    /// The character offsets to select when reaching *back* over the last
    /// insertion: `length` characters ending at the caret sitting at `caretLocation`.
    /// Returns `nil` when the span would start before the field (a negative
    /// origin), which signals a stale/untrustworthy caret — the caller must not
    /// select (and delete) the wrong span. Pure so the arithmetic is unit-tested
    /// independently of the accessibility set-selection call that consumes it.
    /// - Returns: `(location, length)` for the selection, or `nil` if invalid.
    static func selectionRange(caretLocation: Int, length: Int) -> (location: Int, length: Int)? {
        guard length > 0, caretLocation >= length else { return nil }
        return (caretLocation - length, length)
    }
}
