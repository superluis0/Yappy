//
//  SpokenListFormatterTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

/// The formatter runs after SpokenNumberFormatter, so its input already has
/// digit counters ("1", "2", "3") rather than spoken words.
final class SpokenListFormatterTests: XCTestCase {

    private func f(_ s: String) -> String { SpokenListFormatter.format(s) }

    func testBasicListWithPrefix() {
        XCTAssertEqual(
            f("buy 1 milk 2 eggs 3 bread"),
            "buy\n1. Milk\n2. Eggs\n3. Bread"
        )
    }

    func testListWithNoPrefix() {
        XCTAssertEqual(
            f("1 wake up 2 work out 3 sleep"),
            "1. Wake up\n2. Work out\n3. Sleep"
        )
    }

    func testSharedLeadInWordIsDropped() {
        XCTAssertEqual(
            f("step 1 grab milk step 2 pay step 3 leave"),
            "1. Grab milk\n2. Pay\n3. Leave"
        )
    }

    func testTwoItemsIsNotAList() {
        XCTAssertEqual(f("I have 1 cat and 2 dogs"), "I have 1 cat and 2 dogs")
    }

    func testSingleCounterUnchanged() {
        XCTAssertEqual(f("press 1 for sales"), "press 1 for sales")
    }

    func testMustStartAtOne() {
        XCTAssertEqual(f("buy 2 eggs 3 bread 4 milk"), "buy 2 eggs 3 bread 4 milk")
    }

    func testNonMonotonicDoesNotExtend() {
        // Run from 1 stops at the out-of-order 3, leaving only one item — no list.
        XCTAssertEqual(f("1 apples 3 bananas 2 oranges"), "1 apples 3 bananas 2 oranges")
    }

    func testTimeIsNotMistakenForAMarker() {
        // "1" in "1:30" isn't followed by whitespace, so it's not a counter.
        XCTAssertEqual(f("the meeting is at 1:30 today"), "the meeting is at 1:30 today")
    }

    func testNoDigitsIsIdentity() {
        XCTAssertEqual(f("nothing to see here"), "nothing to see here")
    }
}
