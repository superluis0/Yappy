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

/// The heatmap's LIFETIME accumulator: dictation counts and word counts per
/// weekday × hour, independent of the transcripts they came from. Persisted as
/// a sidecar next to history.json (the same pattern as the lifetime word/time
/// counters) so Clear All, per-entry deletes, the entry cap, and retention
/// pruning never erase the record of WHEN the user dictates — only transcripts
/// are removable; the rhythm is a tally, not content.
struct HeatmapTally: Codable, Equatable {
    /// counts[weekday(1...7)][hour(0...23)] — index 0 unused, matching the
    /// 1-based Calendar.weekday convention used throughout.
    var counts: [[Int]]
    var words: [[Int]]

    init() {
        counts = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 8)
        words = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 8)
    }

    var isEmpty: Bool {
        counts.allSatisfy { $0.allSatisfy { $0 == 0 } }
    }

    /// O(1) accumulation — safe on the add() latency path.
    mutating func record(date: Date, wordCount: Int, calendar: Calendar = .current) {
        let comps = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour,
              (1...7).contains(weekday), (0..<24).contains(hour) else { return }
        counts[weekday][hour] += 1
        words[weekday][hour] += wordCount
    }

    /// One-time migration seed: the tally a pre-sidecar install's surviving
    /// entries prove happened. (History cleared before the sidecar existed is
    /// unrecoverable — the timestamps went with the transcripts.)
    static func seeded(from entries: [DictationEntry], calendar: Calendar = .current) -> HeatmapTally {
        var tally = HeatmapTally()
        for entry in entries {
            tally.record(date: entry.date, wordCount: entry.wordCount, calendar: calendar)
        }
        return tally
    }

    /// Defensive: a hand-edited or truncated sidecar must never crash `record`
    /// or `rows` — reshape anything malformed back to the 8×24 grid.
    func normalized() -> HeatmapTally {
        var tally = HeatmapTally()
        for weekday in 1...7 {
            for hour in 0..<24 {
                tally.counts[weekday][hour] = counts.indices.contains(weekday)
                    && counts[weekday].indices.contains(hour) ? counts[weekday][hour] : 0
                tally.words[weekday][hour] = words.indices.contains(weekday)
                    && words[weekday].indices.contains(hour) ? words[weekday][hour] : 0
            }
        }
        return tally
    }
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
        rows(tally: HeatmapTally.seeded(from: entries, calendar: calendar), calendar: calendar)
    }

    /// Rows from the lifetime tally — the production path since the heatmap
    /// became clear-proof. Same output as `hourlyRows` for equal input.
    static func rows(
        tally: HeatmapTally,
        calendar: Calendar = .current
    ) -> [HeatmapWeekday] {
        let maxCount = tally.counts.flatMap { $0 }.max() ?? 0

        // Display order starts at the locale's first weekday (e.g. Sun or Mon).
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return order.map { weekday in
            let hours = (0..<24).map { hour in
                HeatmapHourCell(
                    count: tally.counts[weekday][hour],
                    words: tally.words[weekday][hour],
                    level: level(count: tally.counts[weekday][hour], maxCount: maxCount)
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

    /// One-sentence summary of the whole grid, used as the heatmap's single
    /// VoiceOver label: total volume plus the busiest slot. Day/hour naming is
    /// injected so the view keeps ownership of its (localized) labels and this
    /// stays pure and testable.
    static func accessibilitySummary(
        rows: [HeatmapWeekday],
        dayName: (Int) -> String,
        hourName: (Int) -> String
    ) -> String {
        var totalCount = 0
        var totalWords = 0
        var peak: (weekday: Int, hour: Int, count: Int)?
        for row in rows {
            for (hour, cell) in row.hours.enumerated() {
                totalCount += cell.count
                totalWords += cell.words
                if cell.count > (peak?.count ?? 0) {
                    peak = (row.weekday, hour, cell.count)
                }
            }
        }
        guard totalCount > 0, let peak else {
            return "When you dictate, by day and hour. No dictations yet."
        }
        return "When you dictate, by day and hour. "
            + "\(totalCount) dictation\(totalCount == 1 ? "" : "s"), \(totalWords) words. "
            + "Busiest \(dayName(peak.weekday)) at \(hourName(peak.hour))."
    }

    /// Every cell that has at least one dictation, in reading order (row, then
    /// hour). This is the sequence the heatmap's adjustable VoiceOver action
    /// steps through, so a non-mouse user reaches the same per-cell detail the
    /// hover readout gives a mouse user.
    static func populatedCells(rows: [HeatmapWeekday]) -> [(weekday: Int, hour: Int)] {
        rows.flatMap { row in
            row.hours.enumerated().compactMap { hour, cell in
                cell.count > 0 ? (weekday: row.weekday, hour: hour) : nil
            }
        }
    }

    /// Intensity bucket (1…4) for a cell relative to the busiest cell, 0 if empty.
    static func level(count: Int, maxCount: Int) -> Int {
        guard count > 0 else { return 0 }
        guard maxCount > 0 else { return 1 }
        let scaled = Int((Double(count) * 4.0 / Double(maxCount)).rounded(.up))
        return min(4, max(1, scaled))
    }
}
