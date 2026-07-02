//
//  VoiceEditCommandParserTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class VoiceEditCommandParserTests: XCTestCase {

    private func p(_ s: String) -> VoiceEditCommand? { VoiceEditCommandParser.parse(s) }

    // MARK: - Positive matches

    func testDeleteLastSynonyms() {
        XCTAssertEqual(p("scratch that"), .deleteLast)
        XCTAssertEqual(p("delete that"), .deleteLast)
        XCTAssertEqual(p("remove that"), .deleteLast)
        XCTAssertEqual(p("scratch this"), .deleteLast)
    }

    func testGranularDeletes() {
        XCTAssertEqual(p("delete the last word"), .deleteLastWord)
        XCTAssertEqual(p("delete last word"), .deleteLastWord)
        XCTAssertEqual(p("delete the last sentence"), .deleteLastSentence)
        XCTAssertEqual(p("delete the last line"), .deleteLastLine)
    }

    func testCaseCommands() {
        XCTAssertEqual(p("capitalize that"), .capitalizeThat)
        XCTAssertEqual(p("all caps that"), .allCapsThat)
        XCTAssertEqual(p("uppercase that"), .allCapsThat)
        XCTAssertEqual(p("make that uppercase"), .allCapsThat)
        XCTAssertEqual(p("lowercase that"), .lowercaseThat)
        XCTAssertEqual(p("make that lowercase"), .lowercaseThat)
    }

    // MARK: - Normalization tolerance

    func testTrailingPunctuationTolerated() {
        XCTAssertEqual(p("Scratch that."), .deleteLast)
        XCTAssertEqual(p("scratch that!"), .deleteLast)
    }

    func testLeadingFillerTolerated() {
        XCTAssertEqual(p("um, scratch that"), .deleteLast)
        XCTAssertEqual(p("uh scratch that"), .deleteLast)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(p("ALL CAPS THAT"), .allCapsThat)
    }

    // MARK: - Ambiguity traps (must NOT match)

    func testProseIsNotACommand() {
        XCTAssertNil(p("scratch that idea"))
        XCTAssertNil(p("let me capitalize that word for you"))
        XCTAssertNil(p("delete the last word from the file"))
        XCTAssertNil(p("I need to delete that email"))
        XCTAssertNil(p("scratch that and let's move on"))
    }

    func testNewLineBelongsToOtherFormatter() {
        XCTAssertNil(p("new line"))
        XCTAssertNil(p("new paragraph"))
    }

    func testPlainTextIsNil() {
        XCTAssertNil(p("the quick brown fox"))
        XCTAssertNil(p(""))
    }

    // MARK: - Transforms

    func testTransforms() {
        XCTAssertEqual(VoiceEditCommandParser.transform(.allCapsThat, applyingTo: "hello world"), "HELLO WORLD")
        XCTAssertEqual(VoiceEditCommandParser.transform(.lowercaseThat, applyingTo: "Hello World"), "hello world")
        XCTAssertEqual(VoiceEditCommandParser.transform(.capitalizeThat, applyingTo: "hello world"), "Hello World")
        XCTAssertNil(VoiceEditCommandParser.transform(.deleteLast, applyingTo: "hello"))
    }

    // MARK: - Trailing-range math

    func testTrailingWord() {
        XCTAssertEqual(TextEditMath.trailingWordLength(of: "hello world"), 6)   // " world"
        XCTAssertEqual(TextEditMath.trailingWordLength(of: "world"), 5)
        XCTAssertEqual(TextEditMath.trailingWordLength(of: "hello world "), 7)  // trailing space + " world"...
    }

    func testTrailingSentence() {
        XCTAssertEqual(TextEditMath.trailingSentenceLength(of: "Hi. Bye."), 5)  // " Bye."
        XCTAssertEqual(TextEditMath.trailingSentenceLength(of: "Just one sentence"), 17)
        XCTAssertEqual(TextEditMath.trailingSentenceLength(of: "One. Two. Three."), 7) // " Three."
    }

    func testTrailingLine() {
        XCTAssertEqual(TextEditMath.trailingLineLength(of: "line1\nline2"), 6)   // "\nline2"
        XCTAssertEqual(TextEditMath.trailingLineLength(of: "single line"), 11)
    }

    // MARK: - Set-selection range math (accessibility fast path)

    func testSelectionRangeReachesBackFromCaret() {
        // Caret after 11 chars, select the last 6 → origin 5, length 6.
        let range = TextEditMath.selectionRange(caretLocation: 11, length: 6)
        XCTAssertEqual(range?.location, 5)
        XCTAssertEqual(range?.length, 6)
    }

    func testSelectionRangeAtStartOfSelectionOrigin() {
        // Selecting exactly as many chars as precede the caret → origin 0.
        let range = TextEditMath.selectionRange(caretLocation: 4, length: 4)
        XCTAssertEqual(range?.location, 0)
        XCTAssertEqual(range?.length, 4)
    }

    func testSelectionRangeRejectsUnderflow() {
        // A stale/wrong caret closer to the field start than our insertion is
        // long must NOT produce a negative origin — we'd select the wrong span.
        XCTAssertNil(TextEditMath.selectionRange(caretLocation: 3, length: 6))
        XCTAssertNil(TextEditMath.selectionRange(caretLocation: 0, length: 1))
    }

    func testSelectionRangeRejectsNonPositiveLength() {
        XCTAssertNil(TextEditMath.selectionRange(caretLocation: 10, length: 0))
        XCTAssertNil(TextEditMath.selectionRange(caretLocation: 10, length: -2))
    }

    // MARK: - "cap that" shorthand

    func testCapThatShorthand() {
        XCTAssertEqual(p("cap that"), .capitalizeThat)
        XCTAssertEqual(p("cap this"), .capitalizeThat)
    }

    // MARK: - Submit ("press enter") parsing

    func testSubmitWholeUtterance() {
        let r = SubmitCommandParser.parse("press enter")
        XCTAssertEqual(r.text, "")
        XCTAssertTrue(r.submit)
    }

    func testSubmitTrailing() {
        let r = SubmitCommandParser.parse("send this to the team press enter")
        XCTAssertEqual(r.text, "send this to the team")
        XCTAssertTrue(r.submit)
    }

    func testSubmitTrailingWithPunctuation() {
        let r = SubmitCommandParser.parse("Looks good. Press return.")
        XCTAssertEqual(r.text, "Looks good.")
        XCTAssertTrue(r.submit)
    }

    func testSubmitProseNotTrailingIgnored() {
        let r = SubmitCommandParser.parse("press enter to continue the setup")
        XCTAssertEqual(r.text, "press enter to continue the setup")
        XCTAssertFalse(r.submit)
    }

    func testNoSubmitCommand() {
        let r = SubmitCommandParser.parse("just a normal sentence")
        XCTAssertEqual(r.text, "just a normal sentence")
        XCTAssertFalse(r.submit)
    }
}
