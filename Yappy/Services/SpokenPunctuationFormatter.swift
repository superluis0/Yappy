//
//  SpokenPunctuationFormatter.swift
//  Yappy
//

import Foundation

/// Turns spoken punctuation marks into the real symbols, fixing the spacing
/// around them:
///
///   "hello comma world question mark"  → "Hello, world?"  (after cleanup caps)
///   "see open paren note close paren"  → "see (note)"
///   "done period next thought"         → "done. Next thought"
///
/// A mark is only converted when it's a standalone word token (the tokenizer
/// already guarantees whole-word boundaries, so "commas" and "comma-separated"
/// are safe). This matches how Apple Dictation and Dragon treat reserved mark
/// words — the trade-off being that literally saying "comma" inserts ",". The
/// feature is a toggle so users who dictate those words can turn it off.
/// Multi-word marks ("question mark") are unambiguous; the single common words
/// are the part that relies on the user knowing they're reserved.
enum SpokenPunctuationFormatter {

    private typealias Token = TranscriptTokenizer.Token

    /// Single spoken word → symbol.
    private static let single: [String: String] = [
        "comma": ",",
        "period": ".",
        "colon": ":",
        "semicolon": ";",
        "hyphen": "-",
        "dash": "-",
        "apostrophe": "'",
        "ellipsis": "…",
    ]

    /// First word → (second word → symbol), for two-word marks. Quotes and the
    /// forward slash are intentionally two-word only: a bare "quote" or "slash"
    /// collides with ordinary prose ("the famous quote", "slash the budget").
    private static let double: [String: [String: String]] = [
        "question": ["mark": "?"],
        "exclamation": ["mark": "!", "point": "!"],
        "full": ["stop": "."],
        "open": ["paren": "(", "parenthesis": "(", "parentheses": "(", "bracket": "[", "quote": "“"],
        "close": ["paren": ")", "parenthesis": ")", "parentheses": ")", "bracket": "]", "quote": "”"],
        "closed": ["paren": ")", "parenthesis": ")", "quote": "”"],
        "end": ["quote": "”"],
        "forward": ["slash": "/"],
        "em": ["dash": "—"],
    ]

    /// Cheap substrings that gate the whole pass.
    private static let triggers = [
        "comma", "period", "colon", "semicolon", "hyphen", "dash",
        "question", "exclamation", "full stop", "paren", "bracket",
        "apostrophe", "ellipsis", "open quote", "close quote", "end quote",
        "forward slash", "em dash",
    ]

    /// Marks that hug the preceding word and take a space after.
    private static let attachBefore: Set<String> = [",", ".", ";", ":", "!", "?", ")", "]", "…", "”"]
    /// Marks that take a space before and hug the following word.
    private static let openers: Set<String> = ["(", "[", "“"]
    /// Marks that hug words on both sides.
    private static let glue: Set<String> = ["-", "'", "/", "—"]
    /// Marks that start a new sentence after them.
    private static let sentenceEnders: Set<String> = [".", "!", "?"]

    /// What to do with the gap that follows an emitted mark.
    private enum GapAction { case keep, single, removeLeading }

    static func apply(_ text: String) -> String {
        let lowered = text.lowercased()
        guard triggers.contains(where: { lowered.contains($0) }) else { return text }

        let tokens = TranscriptTokenizer.tokenize(text)
        var out = ""
        var capitalizeNext = false
        var gapAction: GapAction = .keep
        var i = 0

        while i < tokens.count {
            switch tokens[i] {
            case .word(let word):
                let lw = word.lowercased()

                // Two-word mark ("question mark"): word + single-space gap + word.
                if i + 2 < tokens.count,
                   case .gap(let gap) = tokens[i + 1], TranscriptTokenizer.isSpaceOnly(gap),
                   case .word(let second) = tokens[i + 2],
                   let symbol = double[lw]?[second.lowercased()] {
                    emit(symbol, into: &out, capitalizeNext: &capitalizeNext, gapAction: &gapAction)
                    i += 3
                    continue
                }

                // Single-word mark.
                if let symbol = single[lw] {
                    emit(symbol, into: &out, capitalizeNext: &capitalizeNext, gapAction: &gapAction)
                    i += 1
                    continue
                }

                // Ordinary word.
                out += capitalizeNext ? word.capitalizedFirstCharacter() : word
                capitalizeNext = false
                gapAction = .keep
                i += 1

            case .gap(let gap):
                switch gapAction {
                case .keep:
                    out += gap
                case .single:
                    out += " "
                case .removeLeading:
                    var slice = Substring(gap)
                    while let first = slice.first, first == " " { slice.removeFirst() }
                    out += String(slice)
                }
                gapAction = .keep
                i += 1
            }
        }

        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    // MARK: - Emission

    private static func emit(
        _ symbol: String, into out: inout String,
        capitalizeNext: inout Bool, gapAction: inout GapAction
    ) {
        if attachBefore.contains(symbol) {
            while out.hasSuffix(" ") { out.removeLast() }
            out += symbol
            gapAction = .single
            if sentenceEnders.contains(symbol) { capitalizeNext = true }
        } else if openers.contains(symbol) {
            if !out.isEmpty, !out.hasSuffix(" "), !out.hasSuffix("("), !out.hasSuffix("[") {
                out += " "
            }
            out += symbol
            gapAction = .removeLeading
        } else { // glue, e.g. hyphen
            while out.hasSuffix(" ") { out.removeLast() }
            out += symbol
            gapAction = .removeLeading
        }
    }

}
