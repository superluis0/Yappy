//
//  AskRunTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class AskRunTests: XCTestCase {
    // MARK: - Think harder modifier

    func testExtractThinkHarderStripsLeadingCommaModifier() {
        let extracted = AskController.extractThinkHarder("think harder, what is x")

        XCTAssertEqual(extracted.question, "what is x")
        XCTAssertTrue(extracted.thinkHarder)
    }

    func testExtractThinkHarderStripsLeadingAboutModifier() {
        let extracted = AskController.extractThinkHarder("Think hard about y")

        XCTAssertEqual(extracted.question, "y")
        XCTAssertTrue(extracted.thinkHarder)
    }

    func testExtractThinkHarderAloneIsQuestion() {
        let extracted = AskController.extractThinkHarder("think harder")

        XCTAssertEqual(extracted.question, "think harder")
        XCTAssertFalse(extracted.thinkHarder)
    }

    func testExtractThinkHarderNearMissIsQuestion() {
        let extracted = AskController.extractThinkHarder("rethink harder about x")

        XCTAssertEqual(extracted.question, "rethink harder about x")
        XCTAssertFalse(extracted.thinkHarder)
    }

    func testExtractThinkHarderPlainQuestionIsUnchanged() {
        let extracted = AskController.extractThinkHarder("what is x")

        XCTAssertEqual(extracted.question, "what is x")
        XCTAssertFalse(extracted.thinkHarder)
    }

    func testExtractThinkHarderStripsLeadingPeriodModifier() {
        let extracted = AskController.extractThinkHarder("THINK HARDER. compare a and b")

        XCTAssertEqual(extracted.question, "compare a and b")
        XCTAssertTrue(extracted.thinkHarder)
    }

    // MARK: - Card voice commands

    func testParseCardCommandSynonyms() {
        XCTAssertEqual(AskController.parseCardCommand("copy that"), .copy)
        XCTAssertEqual(AskController.parseCardCommand("copy it"), .copy)
        XCTAssertEqual(AskController.parseCardCommand("copy the answer"), .copy)

        XCTAssertEqual(AskController.parseCardCommand("insert that"), .insert)
        XCTAssertEqual(AskController.parseCardCommand("insert it"), .insert)
        XCTAssertEqual(AskController.parseCardCommand("insert the answer"), .insert)
        XCTAssertEqual(AskController.parseCardCommand("type that"), .insert)

        XCTAssertEqual(AskController.parseCardCommand("dismiss"), .dismiss)
        XCTAssertEqual(AskController.parseCardCommand("close"), .dismiss)
        XCTAssertEqual(AskController.parseCardCommand("dismiss that"), .dismiss)
        XCTAssertEqual(AskController.parseCardCommand("close that"), .dismiss)

        XCTAssertEqual(AskController.parseCardCommand("try again"), .retry)
        XCTAssertEqual(AskController.parseCardCommand("ask again"), .retry)
        XCTAssertEqual(AskController.parseCardCommand("retry"), .retry)

        XCTAssertEqual(AskController.parseCardCommand("pin that"), .pin)
        XCTAssertEqual(AskController.parseCardCommand("pin it"), .pin)
        XCTAssertEqual(AskController.parseCardCommand("keep that"), .pin)
    }

    func testParseCardCommandNormalizesCaseAndSingleTrailingPunctuation() {
        XCTAssertEqual(AskController.parseCardCommand("copy that."), .copy)
        XCTAssertEqual(AskController.parseCardCommand("Copy That"), .copy)
        XCTAssertEqual(AskController.parseCardCommand("  INSERT IT!\n"), .insert)
    }

    func testParseCardCommandNearMissesReturnNil() {
        XCTAssertNil(AskController.parseCardCommand("copy that thing"))
        XCTAssertNil(AskController.parseCardCommand("please dismiss"))
        XCTAssertNil(AskController.parseCardCommand("pin"))
        XCTAssertNil(AskController.parseCardCommand("copy that?"))
        XCTAssertNil(AskController.parseCardCommand("copy that.."))
    }

    // MARK: - Lifecycle

    func testAskRunTracksLifecycleAndCompletionDate() throws {
        var run = AskRun(rawTranscript: "what were the top AI headlines this week", status: .listening)

        XCTAssertEqual(run.status, .listening)
        XCTAssertNil(run.completedAt)

        try run.transition(to: .transcribing)
        try run.transition(to: .thinking)
        run.appendStep("Searching the web", state: .running, kind: .search)
        try run.transition(to: .working)
        run.answerText = "The biggest story was…"
        try run.transition(to: .completed)

        XCTAssertEqual(run.status, .completed)
        XCTAssertNotNil(run.completedAt)
        XCTAssertEqual(run.steps.map(\.title), ["Searching the web"])
        XCTAssertEqual(run.steps.first?.kind, .search)
        XCTAssertEqual(run.answerText, "The biggest story was…")
    }

    func testFastAnswerCanSkipStraightToCompleted() throws {
        var run = AskRun(rawTranscript: "hi", status: .thinking)
        // thinking → completed is allowed for answers that need no tool work.
        XCTAssertNoThrow(try run.transition(to: .completed))
        XCTAssertTrue(run.status.isTerminal)
    }

    func testRejectsInvalidLifecycleTransition() {
        var run = AskRun(rawTranscript: "hello", status: .listening)

        XCTAssertThrowsError(try run.transition(to: .completed)) { error in
            XCTAssertEqual(error as? AskRunTransitionError, .invalidTransition(from: .listening, to: .completed))
        }
    }

    func testCancelIsAlwaysReachableFromActiveStates() throws {
        for start in [AskRunStatus.idle, .preparing, .listening, .transcribing, .thinking, .working] {
            var run = AskRun(rawTranscript: "q", status: start)
            XCTAssertNoThrow(try run.transition(to: .cancelled), "cancel should be reachable from \(start)")
        }
    }

    func testPreparingToListeningPathIsValid() throws {
        var run = AskRun(rawTranscript: "", status: .idle)
        try run.transition(to: .preparing)
        try run.transition(to: .listening)
        try run.transition(to: .transcribing)
        try run.transition(to: .thinking)
        try run.transition(to: .completed)
        XCTAssertEqual(run.status, .completed)
    }

    func testPreparingToCompletedIsInvalid() {
        var run = AskRun(rawTranscript: "q", status: .preparing)
        XCTAssertThrowsError(try run.transition(to: .completed)) { error in
            XCTAssertEqual(error as? AskRunTransitionError, .invalidTransition(from: .preparing, to: .completed))
        }
    }

    func testCompletedCanReturnToListeningForFollowUp() throws {
        var run = AskRun(rawTranscript: "first", status: .thinking)
        try run.transition(to: .completed)

        XCTAssertNoThrow(try run.transition(to: .listening))
        XCTAssertEqual(run.status, .listening)
    }

    func testThinkingAndWorkingCanBargeInToListening() throws {
        var thinking = AskRun(rawTranscript: "q", status: .thinking)
        XCTAssertNoThrow(try thinking.transition(to: .listening))
        XCTAssertEqual(thinking.status, .listening)

        var working = AskRun(rawTranscript: "q", status: .working)
        XCTAssertNoThrow(try working.transition(to: .listening))
        XCTAssertEqual(working.status, .listening)
    }

    func testIdleCannotJumpToWorking() {
        var run = AskRun(rawTranscript: "q", status: .idle)
        XCTAssertThrowsError(try run.transition(to: .working)) { error in
            XCTAssertEqual(error as? AskRunTransitionError, .invalidTransition(from: .idle, to: .working))
        }
    }

    func testCancelledAndFailedCannotReturnToListening() throws {
        var cancelled = AskRun(rawTranscript: "q", status: .listening)
        try cancelled.transition(to: .cancelled)
        XCTAssertThrowsError(try cancelled.transition(to: .listening)) { error in
            XCTAssertEqual(error as? AskRunTransitionError, .invalidTransition(from: .cancelled, to: .listening))
        }

        var failed = AskRun(rawTranscript: "q", status: .thinking)
        try failed.transition(to: .failed)
        XCTAssertThrowsError(try failed.transition(to: .listening)) { error in
            XCTAssertEqual(error as? AskRunTransitionError, .invalidTransition(from: .failed, to: .listening))
        }
    }

    func testThinkHarderRoundTripsThroughCodable() throws {
        let run = AskRun(rawTranscript: "why?", status: .thinking, thinkHarder: true)

        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(AskRun.self, from: data)

        XCTAssertTrue(decoded.thinkHarder)
    }

    func testTurnsRoundTripThroughCodable() throws {
        let turns = [
            AskTurn(question: "First?", answer: "First answer."),
            AskTurn(question: "Second?", answer: "Second answer.")
        ]
        let run = AskRun(rawTranscript: "third", status: .completed, turns: turns)

        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(AskRun.self, from: data)

        XCTAssertEqual(decoded.turns, turns)
    }
}
