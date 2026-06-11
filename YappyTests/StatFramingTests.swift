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
        XCTAssertEqual(StatFraming.wordsMilestone(1_000), "about a short story's worth")
        XCTAssertEqual(StatFraming.wordsMilestone(4_999), "about a short story's worth")
        XCTAssertEqual(StatFraming.wordsMilestone(5_000), "a long article's worth")
        XCTAssertEqual(StatFraming.wordsMilestone(40_000), "a short novel's worth")
        XCTAssertEqual(StatFraming.wordsMilestone(1_000_000), "a full novel's worth")
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
    }
}
