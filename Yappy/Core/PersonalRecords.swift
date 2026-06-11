//
//  PersonalRecords.swift
//  Yappy
//

import Foundation

/// All-time personal bests, computed from dictation history.
struct PersonalRecords: Equatable {
    let fastestWPM: Int
    let longestStreakDays: Int
    let biggestDayWords: Int
    let longestDictationWords: Int

    static let empty = PersonalRecords(
        fastestWPM: 0, longestStreakDays: 0, biggestDayWords: 0, longestDictationWords: 0)

    var hasAny: Bool {
        fastestWPM > 0 || longestStreakDays > 0 || biggestDayWords > 0 || longestDictationWords > 0
    }

    /// A WPM reading is only trusted for dictations at least this long with a few
    /// words, so a one-word blip doesn't post an absurd record.
    static let minDurationForWPM: Double = 2.0
    static let minWordsForWPM = 4

    static func compute(from entries: [DictationEntry], calendar: Calendar = .current) -> PersonalRecords {
        guard !entries.isEmpty else { return .empty }

        var fastestWPM = 0
        var longestDictation = 0
        for entry in entries {
            longestDictation = max(longestDictation, entry.wordCount)
            if entry.durationSeconds >= minDurationForWPM, entry.wordCount >= minWordsForWPM {
                let wpm = Int((Double(entry.wordCount) / entry.durationSeconds * 60.0).rounded())
                fastestWPM = max(fastestWPM, wpm)
            }
        }

        // Words per calendar day → biggest day.
        var wordsPerDay: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            wordsPerDay[day, default: 0] += entry.wordCount
        }
        let biggestDay = wordsPerDay.values.max() ?? 0

        return PersonalRecords(
            fastestWPM: fastestWPM,
            longestStreakDays: longestStreak(days: Set(wordsPerDay.keys), calendar: calendar),
            biggestDayWords: biggestDay,
            longestDictationWords: longestDictation
        )
    }

    /// The longest run of consecutive calendar days present in `days`.
    private static func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        var longest = 0
        for day in days {
            // Only start counting from the beginning of a run.
            let previous = calendar.date(byAdding: .day, value: -1, to: day)!
            if days.contains(previous) { continue }
            var run = 0
            var cursor = day
            while days.contains(cursor) {
                run += 1
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            }
            longest = max(longest, run)
        }
        return longest
    }
}

extension HistoryStore {
    var personalRecords: PersonalRecords { PersonalRecords.compute(from: entries) }
}
