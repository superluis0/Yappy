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
        XCTAssertEqual(result.last?.weekday, 7)  // Saturday last

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
            entry(weekday: 1, hour: 10),
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
        XCTAssertEqual(HeatmapModel.level(count: 1, maxCount: 10), 1)   // 10%
        XCTAssertEqual(HeatmapModel.level(count: 3, maxCount: 10), 2)   // 30%
        XCTAssertEqual(HeatmapModel.level(count: 6, maxCount: 10), 3)   // 60%
        XCTAssertEqual(HeatmapModel.level(count: 10, maxCount: 10), 4)  // 100%
        XCTAssertEqual(HeatmapModel.level(count: 1, maxCount: 0), 1)    // degenerate
    }
}
