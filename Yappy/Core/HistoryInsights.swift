//
//  HistoryInsights.swift
//  Yappy
//

import Foundation

/// A repeated dictation that's a good candidate to become a voice shortcut.
struct ShortcutSuggestion: Identifiable, Equatable {
    /// Normalized phrase — stable id, also used to remember dismissals.
    let id: String
    /// A representative original (untrimmed-case) phrase for display/expansion.
    let phrase: String
    /// How many times it was dictated.
    let count: Int
}

/// Derives proactive suggestions from dictation history. Pure and unit-tested —
/// no I/O, no stored state — mirroring `AliasMiner`'s style. Conservative on
/// purpose: a suggestion the user didn't want is worse than a missed one.
enum HistoryInsights {

    /// Dictations repeated verbatim (case/whitespace-insensitive) at least
    /// `minCount` times that aren't already a shortcut and haven't been dismissed.
    /// Restricted to short-to-medium phrases — a signature or boilerplate line,
    /// not a one-word blip or a whole paragraph.
    static func suggestedShortcuts(
        from entries: [DictationEntry],
        existing: [VoiceShortcut],
        dismissedKeys: Set<String> = [],
        minCount: Int = 3,
        minWords: Int = 2,
        maxWords: Int = 12,
        limit: Int = 3
    ) -> [ShortcutSuggestion] {
        var buckets: [String: (phrase: String, count: Int)] = [:]

        for entry in entries {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
            guard wordCount >= minWords, wordCount <= maxWords else { continue }

            let key = normalize(trimmed)
            guard !key.isEmpty else { continue }
            if let existingBucket = buckets[key] {
                buckets[key] = (existingBucket.phrase, existingBucket.count + 1)
            } else {
                buckets[key] = (trimmed, 1)
            }
        }

        let existingExpansions = Set(existing.map { normalize($0.expansion) })

        // Built as an explicit loop (a long filter/map/sort chain trips the
        // Swift type-checker's complexity limit here).
        var result: [ShortcutSuggestion] = []
        for (key, value) in buckets {
            guard value.count >= minCount else { continue }
            guard !existingExpansions.contains(key) else { continue }
            guard !dismissedKeys.contains(key) else { continue }
            result.append(ShortcutSuggestion(id: key, phrase: value.phrase, count: value.count))
        }
        result.sort { a, b in a.count != b.count ? a.count > b.count : a.phrase < b.phrase }
        return Array(result.prefix(limit))
    }

    /// Lowercased, whitespace-collapsed grouping key.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
