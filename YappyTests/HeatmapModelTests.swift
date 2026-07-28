//
//  HeatmapModelTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class HeatmapModelTests: XCTestCase {

    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1 // Sunday
    }

    /// A date at a specific weekday (1=Sun…7=Sat) and hour.
    private func date(weekday: Int, hour: Int) -> Date {
        // 2026-06-07 is a Sunday (weekday 1) in UTC.
        let base = DateComponents(calendar: calendar, year: 2026, month: 6, day: 6 + weekday, hour: hour)
        return base.date!
    }

    private func entry(weekday: Int, hour: Int, words: Int = 3) -> DictationEntry {
        let text = Array(repeating: "w", count: words).joined(separator: " ")
        return DictationEntry(date: date(weekday: weekday, hour: hour), text: text, durationSeconds: 1)
    }

    private func rows(_ entries: [DictationEntry]) -> [HeatmapWeekday] {
        HeatmapModel.hourlyRows(entries: entries, calendar: calendar)
    }

    // MARK: - Shape

    func testSevenRowsTwentyFourHours() {
        let result = rows([])
        XCTAssertEqual(result.count, 7)
        XCTAssertTrue(result.allSatisfy { $0.hours.count == 24 })
    }

    func testRowsOrderedByFirstWeekday() {
        let result = rows([])
        XCTAssertEqual(result.first?.weekday, 1) // Sunday first
        XCTAssertEqual(result.last?.weekday, 7) // Saturday last

        var monday = calendar!
        monday.firstWeekday = 2
        let mondayRows = HeatmapModel.hourlyRows(entries: [], calendar: monday)
        XCTAssertEqual(mondayRows.first?.weekday, 2) // Monday first
    }

    func testEmptyIsAllLevelZero() {
        XCTAssertTrue(rows([]).allSatisfy { row in row.hours.allSatisfy { $0.level == 0 } })
    }

    // MARK: - Bucketing

    func testBucketsByWeekdayAndHour() {
        // Sunday 9:00 ×2, Sunday 10:00 ×1.
        let result = rows([
            entry(weekday: 1, hour: 9, words: 2),
            entry(weekday: 1, hour: 9, words: 4),
            entry(weekday: 1, hour: 10)
        ])
        let sunday = result.first { $0.weekday == 1 }!
        XCTAssertEqual(sunday.hours[9].count, 2)
        XCTAssertEqual(sunday.hours[9].words, 6)
        XCTAssertEqual(sunday.hours[10].count, 1)
        XCTAssertEqual(sunday.hours[0].count, 0)
    }

    func testLevelScalesToBusiestCell() {
        // Busiest cell = 4 → level 4; a cell with 1 (25%) → level 1.
        let entries =
            Array(repeating: entry(weekday: 3, hour: 14), count: 4) +
            [entry(weekday: 5, hour: 20)]
        let result = rows(entries)
        let busiest = result.first { $0.weekday == 3 }!.hours[14]
        let light = result.first { $0.weekday == 5 }!.hours[20]
        XCTAssertEqual(busiest.level, 4)
        XCTAssertEqual(light.level, 1)
    }

    func testLevelThresholds() {
        XCTAssertEqual(HeatmapModel.level(count: 0, maxCount: 10), 0)
        XCTAssertEqual(HeatmapModel.level(count: 1, maxCount: 10), 1) // 10%
        XCTAssertEqual(HeatmapModel.level(count: 3, maxCount: 10), 2) // 30%
        XCTAssertEqual(HeatmapModel.level(count: 6, maxCount: 10), 3) // 60%
        XCTAssertEqual(HeatmapModel.level(count: 10, maxCount: 10), 4) // 100%
        XCTAssertEqual(HeatmapModel.level(count: 1, maxCount: 0), 1) // degenerate
    }

    // MARK: - Busiest hour / weekday

    func testBusiestHourAndWeekday() {
        let entries =
            Array(repeating: entry(weekday: 3, hour: 14), count: 3) +
            [entry(weekday: 5, hour: 9)]
        XCTAssertEqual(HeatmapModel.busiestHour(entries: entries, calendar: calendar), 14)
        XCTAssertEqual(HeatmapModel.busiestWeekday(entries: entries, calendar: calendar), 3)
    }

    func testBusiestIsNilWhenEmpty() {
        XCTAssertNil(HeatmapModel.busiestHour(entries: [], calendar: calendar))
        XCTAssertNil(HeatmapModel.busiestWeekday(entries: [], calendar: calendar))
    }

    // MARK: - Accessibility summary (the heatmap's single VoiceOver label)

    private func day(_ weekday: Int) -> String {
        ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday]
    }

    private func hourName(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case 1..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }

    private func summary(_ rows: [HeatmapWeekday]) -> String {
        HeatmapModel.accessibilitySummary(rows: rows, dayName: day, hourName: hourName)
    }

    func testAccessibilitySummaryReportsTotalsAndPeak() {
        let entries =
            Array(repeating: entry(weekday: 3, hour: 14, words: 5), count: 3) +
            [entry(weekday: 5, hour: 9, words: 2)]
        let rows = HeatmapModel.hourlyRows(entries: entries, calendar: calendar)

        let text = summary(rows)

        XCTAssertTrue(text.contains("4 dictations"), text)
        XCTAssertTrue(text.contains("17 words"), text)
        XCTAssertTrue(text.contains("Busiest Tue at 2p"), text)
    }

    func testAccessibilitySummarySingularizesOneDictation() {
        let rows = HeatmapModel.hourlyRows(entries: [entry(weekday: 1, hour: 0, words: 1)], calendar: calendar)

        let text = summary(rows)

        XCTAssertTrue(text.contains("1 dictation,"), text)
        XCTAssertFalse(text.contains("1 dictations"), text)
        XCTAssertTrue(text.contains("Busiest Sun at 12a"), text)
    }

    func testAccessibilitySummaryHandlesNoActivity() {
        let rows = HeatmapModel.hourlyRows(entries: [], calendar: calendar)

        XCTAssertEqual(summary(rows), "When you dictate, by day and hour. No dictations yet.")
        XCTAssertEqual(summary([]), "When you dictate, by day and hour. No dictations yet.")
    }

    // MARK: - Populated cells (the adjustable VoiceOver cursor's sequence)

    func testPopulatedCellsSkipsEmptyCellsAndKeepsReadingOrder() {
        let entries = [
            entry(weekday: 5, hour: 9),
            entry(weekday: 3, hour: 14),
            entry(weekday: 3, hour: 2)
        ]
        let rows = HeatmapModel.hourlyRows(entries: entries, calendar: calendar)

        let cells = HeatmapModel.populatedCells(rows: rows)

        XCTAssertEqual(cells.count, 3)
        XCTAssertTrue(cells.allSatisfy { $0.hour >= 0 && $0.hour < 24 })
        // Rows come in display order (Sun first), hours ascending within a row.
        XCTAssertEqual(cells.map(\.weekday), [3, 3, 5])
        XCTAssertEqual(cells.map(\.hour), [2, 14, 9])
    }

    func testPopulatedCellsIsEmptyWithoutActivity() {
        let rows = HeatmapModel.hourlyRows(entries: [], calendar: calendar)
        XCTAssertTrue(HeatmapModel.populatedCells(rows: rows).isEmpty)
    }

    // MARK: - Lifetime tally (the clear-proof path)

    func testTallyRowsMatchEntriesRowsForSameInput() {
        let entries = [
            entry(weekday: 2, hour: 9), entry(weekday: 2, hour: 9, words: 10),
            entry(weekday: 5, hour: 17), entry(weekday: 7, hour: 23),
        ]
        let viaEntries = HeatmapModel.hourlyRows(entries: entries, calendar: calendar)
        let viaTally = HeatmapModel.rows(
            tally: HeatmapTally.seeded(from: entries, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(viaEntries, viaTally,
                       "the tally path must render identically to the legacy entries path")
    }

    func testTallyRecordAccumulates() {
        var tally = HeatmapTally()
        XCTAssertTrue(tally.isEmpty)
        tally.record(date: date(weekday: 3, hour: 8), wordCount: 12, calendar: calendar)
        tally.record(date: date(weekday: 3, hour: 8), wordCount: 3, calendar: calendar)
        XCTAssertFalse(tally.isEmpty)
        XCTAssertEqual(tally.counts[3][8], 2)
        XCTAssertEqual(tally.words[3][8], 15)
    }

    /// A hand-edited or truncated sidecar must reshape safely, never crash.
    func testTallyNormalizedRepairsMalformedGrid() {
        var malformed = HeatmapTally()
        malformed.counts = [[1, 2], [3]] // wrong shape entirely
        malformed.words = []
        let repaired = malformed.normalized()
        XCTAssertEqual(repaired.counts.count, 8)
        XCTAssertTrue(repaired.counts.allSatisfy { $0.count == 24 })
        // Surviving in-range values carry over; everything else is zeroed.
        XCTAssertEqual(repaired.counts[1][0], 3)
        var roundTrip = repaired
        roundTrip.record(date: date(weekday: 1, hour: 0), wordCount: 1, calendar: calendar)
        XCTAssertEqual(roundTrip.counts[1][0], 4)
    }
}
