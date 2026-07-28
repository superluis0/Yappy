//
//  StatFramingTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class StatFramingTests: XCTestCase {

    func testWordsBelowThresholdIsNil() {
        XCTAssertNil(StatFraming.wordsMilestone(0))
        XCTAssertNil(StatFraming.wordsMilestone(999))
    }

    func testWordsTiers() {
        XCTAssertEqual(StatFraming.wordsMilestone(1_000), "about a short story’s worth")
        XCTAssertEqual(StatFraming.wordsMilestone(4_999), "about a short story’s worth")
        XCTAssertEqual(StatFraming.wordsMilestone(5_000), "a long article’s worth")
        XCTAssertEqual(StatFraming.wordsMilestone(40_000), "a short novel’s worth")
        XCTAssertEqual(StatFraming.wordsMilestone(100_000), "a full novel’s worth")
        XCTAssertEqual(StatFraming.wordsMilestone(200_000), "a couple of novels’ worth")
        XCTAssertEqual(StatFraming.wordsMilestone(350_000), "a trilogy’s worth")
        XCTAssertEqual(StatFraming.wordsMilestone(600_000), "War and Peace, and then some")
    }

    func testWordsUnboundedTailKeepsCounting() {
        XCTAssertEqual(StatFraming.wordsMilestone(1_000_000), "about 10 novels’ worth")
        XCTAssertEqual(StatFraming.wordsMilestone(1_249_999), "about 12 novels’ worth")
        XCTAssertEqual(StatFraming.wordsMilestone(5_000_000), "about 50 novels’ worth")
    }

    func testWordsTailNeverRegressesAcrossTheBoundary() {
        // Just under the dynamic rung still reads as the top named tier.
        XCTAssertEqual(StatFraming.wordsMilestone(999_999), "War and Peace, and then some")
    }

    func testTimeBelowThresholdIsNil() {
        XCTAssertNil(StatFraming.timeSavedRelatable(minutes: 0))
        XCTAssertNil(StatFraming.timeSavedRelatable(minutes: 14))
    }

    func testTimeTiers() {
        XCTAssertEqual(StatFraming.timeSavedRelatable(minutes: 15), "about a coffee break")
        XCTAssertEqual(StatFraming.timeSavedRelatable(minutes: 59), "about a coffee break")
        XCTAssertEqual(StatFraming.timeSavedRelatable(minutes: 60), "an hour of your day back")
        XCTAssertEqual(StatFraming.timeSavedRelatable(minutes: 480), "a full workday saved")
        XCTAssertEqual(StatFraming.timeSavedRelatable(minutes: 2_400), "a full workweek saved")
    }

    func testTimeUnboundedTailKeepsCounting() {
        XCTAssertEqual(StatFraming.timeSavedRelatable(minutes: 4_800), "2 workweeks saved")
        XCTAssertEqual(StatFraming.timeSavedRelatable(minutes: 24_000), "10 workweeks saved")
    }
}
