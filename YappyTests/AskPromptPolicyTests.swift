//
//  AskPromptPolicyTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class AskPromptPolicyTests: XCTestCase {
    private var pinnedDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 3, hour: 19, minute: 58
        ))!
    }

    func testSystemInstructionsContainsAnswerContract() {
        let instructions = AskPromptPolicy.systemInstructions
        XCTAssertFalse(instructions.isEmpty)
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("start with the answer"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("cite"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("read-only"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("shell commands"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("searching for"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("let me check"))
    }

    func testSystemInstructionsContainsNewAnswerRules() {
        let instructions = AskPromptPolicy.systemInstructions
        XCTAssertTrue(instructions.contains("web search only when"))
        XCTAssertTrue(instructions.contains("markdown link"))
        XCTAssertTrue(instructions.contains("homophones"))
    }

    func testWrapIncludesInstructionsAndQuestion() {
        let question = "What is the capital of France?"
        let wrapped = AskPromptPolicy.wrap(question: question, priorTurns: [], date: pinnedDate)

        XCTAssertTrue(wrapped.hasPrefix(AskPromptPolicy.systemInstructions))
        XCTAssertTrue(wrapped.contains(question))
        XCTAssertGreaterThan(
            wrapped.range(of: question)!.lowerBound,
            wrapped.range(of: AskPromptPolicy.systemInstructions)!.upperBound
        )
        XCTAssertTrue(wrapped.contains("Question:\n\(question)"))
        XCTAssertTrue(wrapped.contains("Context: it is"))
    }

    func testWrapIncludesPriorTurnsBeforeQuestion() {
        let wrapped = AskPromptPolicy.wrap(
            question: "How about Wednesday?",
            priorTurns: [(question: "What about Tuesday?", answer: "Tuesday is open.")],
            date: pinnedDate
        )

        XCTAssertTrue(wrapped.contains("Context: it is"))
        XCTAssertTrue(wrapped.contains("Earlier in this conversation:"))
        XCTAssertTrue(wrapped.contains("Q: What about Tuesday?"))
        XCTAssertTrue(wrapped.contains("A: Tuesday is open."))
        XCTAssertGreaterThan(
            wrapped.range(of: "Question:\nHow about Wednesday?")!.lowerBound,
            wrapped.range(of: "A: Tuesday is open.")!.upperBound
        )
    }

    func testWrapTruncatesLongPriorAnswers() {
        let longAnswer = String(repeating: "x", count: 650)
        let wrapped = AskPromptPolicy.wrap(
            question: "What next?",
            priorTurns: [(question: "What happened?", answer: longAnswer)],
            date: pinnedDate
        )

        XCTAssertTrue(wrapped.contains("A: \(String(repeating: "x", count: 600))…"))
        XCTAssertFalse(wrapped.contains(String(repeating: "x", count: 601)))
    }

    func testWrapIncludesAtMostLastFourPriorTurns() {
        let turns = (1...5).map { index in
            (question: "Question \(index)?", answer: "Answer \(index).")
        }
        let wrapped = AskPromptPolicy.wrap(question: "Current?", priorTurns: turns, date: pinnedDate)

        XCTAssertFalse(wrapped.contains("Q: Question 1?"))
        for index in 2...5 {
            XCTAssertTrue(wrapped.contains("Q: Question \(index)?"))
            XCTAssertTrue(wrapped.contains("A: Answer \(index)."))
        }
        XCTAssertTrue(wrapped.hasSuffix("Question:\nCurrent?"))
    }

    func testContextPrefixCarriesTurnsWithoutInstructions() {
        let prefix = AskPromptPolicy.contextPrefix(
            question: "And tomorrow?",
            priorTurns: [(question: "Weather today?", answer: "Sunny.")],
            date: pinnedDate
        )

        XCTAssertFalse(prefix.contains(AskPromptPolicy.systemInstructions))
        XCTAssertTrue(prefix.contains("Context: it is"))
        XCTAssertTrue(prefix.contains(TimeZone.current.identifier))
        XCTAssertTrue(prefix.contains("Q: Weather today?"))
        XCTAssertTrue(prefix.contains("A: Sunny."))
        XCTAssertTrue(prefix.hasSuffix("Question:\nAnd tomorrow?"))
    }

    func testContextPrefixDateHeaderFormat() {
        let prefix = AskPromptPolicy.contextPrefix(
            question: "Hello?",
            priorTurns: [],
            date: pinnedDate
        )

        XCTAssertTrue(prefix.hasPrefix("Context: it is"))
        XCTAssertTrue(prefix.contains("(\(TimeZone.current.identifier))."))
        XCTAssertTrue(prefix.contains("Question:\nHello?"))
    }
}
