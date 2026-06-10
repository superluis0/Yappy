//
//  SpokenNumberFormatterTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class SpokenNumberFormatterTests: XCTestCase {

    private func f(_ s: String) -> String { SpokenNumberFormatter.format(s) }

    // MARK: - Version / decimal numbers (the reported bug)

    func testVersionString() {
        XCTAssertEqual(f("eleven point six point zero"), "11.6.0")
    }

    func testSimpleDecimal() {
        XCTAssertEqual(f("three point one four"), "3.14")
    }

    func testDecimalPreservesLeadingZero() {
        XCTAssertEqual(f("zero point zero six"), "0.06")
    }

    func testDecimalSpokenAsCardinal() {
        // "point twenty five" reads as a cardinal, not digit-by-digit.
        XCTAssertEqual(f("nine point twenty five"), "9.25")
    }

    func testVersionInSentence() {
        XCTAssertEqual(f("upgrade to version eleven point six point zero today"),
                       "upgrade to version 11.6.0 today")
    }

    // MARK: - Cardinals

    func testTeen() {
        XCTAssertEqual(f("eleven"), "11")
    }

    func testCompoundTens() {
        XCTAssertEqual(f("twenty three"), "23")
    }

    func testHundreds() {
        XCTAssertEqual(f("one hundred twenty three"), "123")
    }

    func testThousands() {
        XCTAssertEqual(f("twenty three thousand"), "23000")
    }

    func testMillions() {
        XCTAssertEqual(f("two million five hundred thousand"), "2500000")
    }

    func testCardinalInSentence() {
        XCTAssertEqual(f("I need fifteen copies"), "I need 15 copies")
    }

    // MARK: - Boundaries & passthrough

    func testPlainTextUnchanged() {
        XCTAssertEqual(f("the quick brown fox"), "the quick brown fox")
    }

    func testBareScaleWordLeftAlone() {
        // Idiomatic, not literal — should not become "1000000".
        XCTAssertEqual(f("one in a million"), "1 in a million")
    }

    func testTrailingPointKeptAsWord() {
        XCTAssertEqual(f("the six point plan"), "the 6 point plan")
    }

    func testPunctuationBreaksRun() {
        // The comma separates two distinct numbers.
        XCTAssertEqual(f("eleven, twenty two"), "11, 22")
    }

    func testEmptyString() {
        XCTAssertEqual(f(""), "")
    }

    func testCasePreservedAroundNumbers() {
        XCTAssertEqual(f("Eleven items"), "11 items")
    }

    func testDisabledPathIsIdentity() {
        // When the feature is off the caller skips formatting entirely; format()
        // itself always transforms, so verify the transform is stable/idempotent.
        XCTAssertEqual(f(f("eleven point six")), "11.6")
    }
}
