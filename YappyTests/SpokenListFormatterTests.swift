//
//  SpokenListFormatterTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

/// The formatter runs on the real transcript and must handle counters as words
/// or digits, ordinals, an optional lead-in word, and the commas/periods a
/// speech model inserts.
final class SpokenListFormatterTests: XCTestCase {

    private func f(_ s: String) -> String { SpokenListFormatter.format(s) }

    // MARK: - Word forms (number formatting off, or model emits words)

    func testBareCardinalWords() {
        XCTAssertEqual(
            f("buy one milk two eggs three bread"),
            "buy\n1. Milk\n2. Eggs\n3. Bread"
        )
    }

    func testCommaSeparatedCardinals() {
        XCTAssertEqual(
            f("one milk, two eggs, three bread"),
            "1. Milk\n2. Eggs\n3. Bread"
        )
    }

    func testNumberLeadInWithCommasAndPeriods() {
        XCTAssertEqual(
            f("Number one, we need X. Number two, we need Y. Number three, we need Z."),
            "1. We need X.\n2. We need Y.\n3. We need Z."
        )
    }

    func testOrdinalWords() {
        XCTAssertEqual(
            f("first grab milk second pay third leave"),
            "1. Grab milk\n2. Pay\n3. Leave"
        )
    }

    func testStepLeadInIsDropped() {
        XCTAssertEqual(
            f("step one do this step two do that step three do other"),
            "1. Do this\n2. Do that\n3. Do other"
        )
    }

    // MARK: - Digit forms (number formatting already ran)

    func testDigitMarkersWithPrefix() {
        XCTAssertEqual(
            f("buy 1 milk 2 eggs 3 bread"),
            "buy\n1. Milk\n2. Eggs\n3. Bread"
        )
    }

    func testDigitMarkersWithDotsLikeAList() {
        XCTAssertEqual(
            f("1. apples 2. bananas 3. oranges"),
            "1. Apples\n2. Bananas\n3. Oranges"
        )
    }

    // MARK: - Conservative guards (must NOT form a list)

    func testTwoItemsIsNotAList() {
        XCTAssertEqual(f("I have one cat and two dogs"), "I have one cat and two dogs")
    }

    func testSingleCounterUnchanged() {
        XCTAssertEqual(f("press one for sales"), "press one for sales")
    }

    func testMustStartAtOne() {
        XCTAssertEqual(f("two eggs three bread four milk"), "two eggs three bread four milk")
    }

    func testClockTimesAreNotMarkers() {
        XCTAssertEqual(f("calls at 1:30 and 2:30 and 3:30"), "calls at 1:30 and 2:30 and 3:30")
    }

    func testDecimalsAreNotMarkers() {
        XCTAssertEqual(f("upgrade to 1.5 then 2.5 then 3.5"), "upgrade to 1.5 then 2.5 then 3.5")
    }

    func testCurrencyAmountsAreNotMarkers() {
        XCTAssertEqual(f("pay $1, $2, $3 each"), "pay $1, $2, $3 each")
    }

    func testNoCountersIsIdentity() {
        XCTAssertEqual(f("milk, eggs, bread"), "milk, eggs, bread")
    }
}
