//
//  FillerWordRemover.swift
//  Yappy
//

import Foundation

/// Strips hesitation fillers ("um", "uh", "erm", "hmm") that Parakeet
/// faithfully transcribes, healing the surrounding punctuation and casing:
///
///   "Um, so I think"       → "So I think"
///   "I was, um, thinking"  → "I was thinking"
///   "Sounds good, um."     → "Sounds good."
///
/// Deliberately narrow: discourse words people may mean ("like", "you know",
/// "well") are never touched, and "Uh-huh" is preserved as an answer.
enum FillerWordRemover {

    private typealias Token = TranscriptTokenizer.Token

    private static let fillers: Set<String> = ["um", "uh", "erm", "hmm", "umm", "uhh", "uhm"]

    /// Punctuation that ends a sentence; the word after a removed filler at
    /// such a boundary gets recapitalized.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\n"]

    static func remove(_ text: String) -> String {
        let tokens = TranscriptTokenizer.tokenize(text)
        guard tokens.contains(where: {
            if case .word(let w) = $0 { return fillers.contains(w.lowercased()) }
            return false
        }) else {
            return text
        }

        var output: [Token] = []
        var hasEmittedWord = false
        var capitalizeNextWord = false
        var i = 0

        while i < tokens.count {
            switch tokens[i] {
            case .gap(let gap):
                output.append(.gap(gap))
                i += 1

            case .word(let word):
                let lower = word.lowercased()
                guard fillers.contains(lower), !isFollowedByHuh(tokens, at: i) else {
                    output.append(.word(capitalizeNextWord ? capitalized(word) : word))
                    capitalizeNextWord = false
                    hasEmittedWord = true
                    i += 1
                    continue
                }

                // Detach the gap before the filler (now the left context).
                var left: String?
                if case .gap(let g)? = output.last {
                    left = g
                    output.removeLast()
                }
                // Consume the gap after the filler (the right context).
                var right = ""
                var next = i + 1
                if next < tokens.count, case .gap(let g) = tokens[next] {
                    right = g
                    next += 1
                }

                let (merged, capitalize) = mergeGaps(
                    left: left, right: right, atSentenceStart: !hasEmittedWord)
                if !merged.isEmpty {
                    output.append(.gap(merged))
                }
                if capitalize { capitalizeNextWord = true }
                i = next
            }
        }

        guard hasEmittedWord else { return "" }

        var rendered = TranscriptTokenizer.render(output)
        while rendered.contains("  ") {
            rendered = rendered.replacingOccurrences(of: "  ", with: " ")
        }
        while rendered.hasSuffix(" ") {
            rendered.removeLast()
        }
        return rendered
    }

    // MARK: - Helpers

    /// Joins the punctuation on both sides of a removed filler into one gap.
    private static func mergeGaps(
        left: String?, right: String, atSentenceStart: Bool
    ) -> (gap: String, capitalizeNext: Bool) {
        // Filler opened the text ("Um, so…"): drop its punctuation entirely
        // and let the real first word start the sentence.
        if atSentenceStart {
            return ("", true)
        }

        // Strip the filler's own pause punctuation from the right side, but
        // keep sentence punctuation ("good, um." must keep the period).
        var rightRemainder = Substring(right)
        while let first = rightRemainder.first, first == " " || first == "," {
            rightRemainder.removeFirst()
        }

        // The filler carried the sentence end ("…, um. Next"): the boundary
        // survives and the comma pause before it is dropped.
        if let first = rightRemainder.first, sentenceEnders.contains(first) || first == ";" || first == ":" {
            return (String(rightRemainder), true)
        }

        // The filler followed a sentence end ("Done. Um, next"): keep the left
        // boundary and recapitalize what follows.
        if let left, left.contains(where: { sentenceEnders.contains($0) }) {
            return (left + rightRemainder, true)
        }

        // Mid-sentence pause ("I was, um, thinking"): collapse to one space.
        return (" ", false)
    }

    /// "Uh-huh" (or "uh huh") is an answer, not a filler.
    private static func isFollowedByHuh(_ tokens: [Token], at index: Int) -> Bool {
        guard index + 2 < tokens.count,
              case .gap = tokens[index + 1],
              case .word(let next) = tokens[index + 2] else {
            return false
        }
        return next.lowercased() == "huh"
    }

    private static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
