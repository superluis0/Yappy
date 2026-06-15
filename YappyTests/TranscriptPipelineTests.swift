//
//  TranscriptPipelineTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class TranscriptPipelineTests: XCTestCase {

    private func pipeline(
        fillers: Bool = true, numbers: Bool = true, lists: Bool = true,
        commands: Bool = true, punctuation: Bool = true
    ) -> TranscriptPipeline {
        TranscriptPipeline(
            removeFillers: fillers, formatNumbers: numbers, formatLists: lists,
            applyCommands: commands, applyPunctuation: punctuation
        )
    }

    func testFullPipelineIntegration() {
        XCTAssertEqual(
            pipeline().process("Um, twenty dollars, new line, thanks"),
            "$20\nThanks"
        )
    }

    func testFillerHealsNumberRun() {
        // Removing the parenthetical filler joins the number words into one run.
        XCTAssertEqual(pipeline().process("twenty, um, three"), "23")
    }

    func testFillersFlagDisablesStage() {
        XCTAssertEqual(
            pipeline(fillers: false).process("I was, um, counting to ten"),
            "I was, um, counting to 10"
        )
    }

    func testNumbersFlagDisablesStage() {
        XCTAssertEqual(
            pipeline(numbers: false).process("I was, um, counting to ten"),
            "I was counting to ten"
        )
    }

    func testCommandsFlagDisablesStage() {
        XCTAssertEqual(
            pipeline(commands: false).process("Hello, new line, thanks"),
            "Hello, new line, thanks"
        )
    }

    func testAllOffIsIdentity() {
        let input = "Um, twenty dollars, new line, thanks"
        XCTAssertEqual(
            pipeline(fillers: false, numbers: false, lists: false,
                     commands: false, punctuation: false).process(input),
            input
        )
    }

    func testNumberedListAfterNumberFormatting() {
        // Spoken counters become digits, then a list.
        XCTAssertEqual(
            pipeline().process("buy one milk two eggs three bread"),
            "buy\n1. Milk\n2. Eggs\n3. Bread"
        )
    }

    func testListsFlagDisablesStage() {
        XCTAssertEqual(
            pipeline(lists: false).process("buy one milk two eggs three bread"),
            "buy 1 milk 2 eggs 3 bread"
        )
    }

    func testSpokenPunctuationApplied() {
        XCTAssertEqual(
            pipeline().process("hello comma world question mark"),
            "hello, world?"
        )
    }

    func testPunctuationFlagDisablesStage() {
        XCTAssertEqual(
            pipeline(punctuation: false).process("hello comma world"),
            "hello comma world"
        )
    }
}
