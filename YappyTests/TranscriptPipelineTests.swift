//
//  TranscriptPipelineTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class TranscriptPipelineTests: XCTestCase {

    private func pipeline(
        fillers: Bool = true, numbers: Bool = true, commands: Bool = true
    ) -> TranscriptPipeline {
        TranscriptPipeline(removeFillers: fillers, formatNumbers: numbers, applyCommands: commands)
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
            pipeline(fillers: false, numbers: false, commands: false).process(input),
            input
        )
    }
}
