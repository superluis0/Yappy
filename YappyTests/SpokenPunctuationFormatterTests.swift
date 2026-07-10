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

    // MARK: - Extended marks

    func testApostropheGlues() {
        XCTAssertEqual(f("it apostrophe s working"), "it's working")
    }

    func testEllipsis() {
        XCTAssertEqual(f("wait ellipsis really"), "wait… really")
    }

    func testEmDashGlues() {
        XCTAssertEqual(f("yes em dash no"), "yes—no")
    }

    func testForwardSlashGlues() {
        XCTAssertEqual(f("a forward slash b"), "a/b")
    }

    func testQuotes() {
        XCTAssertEqual(f("he said open quote hi close quote"), "he said \u{201C}hi\u{201D}")
    }

    // A bare "quote" / "slash" stays prose — only the two-word forms convert.
    func testBareQuoteWordIsNotConverted() {
        XCTAssertEqual(f("the famous quote is here"), "the famous quote is here")
    }

    /// Every symbol-producing spoken form must pass the substring triggers gate;
    /// otherwise the formatter returns the input unchanged.
    func testEverySymbolMapEntryIsCoveredBySubstringTriggers() {
        let cases: [(input: String, expected: String)] = [
            ("hello comma world", "hello, world"),
            ("done period next", "done. Next"),
            ("items colon a", "items: a"),
            ("a semicolon b", "a; b"),
            ("x hyphen y", "x-y"),
            ("x dash y", "x-y"),
            ("it apostrophe s", "it's"),
            ("wait ellipsis really", "wait… really"),
            ("is this real question mark", "is this real?"),
            ("wow exclamation mark", "wow!"),
            ("wow exclamation point", "wow!"),
            ("okay full stop", "okay."),
            ("see open paren note close paren", "see (note)"),
            ("see open parenthesis note close parenthesis", "see (note)"),
            ("see open bracket note close bracket", "see [note]"),
            ("he said open quote hi close quote", "he said \u{201C}hi\u{201D}"),
            ("he said open quote hi end quote", "he said \u{201C}hi\u{201D}"),
            ("a forward slash b", "a/b"),
            ("yes em dash no", "yes—no"),
        ]
        for item in cases {
            let result = f(item.input)
            XCTAssertEqual(
                result,
                item.expected,
                "trigger gate or map miss for \(item.input.debugDescription)"
            )
        }
    }
}
