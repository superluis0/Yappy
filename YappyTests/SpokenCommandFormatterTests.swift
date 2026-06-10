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
}
