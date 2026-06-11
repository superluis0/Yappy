//
//  PersonalRecordsTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class PersonalRecordsTests: XCTestCase {

    private var cal = Calendar.current

    private func entry(_ text: String, duration: Double, daysAgo: Int = 0) -> DictationEntry {
        let date = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
        return DictationEntry(date: date, text: text, durationSeconds: duration)
    }

    func testEmptyHistory() {
        XCTAssertEqual(PersonalRecords.compute(from: []), .empty)
        XCTAssertFalse(PersonalRecords.empty.hasAny)
    }

    func testFastestWPMIgnoresTinyDurations() {
        let r = PersonalRecords.compute(from: [
            // 6 words in 0.5s would be 720 WPM — rejected (below min duration).
            entry("one two three four five six", duration: 0.5),
            // 60 words in 60s = 60 WPM — counted.
            entry(Array(repeating: "w", count: 60).joined(separator: " "), duration: 60),
        ])
        XCTAssertEqual(r.fastestWPM, 60)
    }

    func testFastestWPMIgnoresTooFewWords() {
        let r = PersonalRecords.compute(from: [
            entry("hi", duration: 5),   // only 1 word — rejected
        ])
        XCTAssertEqual(r.fastestWPM, 0)
    }

    func testLongestDictation() {
        let r = PersonalRecords.compute(from: [
            entry("a b c", duration: 5),
            entry("a b c d e f g", duration: 10),
        ])
        XCTAssertEqual(r.longestDictationWords, 7)
    }

    func testBiggestDayAggregates() {
        let r = PersonalRecords.compute(from: [
            entry("a b c", duration: 5, daysAgo: 0),
            entry("d e", duration: 5, daysAgo: 0),     // same day → 5 words
            entry("x", duration: 5, daysAgo: 3),       // different day → 1 word
        ])
        XCTAssertEqual(r.biggestDayWords, 5)
    }

    func testLongestStreak() {
        // Days 0,1,2 present (a 3-run), gap, then day 5.
        let r = PersonalRecords.compute(from: [
            entry("a", duration: 5, daysAgo: 0),
            entry("a", duration: 5, daysAgo: 1),
            entry("a", duration: 5, daysAgo: 2),
            entry("a", duration: 5, daysAgo: 5),
        ])
        XCTAssertEqual(r.longestStreakDays, 3)
    }
}
