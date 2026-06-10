//
//  HeatmapModel.swift
//  Yappy
//

import Foundation

/// One cell of the activity heatmap.
struct HeatmapDay: Equatable, Identifiable {
    let date: Date
    let dictations: Int
    let words: Int
    /// Intensity bucket 0 (none) … 4 (most active).
    let level: Int

    var id: Date { date }
}

/// Pure day-bucketing for the contribution-style activity grid.
/// `today` and `calendar` are injectable so tests are date-stable.
enum HeatmapModel {
    /// Days for the trailing `weeks` weeks: from the start of the week
    /// `weeks - 1` weeks ago through today, in chronological order.
    static func days(
        entries: [DictationEntry],
        weeks: Int = 12,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [HeatmapDay] {
        let todayStart = calendar.startOfDay(for: today)
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: todayStart)?.start,
              let rangeStart = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeekStart) else {
            return []
        }

        // Single pass over entries → per-day totals.
        var totals: [Date: (dictations: Int, words: Int)] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            guard day >= rangeStart, day <= todayStart else { continue }
            var bucket = totals[day] ?? (0, 0)
            bucket.dictations += 1
            bucket.words += entry.wordCount
            totals[day] = bucket
        }

        var days: [HeatmapDay] = []
        var cursor = rangeStart
        while cursor <= todayStart {
            let bucket = totals[cursor] ?? (0, 0)
            days.append(HeatmapDay(
                date: cursor,
                dictations: bucket.dictations,
                words: bucket.words,
                level: level(forDictations: bucket.dictations)
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// Fixed, deterministic intensity buckets (count of dictations per day).
    static func level(forDictations count: Int) -> Int {
        switch count {
        case ..<1: return 0
        case 1: return 1
        case 2...3: return 2
        case 4...6: return 3
        default: return 4
        }
    }
}
