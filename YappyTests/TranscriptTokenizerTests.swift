//
//  TranscriptTokenizerTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class TranscriptTokenizerTests: XCTestCase {

    private func assertRoundTrip(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let tokens = TranscriptTokenizer.tokenize(text)
        let rendered = TranscriptTokenizer.render(tokens)
        XCTAssertEqual(rendered, text, "round-trip failed for \(text.debugDescription)", file: file, line: line)
    }

    func testRoundTripPlainText() {
        assertRoundTrip("hello world")
    }

    func testRoundTripMultispace() {
        assertRoundTrip("hello   world")
    }

    func testRoundTripLeadingAndTrailingSpace() {
        assertRoundTrip("  leading")
        assertRoundTrip("trailing  ")
        assertRoundTrip("  both  ")
    }

    func testRoundTripEmpty() {
        assertRoundTrip("")
        XCTAssertTrue(TranscriptTokenizer.tokenize("").isEmpty)
        XCTAssertEqual(TranscriptTokenizer.render([]), "")
    }

    func testRoundTripEmoji() {
        assertRoundTrip("hello 👋 world")
        assertRoundTrip("🎉 party 🎊")
    }

    func testRoundTripCombiningCharacters() {
        // e + combining acute accent
        let combining = "cafe\u{0301}"
        assertRoundTrip(combining)
        assertRoundTrip("naïve")
    }

    func testRoundTripNewlines() {
        assertRoundTrip("line one\nline two")
        assertRoundTrip("a\n\nb")
        assertRoundTrip("trailing\n")
    }

    func testIsSpaceOnlyTrueForSpaces() {
        XCTAssertTrue(TranscriptTokenizer.isSpaceOnly(" "))
        XCTAssertTrue(TranscriptTokenizer.isSpaceOnly("   "))
    }

    func testIsSpaceOnlyFalseForEmpty() {
        XCTAssertFalse(TranscriptTokenizer.isSpaceOnly(""))
    }

    func testIsSpaceOnlyFalseForTabsNewlinesOrMixed() {
        XCTAssertFalse(TranscriptTokenizer.isSpaceOnly("\t"))
        XCTAssertFalse(TranscriptTokenizer.isSpaceOnly("\n"))
        XCTAssertFalse(TranscriptTokenizer.isSpaceOnly(" \n"))
        XCTAssertFalse(TranscriptTokenizer.isSpaceOnly(" a "))
        XCTAssertFalse(TranscriptTokenizer.isSpaceOnly("."))
    }

    func testTokenKinds() {
        let tokens = TranscriptTokenizer.tokenize("Hi, world!")
        XCTAssertEqual(tokens.map(\.text), ["Hi", ", ", "world", "!"])
        XCTAssertTrue(tokens[0].isWord)
        XCTAssertFalse(tokens[1].isWord)
    }
}
