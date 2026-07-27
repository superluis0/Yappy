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
        "ellipsis": "…"
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
        "em": ["dash": "—"]
    ]

    /// Cheap substrings that gate the whole pass.
    private static let triggers = [
        "comma", "period", "colon", "semicolon", "hyphen", "dash",
        "question", "exclamation", "full stop", "paren", "bracket",
        "apostrophe", "ellipsis", "open quote", "close quote", "end quote",
        "forward slash", "em dash"
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

                // Single-word mark — skip when a determiner makes the noun reading certain.
                if let symbol = single[lw], !staysLiteralNoun(tokens: tokens, index: i) {
                    emit(symbol, into: &out, capitalizeNext: &capitalizeNext, gapAction: &gapAction)
                    i += 1
                    continue
                }

                // Ordinary word (including single-word marks kept as literal nouns).
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

    // MARK: - Prose guard (mark words stay as nouns)

    /// Determiners after which a single-word mark reads as a literal noun
    /// ("her period", "a dash of salt") rather than a punctuation command.
    ///
    /// The list is chosen on failure cost, not on grammar alone. Guarding too
    /// eagerly leaves the spoken word visible in the text, which the user can
    /// see and fix; not guarding silently deletes the word they actually said.
    /// Visible-and-wrong beats silent-and-destructive, so a determiner reading
    /// wins whenever it is the common one.
    ///
    /// Most entries genuinely cannot end a sentence, so suppressing after them
    /// can never swallow a real command. FOUR can, and each is kept on purpose:
    ///
    ///   "her" / "his"  — also pronouns ("I gave it to her.", "The book is his.")
    ///   "each"         — also adverbial ("They're five dollars each.")
    ///   "another"      — also a pronoun ("I'll take another.")
    ///
    /// After these, "…each period" keeps the literal word instead of ending the
    /// sentence. Accepted, because the reverse error is worse: "each period
    /// lasts twenty minutes" would otherwise become "each. Lasts twenty
    /// minutes", and "she missed her period" would become "she missed her." —
    /// both still read as grammatical English, so the user may never notice the
    /// words that went missing. A stray literal "period" is impossible to miss.
    ///
    /// Demonstratives ("this", "that", "these", "those") are deliberately absent:
    /// they double as pronouns AND commonly end sentences, so "I don't like that
    /// period" really does mean "I don't like that."
    private static let nounDeterminers: Set<String> = [
        "a", "an", "the",
        "my", "your", "his", "her", "its", "our", "their",
        "each", "every", "another"
    ]

    /// True when a single-word mark at `index` is preceded by a determiner and so
    /// should stay a literal word.
    ///
    /// Lookback is exactly one whitespace-only gap + one word. A gap that already
    /// contains punctuation (e.g. ",") means a different phrase and must not be
    /// skipped; a two-token window would wrongly suppress "the store comma …".
    static func staysLiteralNoun(tokens: [TranscriptTokenizer.Token], index: Int) -> Bool {
        guard index >= 2,
              case .gap(let gap) = tokens[index - 1], TranscriptTokenizer.isSpaceOnly(gap),
              case .word(let previous) = tokens[index - 2] else {
            return false
        }
        return nounDeterminers.contains(previous.lowercased())
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
