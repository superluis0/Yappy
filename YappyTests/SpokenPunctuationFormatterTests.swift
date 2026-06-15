//
//  SpokenPunctuationFormatterTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class SpokenPunctuationFormatterTests: XCTestCase {

    private func f(_ s: String) -> String { SpokenPunctuationFormatter.apply(s) }

    func testComma() {
        XCTAssertEqual(f("hello comma world"), "hello, world")
    }

    func testPeriodStartsNewSentence() {
        XCTAssertEqual(f("done period next thought"), "done. Next thought")
    }

    func testQuestionMark() {
        XCTAssertEqual(f("is this real question mark"), "is this real?")
    }

    func testExclamationMarkAndPoint() {
        XCTAssertEqual(f("wow exclamation mark"), "wow!")
        XCTAssertEqual(f("wow exclamation point"), "wow!")
    }

    func testFullStop() {
        XCTAssertEqual(f("okay full stop"), "okay.")
    }

    func testColonAndSemicolon() {
        XCTAssertEqual(f("items colon a semicolon b"), "items: a; b")
    }

    func testParentheses() {
        XCTAssertEqual(f("see open paren note close paren here"), "see (note) here")
    }

    func testHyphenGlues() {
        XCTAssertEqual(f("x hyphen y"), "x-y")
    }

    // MARK: - Whole-word safety

    func testPluralIsNotConverted() {
        XCTAssertEqual(f("the commas are wrong"), "the commas are wrong")
    }

    func testMarkWordEmbeddedIsNotConverted() {
        XCTAssertEqual(f("a periodic table"), "a periodic table")
    }

    func testHalfOfTwoWordMarkIsSafe() {
        XCTAssertEqual(f("what is the question"), "what is the question")
    }

    func testNoTriggerIsIdentity() {
        XCTAssertEqual(f("just a normal sentence"), "just a normal sentence")
    }
}
