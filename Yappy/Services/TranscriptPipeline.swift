//
//  TranscriptPipeline.swift
//  Yappy
//

import Foundation

/// Result of running the local transcript pipeline.
/// - `formatted`: ran the normal deterministic stages.
/// - `verbatim`: utterance began with a "type literally" / "type exactly"
///   escape prefix; remainder is untouched and must bypass cleanup + voice
///   command/edit parsing downstream.
struct TranscriptPipelineResult: Equatable {
    let text: String
    let isVerbatim: Bool
}

/// Chains the local transcript cleanups in their required order:
/// **verbatim-escape first**, then fillers → numbers → lists → line-break
/// commands → punctuation. Runs on the raw Parakeet output, before
/// user-authored shortcut expansions (which must stay verbatim). Lists run
/// after numbers so the spoken counters already read as digits; punctuation
/// runs last so it can hug the words it lands against.
///
/// Order note: the verbatim-prefix parse runs *before* spoken-punctuation
/// formatting, so "type literally colon hello" keeps the spoken word
/// "colon" (not a ":" glyph). Callers that need to skip voice-edit parsing
/// for a verbatim remainder should check `stripVerbatimPrefix` (or
/// `isVerbatim` on the result) *before* running voice-edit / voice-control
/// parsers on the raw utterance.
struct TranscriptPipeline {
    var removeFillers: Bool
    var formatNumbers: Bool
    var formatLists: Bool
    var applyCommands: Bool
    var applyPunctuation: Bool

    func process(_ raw: String) -> String {
        processDetailed(raw).text
    }

    /// Same as `process`, but reports whether a verbatim escape fired so the
    /// caller can bypass cleanup and voice-command handling.
    func processDetailed(_ raw: String) -> TranscriptPipelineResult {
        if let remainder = Self.stripVerbatimPrefix(raw) {
            return TranscriptPipelineResult(text: remainder, isVerbatim: true)
        }
        var text = raw
        if removeFillers { text = FillerWordRemover.remove(text) }
        if formatNumbers { text = SpokenNumberFormatter.format(text) }
        if formatLists {
            text = SpokenListFormatter.format(text)
            text = SpokenBulletFormatter.format(text)
        }
        if applyCommands { text = SpokenCommandFormatter.apply(text) }
        if applyPunctuation { text = SpokenPunctuationFormatter.apply(text) }
        return TranscriptPipelineResult(text: text, isVerbatim: false)
    }

    // MARK: - Verbatim escape

    /// Spoken prefixes that mean "insert the rest exactly as heard".
    /// Matched case-insensitively at the start of the utterance only.
    private static let verbatimPrefixes = [
        "type literally",
        "type exactly"
    ]

    /// If `raw` begins with a whole-prefix verbatim escape ("type literally" /
    /// "type exactly", optional trailing colon or comma), returns the remainder
    /// with the prefix stripped and leading whitespace removed. Nil when no
    /// escape applies. Whole-prefix only — "type literally-ish" does not match.
    static func stripVerbatimPrefix(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        for prefix in verbatimPrefixes {
            guard lower.hasPrefix(prefix) else { continue }
            var rest = trimmed.dropFirst(prefix.count)
            // Optional spoken/typed separator after the prefix.
            if rest.first == ":" || rest.first == "," {
                rest = rest.dropFirst()
            }
            // Require a word boundary after the prefix (space, end, or the
            // separator we just consumed). Reject "type literallyX".
            if let first = rest.first, !first.isWhitespace, first != ":" && first != "," {
                // Already consumed separator above; if rest starts with a letter
                // glued to the prefix, the prefix didn't stand alone.
                // e.g. "type literallyish" → rest starts with "ish" after prefix.
                // After optional separator strip, if the original char after
                // prefix wasn't whitespace/separator, fail.
                let afterPrefix = trimmed.dropFirst(prefix.count)
                if let c = afterPrefix.first, !c.isWhitespace, c != ":", c != "," {
                    continue
                }
            }
            let remainder = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty remainder (just the prefix) is still a successful strip —
            // caller inserts nothing.
            return remainder
        }
        return nil
    }

    /// True when the utterance is a verbatim-escape dictation (prefix present).
    static func isVerbatimEscape(_ raw: String) -> Bool {
        stripVerbatimPrefix(raw) != nil
    }
}
