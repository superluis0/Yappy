//
//  SpokenNumberFormatter.swift
//  Yappy
//

import Foundation

/// Converts spoken-out numbers into digits — the inverse text normalization that
/// the Parakeet model does not perform itself. So "eleven point six point zero"
/// becomes "11.6.0", "twenty three" becomes "23", and "three point one four"
/// becomes "3.14".
///
/// Deterministic and fully local (no LLM). Conservative by design: it only
/// rewrites maximal runs of number words, leaves all other text untouched, and
/// declines ambiguous cases (e.g. a bare scale word like "million") rather than
/// guessing.
enum SpokenNumberFormatter {

    // MARK: - Public

    static func format(_ text: String) -> String {
        let tokens = tokenize(text)
        guard tokens.contains(where: { if case .word(let w) = $0 { return isNumberWord(w.lowercased()) } else { return false } }) else {
            return text
        }

        var output = ""
        var i = 0
        while i < tokens.count {
            guard case .word(let word) = tokens[i], isNumberWord(word.lowercased()) else {
                output += tokens[i].text
                i += 1
                continue
            }

            // Collect a maximal run of number words (and internal "point"
            // separators) joined only by spaces.
            var runIndices = [i]
            var k = i
            while k + 2 < tokens.count,
                  case .gap(let gap) = tokens[k + 1], isSpaceOnly(gap),
                  case .word(let next) = tokens[k + 2],
                  isRunWord(next.lowercased()) {
                runIndices.append(k + 2)
                k += 2
            }

            // A trailing "point" is the literal word, not a decimal separator.
            while let last = runIndices.last,
                  case .word(let w) = tokens[last], w.lowercased() == "point" {
                runIndices.removeLast()
            }

            let words = runIndices.map { idx -> String in
                if case .word(let w) = tokens[idx] { return w.lowercased() }
                return ""
            }
            let lastIdx = runIndices.last ?? i

            if let converted = convertRun(words) {
                output += converted
            } else {
                // Emit the original substring (words + their joining spaces) untouched.
                for idx in i...lastIdx { output += tokens[idx].text }
            }
            i = lastIdx + 1
        }
        return output
    }

    // MARK: - Run Conversion

    /// Converts a run of number words (with optional internal "point" separators)
    /// to its digit form, or nil if the run is ambiguous and should be left alone.
    private static func convertRun(_ words: [String]) -> String? {
        // Split into segments around the decimal/version separator.
        var segments: [[String]] = [[]]
        for word in words {
            if word == "point" {
                segments.append([])
            } else {
                segments[segments.count - 1].append(word)
            }
        }

        guard let firstSegment = segments.first, !firstSegment.isEmpty,
              let whole = parseCardinal(firstSegment) else {
            return nil
        }

        var result = String(whole)
        for segment in segments.dropFirst() {
            guard !segment.isEmpty, let fractional = parseFractional(segment) else {
                return nil
            }
            result += "." + fractional
        }
        return result
    }

    /// Parses a run of cardinal number words into an integer, e.g.
    /// ["one", "hundred", "twenty", "three"] -> 123. Returns nil for a run made
    /// only of scale words ("hundred", "million") with no leading count, since
    /// those are usually idiomatic ("one in a million") rather than literal.
    private static func parseCardinal(_ words: [String]) -> Int? {
        var result = 0
        var current = 0
        var sawSmall = false

        for word in words {
            if let value = smallNumbers[word] {
                current += value
                sawSmall = true
            } else if let scale = scales[word] {
                if scale == 100 {
                    current = (current == 0 ? 1 : current) * 100
                } else {
                    result += (current == 0 ? 1 : current) * scale
                    current = 0
                }
            } else {
                return nil
            }
        }

        let total = result + current
        // A bare scale word ("hundred", "million") — no actual count — is left alone.
        guard sawSmall else { return nil }
        return total
    }

    /// Parses the part after a decimal/version "point". Digits spoken individually
    /// ("one four" -> "14", "zero six" -> "06") are concatenated to preserve
    /// leading zeros; otherwise the segment is read as a cardinal ("twenty five"
    /// -> "25", "fourteen" -> "14").
    private static func parseFractional(_ words: [String]) -> String? {
        if words.allSatisfy({ singleDigits[$0] != nil }) {
            return words.map { String(singleDigits[$0]!) }.joined()
        }
        guard let value = parseCardinal(words) else { return nil }
        return String(value)
    }

    // MARK: - Vocabulary

    private static let singleDigits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    private static func isNumberWord(_ word: String) -> Bool {
        smallNumbers[word] != nil || scales[word] != nil
    }

    /// Words allowed to extend a run: number words plus the internal "point".
    private static func isRunWord(_ word: String) -> Bool {
        word == "point" || isNumberWord(word)
    }

    // MARK: - Tokenizing

    private enum Token {
        case word(String)
        case gap(String)

        var text: String {
            switch self {
            case .word(let w): return w
            case .gap(let g): return g
            }
        }
    }

    /// Splits text into alternating runs of letters (words) and everything else
    /// (gaps), preserving every character so the input can be rebuilt exactly.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsLetter: Bool?

        for char in text {
            let isLetter = char.isLetter
            if currentIsLetter == nil {
                currentIsLetter = isLetter
                current.append(char)
            } else if isLetter == currentIsLetter {
                current.append(char)
            } else {
                tokens.append(currentIsLetter! ? .word(current) : .gap(current))
                current = String(char)
                currentIsLetter = isLetter
            }
        }
        if let currentIsLetter, !current.isEmpty {
            tokens.append(currentIsLetter ? .word(current) : .gap(current))
        }
        return tokens
    }

    private static func isSpaceOnly(_ gap: String) -> Bool {
        !gap.isEmpty && gap.allSatisfy { $0 == " " }
    }
}
