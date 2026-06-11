//
//  HeatmapModel.swift
//  Yappy
//

import Foundation

/// One day-of-week × hour cell of the activity heatmap.
struct HeatmapHourCell: Equatable {
    let count: Int
    let words: Int
    /// Intensity bucket 0 (none) … 4 (busiest), relative to the busiest cell.
    let level: Int
}

/// A row of the heatmap: one weekday with its 24 hourly cells.
struct HeatmapWeekday: Equatable, Identifiable {
    /// Calendar weekday, 1 (Sunday) … 7 (Saturday).
    let weekday: Int
    /// 24 cells, midnight … 11 PM.
    let hours: [HeatmapHourCell]

    var id: Int { weekday }
}

/// Buckets dictations by when they happened (weekday + hour of day) so the
/// heatmap shows the user's dictation rhythm. Pure and injectable for tests.
enum HeatmapModel {
    /// Rows ordered by the calendar's first weekday. Intensity is scaled to the
    /// busiest cell so the pattern reads regardless of total volume.
    static func hourlyRows(
        entries: [DictationEntry],
        calendar: Calendar = .current
    ) -> [HeatmapWeekday] {
        // counts[weekday(1...7)][hour(0...23)]
        var counts = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 8)
        var words = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 8)

        for entry in entries {
            let comps = calendar.dateComponents([.weekday, .hour], from: entry.date)
            guard let weekday = comps.weekday, let hour = comps.hour else { continue }
            counts[weekday][hour] += 1
            words[weekday][hour] += entry.wordCount
        }

        let maxCount = counts.flatMap { $0 }.max() ?? 0

        // Display order starts at the locale's first weekday (e.g. Sun or Mon).
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return order.map { weekday in
            let hours = (0..<24).map { hour in
                HeatmapHourCell(
                    count: counts[weekday][hour],
                    words: words[weekday][hour],
                    level: level(count: counts[weekday][hour], maxCount: maxCount)
                )
            }
            return HeatmapWeekday(weekday: weekday, hours: hours)
        }
    }

    /// The hour of day (0…23) with the most dictations, or nil if there are none.
    static func busiestHour(entries: [DictationEntry], calendar: Calendar = .current) -> Int? {
        var counts = [Int](repeating: 0, count: 24)
        for entry in entries {
            if let hour = calendar.dateComponents([.hour], from: entry.date).hour {
                counts[hour] += 1
            }
        }
        guard let maxCount = counts.max(), maxCount > 0 else { return nil }
        return counts.firstIndex(of: maxCount)
    }

    /// The weekday (1=Sunday…7=Saturday) with the most dictations, or nil.
    static func busiestWeekday(entries: [DictationEntry], calendar: Calendar = .current) -> Int? {
        var counts = [Int](repeating: 0, count: 8)
        for entry in entries {
            if let weekday = calendar.dateComponents([.weekday], from: entry.date).weekday {
                counts[weekday] += 1
            }
        }
        guard let maxCount = counts.max(), maxCount > 0 else { return nil }
        return counts.firstIndex(of: maxCount)
    }

    /// Intensity bucket (1…4) for a cell relative to the busiest cell, 0 if empty.
    static func level(count: Int, maxCount: Int) -> Int {
        guard count > 0 else { return 0 }
        guard maxCount > 0 else { return 1 }
        let scaled = Int((Double(count) * 4.0 / Double(maxCount)).rounded(.up))
        return min(4, max(1, scaled))
    }
}
