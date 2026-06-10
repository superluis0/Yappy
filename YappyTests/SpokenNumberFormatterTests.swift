//
//  SpokenNumberFormatterTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class SpokenNumberFormatterTests: XCTestCase {

    private func f(_ s: String) -> String { SpokenNumberFormatter.format(s) }

    // MARK: - Version / decimal numbers

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

    // MARK: - Adjacent independent numbers (strict parser)

    func testAdjacentNumbersSplit() {
        XCTAssertEqual(f("eleven twenty"), "11 20")
    }

    func testAdjacentCompoundsSplit() {
        XCTAssertEqual(f("twenty five sixty"), "25 60")
    }

    // MARK: - Digit runs

    func testPhoneStyleDigitRun() {
        XCTAssertEqual(f("five five five one two one two"), "5551212")
    }

    func testDigitRunPreservesLeadingZeros() {
        XCTAssertEqual(f("zero zero seven"), "007")
    }

    func testTwoDigitsAreNotARun() {
        XCTAssertEqual(f("two two"), "2 2")
    }

    // MARK: - Years

    func testModernYear() {
        XCTAssertEqual(f("twenty twenty six"), "2026")
    }

    func testNineteenHundredsYear() {
        XCTAssertEqual(f("nineteen ninety nine"), "1999")
    }

    func testRoundYear() {
        XCTAssertEqual(f("twenty twenty"), "2020")
    }

    func testTeensYear() {
        XCTAssertEqual(f("twenty thirteen"), "2013")
    }

    func testNonYearPairSplits() {
        XCTAssertEqual(f("thirty forty"), "30 40")
    }

    // MARK: - Ordinals

    func testCompoundOrdinal() {
        XCTAssertEqual(f("twenty third"), "23rd")
    }

    func testCompoundOrdinalFirst() {
        XCTAssertEqual(f("thirty first"), "31st")
    }

    func testCompoundOrdinalSecond() {
        XCTAssertEqual(f("twenty second"), "22nd")
    }

    func testStandaloneScaleOrdinal() {
        XCTAssertEqual(f("hundredth"), "100th")
    }

    func testCardinalTimesScaleOrdinal() {
        XCTAssertEqual(f("one hundredth"), "100th")
    }

    func testStandaloneLargeOrdinal() {
        XCTAssertEqual(f("the twentieth century"), "the 20th century")
    }

    func testStandaloneTeenOrdinal() {
        XCTAssertEqual(f("thirteenth"), "13th")
    }

    func testHundredTwentiethCompound() {
        XCTAssertEqual(f("one hundred twentieth"), "120th")
    }

    func testAmbiguousSmallOrdinalsUntouched() {
        XCTAssertEqual(f("wait a second"), "wait a second")
        XCTAssertEqual(f("first of all"), "first of all")
        XCTAssertEqual(f("third party"), "third party")
        XCTAssertEqual(f("the eleventh hour"), "the eleventh hour")
    }

    // MARK: - Percent

    func testIntegerPercent() {
        XCTAssertEqual(f("fifty percent"), "50%")
    }

    func testDecimalPercent() {
        XCTAssertEqual(f("three point five percent"), "3.5%")
    }

    func testBareScalePercentUntouched() {
        XCTAssertEqual(f("a hundred percent"), "a hundred percent")
    }

    // MARK: - Currency

    func testWholeDollars() {
        XCTAssertEqual(f("twenty dollars"), "$20")
    }

    func testSingularDollar() {
        XCTAssertEqual(f("one dollar"), "$1")
    }

    func testDollarsAndCents() {
        XCTAssertEqual(f("five dollars and fifty cents"), "$5.50")
    }

    func testCentsArePadded() {
        XCTAssertEqual(f("five dollars and five cents"), "$5.05")
    }

    func testBareCentsStayWords() {
        XCTAssertEqual(f("fifty cents"), "50 cents")
    }

    func testEuros() {
        XCTAssertEqual(f("twenty euros"), "€20")
    }

    func testBareScaleCurrencyUntouched() {
        XCTAssertEqual(f("a million dollars"), "a million dollars")
    }

    // MARK: - Times

    func testHourMinutesTime() {
        XCTAssertEqual(f("three thirty pm"), "3:30 PM")
    }

    func testHourOnlyTime() {
        XCTAssertEqual(f("three pm"), "3 PM")
    }

    func testMorningTime() {
        XCTAssertEqual(f("ten forty five am"), "10:45 AM")
    }

    func testDottedMeridiemAnchorsButStays() {
        // The dotted abbreviation is left as written so surrounding sentence
        // punctuation stays intact; the number still becomes a clock reading.
        XCTAssertEqual(f("three thirty p.m."), "3:30 p.m.")
    }

    func testNoMeridiemNoTime() {
        XCTAssertEqual(f("three thirty"), "3 30")
    }

    func testInvalidHourLeavesMeridiem() {
        XCTAssertEqual(f("thirteen pm"), "13 pm")
    }

    func testInvalidMinutesLeavesMeridiem() {
        XCTAssertEqual(f("three five pm"), "3 5 pm")
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

    func testIdempotentOnFormattedOutput() {
        for sample in ["eleven point six", "twenty dollars and fifty cents",
                       "three thirty pm", "twenty third", "fifty percent"] {
            let once = f(sample)
            XCTAssertEqual(f(once), once, "not idempotent for: \(sample)")
        }
    }
}
