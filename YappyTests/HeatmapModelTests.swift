//
//  HeatmapModelTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class HeatmapModelTests: XCTestCase {

    private var calendar: Calendar!
    /// A fixed "today": 2026-06-10 12:00 UTC.
    private var today: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        today = DateComponents(calendar: calendar, year: 2026, month: 6, day: 10, hour: 12).date!
    }

    private func entry(daysAgo: Int, words: Int = 3) -> DictationEntry {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        return DictationEntry(date: date, text: text, durationSeconds: 2)
    }

    private func days(_ entries: [DictationEntry], weeks: Int = 12) -> [HeatmapDay] {
        HeatmapModel.days(entries: entries, weeks: weeks, today: today, calendar: calendar)
    }

    // MARK: - Range

    func testLastDayIsToday() {
        let result = days([])
        XCTAssertEqual(result.last?.date, calendar.startOfDay(for: today))
    }

    func testRangeSpansRequestedWeeks() {
        let result = days([], weeks: 12)
        // From the start of the week 11 weeks ago through today: at least
        // 11 full weeks plus today's partial week, never more than 12 weeks.
        XCTAssertGreaterThanOrEqual(result.count, 11 * 7 + 1)
        XCTAssertLessThanOrEqual(result.count, 12 * 7)
        // First day is the start of a week.
        let first = result.first!.date
        XCTAssertEqual(calendar.dateInterval(of: .weekOfYear, for: first)?.start, first)
    }

    func testEmptyEntriesAllLevelZero() {
        XCTAssertTrue(days([]).allSatisfy { $0.level == 0 && $0.dictations == 0 })
    }

    // MARK: - Bucketing

    func testCountsAndWordsBucketPerDay() {
        let result = days([entry(daysAgo: 0, words: 5), entry(daysAgo: 0, words: 2), entry(daysAgo: 1)])
        let todayCell = result.last!
        XCTAssertEqual(todayCell.dictations, 2)
        XCTAssertEqual(todayCell.words, 7)
        let yesterday = result[result.count - 2]
        XCTAssertEqual(yesterday.dictations, 1)
    }

    func testEntriesOutsideWindowExcluded() {
        let result = days([entry(daysAgo: 12 * 7 + 30)])
        XCTAssertTrue(result.allSatisfy { $0.dictations == 0 })
    }

    func testLevelBucketBoundaries() {
        XCTAssertEqual(HeatmapModel.level(forDictations: 0), 0)
        XCTAssertEqual(HeatmapModel.level(forDictations: 1), 1)
        XCTAssertEqual(HeatmapModel.level(forDictations: 2), 2)
        XCTAssertEqual(HeatmapModel.level(forDictations: 3), 2)
        XCTAssertEqual(HeatmapModel.level(forDictations: 4), 3)
        XCTAssertEqual(HeatmapModel.level(forDictations: 6), 3)
        XCTAssertEqual(HeatmapModel.level(forDictations: 7), 4)
        XCTAssertEqual(HeatmapModel.level(forDictations: 40), 4)
    }
}
