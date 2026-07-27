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

    // MARK: - Digit-time repair (ASR misrendering)

    func testDigitTimePeriodSpaceRepaired() {
        // Exact shape Parakeet emitted in the wild (Messages, 2026-07-09).
        XCTAssertEqual(f("Well, I have a call with Cigna tomorrow at 7. 30 A.M."),
                       "Well, I have a call with Cigna tomorrow at 7:30 A.M.")
    }

    func testDigitTimePeriodNoSpaceRepaired() {
        XCTAssertEqual(f("I said 7.30 AM and it said the time wrong."),
                       "I said 7:30 AM and it said the time wrong.")
    }

    func testDigitTimeLowercaseMeridiem() {
        XCTAssertEqual(f("meet at 11.45 pm sharp"), "meet at 11:45 pm sharp")
    }

    func testDigitTimeNoMeridiemUntouched() {
        // A bare decimal is NOT a time — never rewrite without the anchor.
        XCTAssertEqual(f("the board is 7.30 inches wide"),
                       "the board is 7.30 inches wide")
    }

    func testDigitTimeInvalidHourUntouched() {
        XCTAssertEqual(f("scored 13.30 am I right"), "scored 13.30 am I right")
    }

    func testDigitTimeInvalidMinutesUntouched() {
        XCTAssertEqual(f("version 7.99 pm build"), "version 7.99 pm build")
    }

    func testDigitTimeIdempotent() {
        let once = f("at 7. 30 A.M.")
        XCTAssertEqual(f(once), once)
    }

    // MARK: - Boundaries & passthrough

    func testPlainTextUnchanged() {
        XCTAssertEqual(f("the quick brown fox"), "the quick brown fox")
    }

    func testBareScaleWordLeftAlone() {
        // Idiomatic, not literal — should not become "1000000".
        XCTAssertEqual(f("one in a million"), "one in a million")
    }

    func testTrailingPointKeptAsWord() {
        // Changed with the prose guard: "the six point plan" is a
        // compound adjective, not a quantity, so it reads as prose.
        // The point of this test still holds — "point" is not consumed
        // as a decimal separator.
        XCTAssertEqual(f("the six point plan"), "the six point plan")
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

    // MARK: - Prose guard: lone small numbers stay spelled out

    /// The reported bug: "hey one of these days" became "hey 1 of these days",
    /// which reads as a typo in ordinary writing other people see.
    func testLoneSmallNumberInProseStaysSpelledOut() {
        XCTAssertEqual(f("hey one of these days"), "hey one of these days")
        XCTAssertEqual(f("one of the best"), "one of the best")
        XCTAssertEqual(f("no one is here"), "no one is here")
        XCTAssertEqual(f("at one point I gave up"), "at one point I gave up")
        XCTAssertEqual(f("we talked for one another"), "we talked for one another")
        XCTAssertEqual(f("give me two seconds"), "give me two seconds")
        XCTAssertEqual(f("I have three of those"), "I have three of those")
    }

    /// Sentence-initial capitalization must survive being left alone.
    func testSpelledOutNumberKeepsOriginalCasing() {
        XCTAssertEqual(f("One of these days"), "One of these days")
    }

    /// Everything the user explicitly wants as digits still converts.
    func testQuantitativeContextsStillUseDigits() {
        XCTAssertEqual(f("step one"), "step 1")
        XCTAssertEqual(f("number two"), "number 2")
        XCTAssertEqual(f("version three"), "version 3")
        XCTAssertEqual(f("page seven"), "page 7")
        XCTAssertEqual(f("three miles"), "3 miles")
        XCTAssertEqual(f("five gigabytes"), "5 gigabytes")
        XCTAssertEqual(f("seventy two degrees"), "72 degrees")
        XCTAssertEqual(f("nine percent"), "9%")
        XCTAssertEqual(f("five dollars"), "$5")
        XCTAssertEqual(f("three pm"), "3 PM")
        XCTAssertEqual(f("nine thirty am"), "9:30 AM")
    }

    /// Only a LONE 0-9 is affected: bigger and compound numbers keep digits.
    func testGuardIsNarrowlyScoped() {
        XCTAssertEqual(f("twenty three of these"), "23 of these")
        XCTAssertEqual(f("ten of these"), "10 of these")
        XCTAssertEqual(f("one hundred of these"), "100 of these")
        XCTAssertEqual(f("one point five"), "1.5")
        // Lone ordinals were already left alone (see testOrdinals);
        // the cardinal guard matches that established behavior.
        XCTAssertEqual(f("first of all"), "first of all")
    }
}
