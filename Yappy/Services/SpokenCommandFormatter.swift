//
//  SpokenCommandFormatter.swift
//  Yappy
//

import Foundation

/// Turns spoken formatting commands into real line breaks:
///
///   "Hello, new line, thanks"          → "Hello\nThanks"
///   "done. New paragraph. Next topic"  → "done.\n\nNext topic"
///
/// Conservative: a command only matches when it is set off on BOTH sides by
/// the start/end of the utterance or punctuation — the pauses Parakeet
/// transcribes around a spoken command. Plain prose like "a new line of
/// products" has ordinary spaces around it and is never touched.
enum SpokenCommandFormatter {

    private typealias Token = TranscriptTokenizer.Token

    private static let commands: [String: String] = [
        "line": "\n",
        "paragraph": "\n\n",
    ]

    /// Punctuation that can anchor a command boundary.
    private static let anchors: Set<Character> = [".", ",", ";", ":", "!", "?", "\n"]

    static func apply(_ text: String) -> String {
        let lowered = text.lowercased()
        guard lowered.contains("new line") || lowered.contains("new paragraph") else {
            return text
        }

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

            guard word.lowercased() == "new",
                  i + 2 < tokens.count,
                  case .gap(" ") = tokens[i + 1],
                  case .word(let second) = tokens[i + 2],
                  let breakText = commands[second.lowercased()],
                  isLeftAnchored(output: output, hasEmittedWord: hasEmittedWord),
                  isRightAnchored(tokens, afterCommandAt: i + 2) else {
                output.append(.word(capitalizeNextWord ? capitalized(word) : word))
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
            var next = i + 3
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

    private static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
