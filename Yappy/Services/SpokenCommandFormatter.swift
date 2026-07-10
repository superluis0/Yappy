//
//  SpokenCommandFormatter.swift
//  Yappy
//

import Foundation

/// Turns spoken formatting commands into real line breaks:
///
///   "Hello, new line, thanks"          → "Hello\nThanks"
///   "done. New paragraph. Next topic"  → "done.\n\nNext topic"
///   "first item, next line, second"    → "first item\nSecond"
///
/// Recognizes the line-break phrasings shared across Apple Dictation/Voice Control,
/// Dragon, Wispr Flow and Willow — "new line", "next line", "line break",
/// "insert line", "new paragraph", "next paragraph", "skip a line".
///
/// Conservative: a command only matches when it is set off on BOTH sides by the
/// start/end of the utterance or punctuation — the pauses Parakeet transcribes
/// around a spoken command. Plain prose like "a new line of products" or "insert
/// line 5 here" has ordinary spaces around it and is never touched.
enum SpokenCommandFormatter {

    private typealias Token = TranscriptTokenizer.Token

    /// Spoken phrase (lowercased words) → the break it inserts. Tried longest-first so
    /// "skip a line" is matched as a unit rather than mis-parsed.
    private static let phrases: [(words: [String], breakText: String)] = [
        (["new", "paragraph"], "\n\n"),
        (["next", "paragraph"], "\n\n"),
        (["skip", "a", "line"], "\n\n"),
        (["new", "line"], "\n"),
        (["next", "line"], "\n"),
        (["line", "break"], "\n"),
        (["insert", "line"], "\n"),
    ].sorted { $0.words.count > $1.words.count }

    /// Cheap substring gate: skip tokenizing entirely unless a phrase could be present.
    private static let triggers = [
        "new line", "next line", "line break", "insert line",
        "new paragraph", "next paragraph", "skip a line",
    ]

    /// Punctuation that can anchor a command boundary.
    private static let anchors: Set<Character> = [".", ",", ";", ":", "!", "?", "\n"]

    static func apply(_ text: String) -> String {
        let lowered = text.lowercased()
        guard triggers.contains(where: { lowered.contains($0) }) else { return text }

        let tokens = TranscriptTokenizer.tokenize(text)
        var output: [Token] = []
        var hasEmittedWord = false
        var capitalizeNextWord = false
        var i = 0

        while i < tokens.count {
            guard case .word(let word) = tokens[i] else {
                output.append(tokens[i])
                i += 1
                continue
            }

            guard let (breakText, tokenCount) = matchedPhrase(tokens, at: i),
                  isLeftAnchored(output: output, hasEmittedWord: hasEmittedWord),
                  isRightAnchored(tokens, afterCommandAt: i + tokenCount - 1) else {
                output.append(.word(capitalizeNextWord ? word.capitalizedFirstCharacter() : word))
                capitalizeNextWord = false
                hasEmittedWord = true
                i += 1
                continue
            }

            // Trim the pause punctuation that introduced the command, keeping
            // real sentence ends ("Hello," → "Hello"; "Hello." stays).
            if case .gap(let g)? = output.last {
                output.removeLast()
                let trimmed = trimLeftGap(g)
                if !trimmed.isEmpty {
                    output.append(.gap(trimmed))
                }
            }
            output.append(.gap(breakText))

            // Consume the command's own trailing pause ("new line," / "new line.").
            var next = i + tokenCount
            if next < tokens.count, case .gap(let g) = tokens[next] {
                let remainder = trimRightGap(g)
                if !remainder.isEmpty {
                    output.append(.gap(remainder))
                }
                next += 1
            }
            capitalizeNextWord = true
            i = next
        }

        var rendered = TranscriptTokenizer.render(output)
        // A trailing break is kept — dictating "new line" at the end is a
        // spoken Enter. Only stray trailing spaces are dropped.
        while rendered.hasSuffix(" ") {
            rendered.removeLast()
        }
        return rendered
    }

    // MARK: - Phrase matching

    /// If a command phrase starts at `index`, returns the break to insert and how many
    /// tokens it spans. Longest phrase wins.
    private static func matchedPhrase(_ tokens: [Token], at index: Int) -> (breakText: String, tokenCount: Int)? {
        for phrase in phrases {
            if let count = matchLength(tokens, at: index, words: phrase.words) {
                return (phrase.breakText, count)
            }
        }
        return nil
    }

    /// The number of tokens spanned if `words` match consecutive word-tokens starting
    /// at `index`, each adjacent pair separated by a single-space gap; otherwise nil.
    private static func matchLength(_ tokens: [Token], at index: Int, words: [String]) -> Int? {
        var t = index
        for (offset, word) in words.enumerated() {
            guard t < tokens.count, case .word(let actual) = tokens[t],
                  actual.lowercased() == word else { return nil }
            t += 1
            if offset < words.count - 1 {
                guard t < tokens.count, case .gap(" ") = tokens[t] else { return nil }
                t += 1
            }
        }
        return t - index
    }

    // MARK: - Anchoring

    private static func isLeftAnchored(output: [Token], hasEmittedWord: Bool) -> Bool {
        guard hasEmittedWord else { return true } // start of utterance
        if case .gap(let g)? = output.last {
            return g.contains(where: { anchors.contains($0) })
        }
        return false
    }

    private static func isRightAnchored(_ tokens: [Token], afterCommandAt index: Int) -> Bool {
        guard index + 1 < tokens.count else { return true } // end of utterance
        guard case .gap(let g) = tokens[index + 1] else { return false }
        if g.contains(where: { anchors.contains($0) }) { return true }
        return index + 2 >= tokens.count // trailing spaces at the very end
    }

    // MARK: - Gap Trimming

    /// The gap before a command: keep sentence punctuation, drop the pause
    /// comma and surrounding spaces (a newline follows immediately).
    private static func trimLeftGap(_ gap: String) -> String {
        var result = Substring(gap)
        while let last = result.last, last == " " || last == "," {
            result.removeLast()
        }
        return String(result)
    }

    /// The gap after a command: its comma/period is the command's own pause —
    /// drop it along with surrounding spaces.
    private static func trimRightGap(_ gap: String) -> String {
        var result = Substring(gap)
        while let first = result.first, first == " " || first == "," || first == "." {
            result.removeFirst()
        }
        return String(result)
    }

}
