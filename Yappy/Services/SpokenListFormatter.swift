//
//  SpokenListFormatter.swift
//  Yappy
//

import Foundation

/// Turns a spoken enumeration into a formatted numbered list, working on the
/// real, messy transcript a speech model produces — number words *or* digits,
/// ordinals, an optional lead-in word, and the commas/periods the model adds:
///
///   "one milk two eggs three bread"
///     → "1. Milk\n2. Eggs\n3. Bread"
///   "number one, we need X. number two, we need Y. number three, we need Z"
///     → "1. We need X.\n2. We need Y.\n3. We need Z."
///   "first grab milk second pay third leave"
///     → "1. Grab milk\n2. Pay\n3. Leave"
///
/// Conservative: it only fires on a run of **at least three** counters that go
/// 1, 2, 3, … starting at one, each followed by real words. A stray "I have one
/// cat and two dogs" or "press one for sales" is left alone. Works whether or
/// not the number formatter has already turned the counters into digits.
enum SpokenListFormatter {

    // 1–20 covers any practical spoken list.
    private static let cardinals: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20,
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
    ]

    private struct Marker {
        let value: Int
        let matchStart: Int   // start of the lead-in word, or the counter itself
        let contentStart: Int // first content character after the counter + separators
    }

    /// One counter: an optional lead-in ("number", "step"…), then a digit run or
    /// a cardinal/ordinal word, then a separator (so a real item follows). The
    /// left guard keeps "$20", "v2", and "mp3" out; the right guard keeps clock
    /// times ("1:30") and decimals ("1.5") out.
    private static let markerRegex: NSRegularExpression = {
        let words = (Array(cardinals.keys) + Array(ordinals.keys))
            .sorted { $0.count > $1.count }   // longest first so "twenty" beats "two"
            .joined(separator: "|")
        let pattern = "(?<![\\w$£€#@])(?:(?:number|step|item|point|part|section)\\s+)?"
            + "(\\d+|\(words))(?=[\\s,)]|[.:](?!\\d))"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let separators: Set<Character> = [" ", "\t", "\n", ",", ".", ":", ")"]

    static func format(_ text: String) -> String {
        let ns = text as NSString
        let markers = findMarkers(in: ns)
        guard let run = monotonicRunFromOne(markers, in: ns), run.count >= 3 else {
            return text
        }
        return render(ns: ns, run: run)
    }

    // MARK: - Detection

    private static func findMarkers(in ns: NSString) -> [Marker] {
        let full = NSRange(location: 0, length: ns.length)
        return markerRegex.matches(in: ns as String, range: full).compactMap { match in
            let valueRange = match.range(at: 1)
            guard valueRange.location != NSNotFound,
                  let value = parseValue(ns.substring(with: valueRange)) else { return nil }

            // Skip the counter's trailing separators to find where the item text begins.
            var contentStart = valueRange.location + valueRange.length
            while contentStart < ns.length,
                  let scalar = Unicode.Scalar(ns.character(at: contentStart)),
                  separators.contains(Character(scalar)) {
                contentStart += 1
            }
            return Marker(value: value, matchStart: match.range.location, contentStart: contentStart)
        }
    }

    private static func parseValue(_ token: String) -> Int? {
        if let n = Int(token) { return n }
        let lower = token.lowercased()
        return cardinals[lower] ?? ordinals[lower]
    }

    /// The longest leading run valued 1, 2, 3, … with at least one letter of item
    /// text between consecutive counters.
    private static func monotonicRunFromOne(_ markers: [Marker], in ns: NSString) -> [Marker]? {
        guard let start = markers.firstIndex(where: { $0.value == 1 }) else { return nil }
        var run = [markers[start]]
        var j = start + 1
        while j < markers.count {
            let prev = run[run.count - 1]
            let cur = markers[j]
            guard cur.value == prev.value + 1,
                  hasLetter(in: ns, from: prev.contentStart, to: cur.matchStart) else { break }
            run.append(cur)
            j += 1
        }
        return run
    }

    // MARK: - Rendering

    private static func render(ns: NSString, run: [Marker]) -> String {
        let prefix = ns.substring(to: run[0].matchStart)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        for (index, marker) in run.enumerated() {
            let end = index + 1 < run.count ? run[index + 1].matchStart : ns.length
            guard marker.contentStart < end else { continue }
            let raw = ns.substring(with: NSRange(location: marker.contentStart, length: end - marker.contentStart))
            let item = capitalizeFirst(trimItem(raw))
            guard !item.isEmpty else { continue }
            lines.append("\(marker.value). \(item)")
        }
        guard lines.count >= 3 else { return ns as String }

        let list = lines.joined(separator: "\n")
        return prefix.isEmpty ? list : prefix + "\n" + list
    }

    private static func trimItem(_ s: String) -> String {
        // Drop surrounding whitespace and any trailing list separator the speaker
        // ran into the next counter (", " / ". ").
        var result = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, last == "," || last == ";" {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private static func hasLetter(in ns: NSString, from: Int, to: Int) -> Bool {
        guard to > from, from >= 0, to <= ns.length else { return false }
        let slice = ns.substring(with: NSRange(location: from, length: to - from))
        return slice.contains { $0.isLetter }
    }
}

/// Turns a spoken bulleted enumeration into a Markdown bullet list — the "bullet"
/// cue Willow and Dragon use, which Wispr Flow paywalls behind Command Mode:
///
///   "bring the following. Bullet milk. Bullet eggs. Bullet bread"
///     → "bring the following.\n- Milk\n- Eggs\n- Bread"
///
/// Conservative like SpokenListFormatter: fires only on **at least two** "bullet"
/// (or "bullet point") markers, each set off from the prior item by the start of
/// the utterance or sentence punctuation. "The bullet hit the wall" or a lone
/// "add a bullet point here" is left alone.
enum SpokenBulletFormatter {

    private static let markerRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}])bullets?(?:\\s+points?)?",
        options: [.caseInsensitive])

    private static let anchors: Set<Character> = [".", ",", ";", ":", "!", "?", "\n"]
    private static let separators: Set<Character> = [" ", "\t", "\n", ",", ".", ":"]

    private struct Marker {
        let matchStart: Int
        let contentStart: Int
        let anchored: Bool
    }

    static func format(_ text: String) -> String {
        guard text.lowercased().contains("bullet") else { return text }
        let ns = text as NSString
        let markers = allMarkers(in: ns)
        // A list starts at the first marker sitting at a clause boundary (utterance
        // start or after sentence punctuation); every "bullet" after it continues the
        // list. This fires on "bullet milk bullet eggs" yet leaves prose like "the
        // bullet hit and the bullet missed" — which has no anchored marker — alone.
        guard let start = markers.firstIndex(where: { $0.anchored }) else { return text }
        let run = Array(markers[start...])
        guard run.count >= 2 else { return text }
        return render(ns: ns, markers: run)
    }

    private static func allMarkers(in ns: NSString) -> [Marker] {
        let full = NSRange(location: 0, length: ns.length)
        return markerRegex.matches(in: ns as String, range: full).map { match in
            var contentStart = match.range.location + match.range.length
            while contentStart < ns.length,
                  let scalar = Unicode.Scalar(ns.character(at: contentStart)),
                  separators.contains(Character(scalar)) {
                contentStart += 1
            }
            return Marker(matchStart: match.range.location,
                          contentStart: contentStart,
                          anchored: isAnchored(ns: ns, before: match.range.location))
        }
    }

    /// Valid only when, scanning back over spaces, we reach the start of the
    /// utterance or a sentence-punctuation anchor.
    private static func isAnchored(ns: NSString, before location: Int) -> Bool {
        var i = location - 1
        while i >= 0, let scalar = Unicode.Scalar(ns.character(at: i)),
              scalar == " " || scalar == "\t" {
            i -= 1
        }
        guard i >= 0 else { return true }
        guard let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
        return anchors.contains(Character(scalar))
    }

    private static func render(ns: NSString, markers: [Marker]) -> String {
        let prefix = ns.substring(to: markers[0].matchStart)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        for (index, marker) in markers.enumerated() {
            let end = index + 1 < markers.count ? markers[index + 1].matchStart : ns.length
            guard marker.contentStart < end else { continue }
            let raw = ns.substring(with: NSRange(location: marker.contentStart, length: end - marker.contentStart))
            let item = capitalizeFirst(trimItem(raw))
            guard !item.isEmpty else { continue }
            lines.append("- \(item)")
        }
        guard lines.count >= 2 else { return ns as String }

        let list = lines.joined(separator: "\n")
        return prefix.isEmpty ? list : prefix + "\n" + list
    }

    private static func trimItem(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, last == "," || last == ";" || last == "." {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
