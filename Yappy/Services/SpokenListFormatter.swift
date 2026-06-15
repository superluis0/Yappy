//
//  SpokenListFormatter.swift
//  Yappy
//

import Foundation

/// Turns a spoken enumeration into a formatted numbered list. Runs *after*
/// `SpokenNumberFormatter`, so the counters already read as digits:
///
///   "going to the store for 1 apples 2 bananas 3 oranges"
///     → "going to the store for\n1. Apples\n2. Bananas\n3. Oranges"
///
///   "step 1 grab milk step 2 pay step 3 leave"   // shared lead-in word
///     → "1. Grab milk\n2. Pay\n3. Leave"
///
/// Conservative by design: it only fires on a run of **at least three** counters
/// that start at 1 and increase by exactly one, each followed by real words. A
/// stray "press 1 for sales" or "I need 1 thing from 2 stores" is left alone.
enum SpokenListFormatter {

    /// One detected counter: its integer value, the span of the digits, and the
    /// plain word spoken immediately before it (a shared one like "step" is
    /// treated as part of the marker, not the item text).
    private struct Marker {
        let value: Int
        let numberRange: NSRange
        let precedingWord: String?
        let precedingWordLocation: Int   // valid only when precedingWord != nil

        var numberEnd: Int { numberRange.location + numberRange.length }
    }

    /// An integer that begins a token (start or whitespace before it) and is
    /// followed by whitespace + more content — i.e. a plausible "N <item>".
    /// Anchoring on whitespace keeps "$20", "3:30", and "11.6" out.
    private static let markerRegex = try! NSRegularExpression(
        pattern: "(?:(?<=\\s)|^)(\\d+)(?=\\s+\\S)"
    )

    static func format(_ text: String) -> String {
        // Cheap bail: a list must contain a standalone "1".
        guard text.contains("1") else { return text }

        let ns = text as NSString
        let markers = findMarkers(in: ns)
        guard let run = monotonicRunFromOne(markers, in: ns), run.count >= 3 else {
            return text
        }

        let label = sharedLabel(in: run)
        return render(ns: ns, run: run, label: label)
    }

    // MARK: - Detection

    private static func findMarkers(in ns: NSString) -> [Marker] {
        let full = NSRange(location: 0, length: ns.length)
        return markerRegex.matches(in: ns as String, range: full).compactMap { match in
            let numberRange = match.range(at: 1)
            guard numberRange.location != NSNotFound,
                  let value = Int(ns.substring(with: numberRange)) else { return nil }
            let (word, location) = precedingWord(in: ns, before: numberRange.location)
            return Marker(value: value, numberRange: numberRange,
                          precedingWord: word, precedingWordLocation: location)
        }
    }

    /// The run of letters immediately before `location`, skipping a single
    /// stretch of whitespace ("step 1" → "step"). Returns nil when the counter
    /// isn't preceded by a word (start of text, or punctuation).
    private static func precedingWord(in ns: NSString, before location: Int) -> (String?, Int) {
        var i = location
        while i > 0, isWhitespace(ns.character(at: i - 1)) { i -= 1 }
        let wordEnd = i
        while i > 0, isLetter(ns.character(at: i - 1)) { i -= 1 }
        guard i < wordEnd else { return (nil, 0) }
        return (ns.substring(with: NSRange(location: i, length: wordEnd - i)), i)
    }

    /// The longest leading run of markers valued 1, 2, 3, … with at least one
    /// letter of item text between consecutive counters (so "4 5 6" can't extend
    /// a list — there's nothing spoken between those numbers).
    private static func monotonicRunFromOne(_ markers: [Marker], in ns: NSString) -> [Marker]? {
        guard let start = markers.firstIndex(where: { $0.value == 1 }) else { return nil }
        var run = [markers[start]]
        var j = start + 1
        while j < markers.count {
            let prev = run[run.count - 1]
            let cur = markers[j]
            guard cur.value == prev.value + 1,
                  hasLetter(in: ns, from: prev.numberEnd, to: cur.numberRange.location) else { break }
            run.append(cur)
            j += 1
        }
        return run
    }

    /// The lead-in word ("step", "number") shared by every counter, if any.
    private static func sharedLabel(in run: [Marker]) -> String? {
        guard let first = run.first?.precedingWord, !first.isEmpty else { return nil }
        let lowered = first.lowercased()
        for marker in run.dropFirst() {
            guard let word = marker.precedingWord, word.lowercased() == lowered else { return nil }
        }
        return first
    }

    // MARK: - Rendering

    private static func render(ns: NSString, run: [Marker], label: String?) -> String {
        func itemStart(_ marker: Marker) -> Int {
            label != nil ? marker.precedingWordLocation : marker.numberRange.location
        }

        let prefix = ns.substring(to: itemStart(run[0]))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        for (index, marker) in run.enumerated() {
            let contentStart = marker.numberEnd
            let contentEnd = index + 1 < run.count ? itemStart(run[index + 1]) : ns.length
            let raw = ns.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
            let item = capitalizeFirst(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("\(marker.value). \(item)")
        }

        let list = lines.joined(separator: "\n")
        let result = prefix.isEmpty ? list : prefix + "\n" + list
        return result
    }

    // MARK: - Helpers

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private static func hasLetter(in ns: NSString, from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        let slice = ns.substring(with: NSRange(location: from, length: to - from))
        return slice.contains { $0.isLetter }
    }

    private static func isWhitespace(_ unichar: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unichar) else { return false }
        return Character(scalar).isWhitespace
    }

    private static func isLetter(_ unichar: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unichar) else { return false }
        return Character(scalar).isLetter
    }
}
