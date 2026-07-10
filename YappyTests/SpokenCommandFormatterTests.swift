//
//  SpokenCommandFormatterTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class SpokenCommandFormatterTests: XCTestCase {

    private func f(_ s: String) -> String { SpokenCommandFormatter.apply(s) }

    func testCommaSeparatedCommand() {
        XCTAssertEqual(f("Hello, new line, thanks"), "Hello\nThanks")
    }

    func testPeriodSeparatedCommand() {
        XCTAssertEqual(f("Hello. New line. Thanks."), "Hello.\nThanks.")
    }

    func testNewParagraph() {
        XCTAssertEqual(f("done. New paragraph. Next topic"), "done.\n\nNext topic")
    }

    func testProseNewLineUntouched() {
        XCTAssertEqual(f("a new line of products"), "a new line of products")
    }

    func testProseNewParagraphUntouched() {
        XCTAssertEqual(f("the new paragraph looks good"), "the new paragraph looks good")
    }

    func testWholeUtteranceCommandIsASpokenEnter() {
        XCTAssertEqual(f("New line."), "\n")
    }

    func testTrailingCommandKeepsBreak() {
        XCTAssertEqual(f("Hello, new line"), "Hello\n")
    }

    func testMixedProseAndCommand() {
        XCTAssertEqual(f("It's a new line. New line. Done."), "It's a new line.\nDone.")
    }

    func testCommandAtStart() {
        XCTAssertEqual(f("New paragraph. Hi there"), "\n\nHi there")
    }

    func testNoCommandIsIdentity() {
        XCTAssertEqual(f("Nothing here at all."), "Nothing here at all.")
    }

    // "next line" / "next paragraph" are synonyms for "new line" / "new paragraph".
    func testNextLineCommand() {
        XCTAssertEqual(f("Hello, next line, thanks"), "Hello\nThanks")
    }

    func testNextParagraphCommand() {
        XCTAssertEqual(f("done. Next paragraph. Next topic"), "done.\n\nNext topic")
    }

    func testProseNextLineUntouched() {
        XCTAssertEqual(f("go to the next line of code"), "go to the next line of code")
    }

    // "line break", "insert line", "skip a line" — the remaining common phrasings
    // shared with Apple Dictation/Voice Control, Dragon, and Wispr Flow.
    func testLineBreakCommand() {
        XCTAssertEqual(f("first item, line break, second item"), "first item\nSecond item")
    }

    func testInsertLineCommand() {
        XCTAssertEqual(f("name, insert line, address"), "name\nAddress")
    }

    func testSkipALineCommand() {
        XCTAssertEqual(f("intro. Skip a line. Body"), "intro.\n\nBody")
    }

    func testProseInsertLineUntouched() {
        XCTAssertEqual(f("please insert line 5 here"), "please insert line 5 here")
    }

    /// Every phrase in the phrase map must be covered by the cheap substring
    /// triggers gate — otherwise `apply` early-returns without transforming.
    func testEveryPhraseMapEntryIsCoveredBySubstringTriggers() {
        let cases: [(input: String, mustContain: String)] = [
            ("Hello, new line, thanks", "\n"),
            ("Hello, next line, thanks", "\n"),
            ("first item, line break, second item", "\n"),
            ("name, insert line, address", "\n"),
            ("done. New paragraph. Next topic", "\n\n"),
            ("done. Next paragraph. Next topic", "\n\n"),
            ("intro. Skip a line. Body", "\n\n"),
        ]
        for item in cases {
            let result = f(item.input)
            XCTAssertTrue(
                result.contains(item.mustContain),
                "phrase gate missed transform for \(item.input.debugDescription); got \(result.debugDescription)"
            )
            XCTAssertNotEqual(result, item.input, "expected a transform for \(item.input.debugDescription)")
        }
    }
}
