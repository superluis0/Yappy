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
        // No "1." markers proves the list stage is off. The counters now stay
        // spelled out because nothing marks them as quantities once the list
        // stage isn't there to claim them — mid-sentence digits ("buy 1 milk")
        // are the exact prose problem the small-number guard exists to avoid.
        // With lists ON (the default, and the test above) this same input still
        // becomes a numbered list: SpokenListFormatter matches words and digits.
        XCTAssertEqual(
            pipeline(lists: false).process("buy one milk two eggs three bread"),
            "buy one milk two eggs three bread"
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

    // MARK: - Verbatim escape ("type literally" / "type exactly")

    func testVerbatimPrefixTypeLiterallyStripsAndBypassesFormatters() {
        // Fillers/numbers/punctuation must NOT run on the remainder.
        let result = pipeline().processDetailed("type literally um twenty dollars period")
        XCTAssertTrue(result.isVerbatim)
        XCTAssertEqual(result.text, "um twenty dollars period")
    }

    func testVerbatimPrefixTypeExactly() {
        let result = pipeline().processDetailed("type exactly scratch that")
        XCTAssertTrue(result.isVerbatim)
        XCTAssertEqual(result.text, "scratch that")
    }

    func testVerbatimPrefixWithColon() {
        let result = pipeline().processDetailed("type literally: hello comma world")
        XCTAssertTrue(result.isVerbatim)
        // Prefix parse happens BEFORE spoken-punctuation formatting, so "comma"
        // stays the spoken word, not ",".
        XCTAssertEqual(result.text, "hello comma world")
    }

    func testVerbatimPrefixWithCommaSeparator() {
        let result = pipeline().processDetailed("type exactly, keep this um raw")
        XCTAssertTrue(result.isVerbatim)
        XCTAssertEqual(result.text, "keep this um raw")
    }

    func testVerbatimPrefixCaseInsensitive() {
        let result = pipeline().processDetailed("Type Literally Hello")
        XCTAssertTrue(result.isVerbatim)
        XCTAssertEqual(result.text, "Hello")
    }

    func testVerbatimPrefixWholeWordOnly() {
        // "type literallyish" must NOT match — not a whole-prefix escape.
        let result = pipeline().processDetailed("type literallyish hello")
        XCTAssertFalse(result.isVerbatim)
    }

    func testStripVerbatimPrefixStandalone() {
        XCTAssertEqual(
            TranscriptPipeline.stripVerbatimPrefix("type literally scratch that"),
            "scratch that"
        )
        XCTAssertNil(TranscriptPipeline.stripVerbatimPrefix("please type literally nothing"))
        XCTAssertNil(TranscriptPipeline.stripVerbatimPrefix("hello world"))
    }

    func testProcessConvenienceReturnsTextOnly() {
        XCTAssertEqual(
            pipeline().process("type literally raw text"),
            "raw text"
        )
    }

    // MARK: - Cross-stage interactions (F27)
    //
    // These exercise how the stages compose on a full, realistic dictation —
    // numbers → lists → line-break commands → spoken punctuation — and lock the
    // CURRENT behavior so a later refactor can't silently change it. A few known
    // cross-stage quirks are deferred to backlog plan 007 (spoken-punctuation
    // words don't yet anchor a command; the bullet/list interaction needs a
    // second pass). Those are written as explicit characterization tests below,
    // documenting today's behavior — NOT the eventual fix.

    func testCombinedNumberNewlineAndSpokenPunctuation() {
        // Number formatting (20), a comma-anchored spoken "new line" (real break +
        // recapitalized "Ship"), and a spoken "question mark" all fire together.
        XCTAssertEqual(
            pipeline().process("i have twenty items, new line, ship them question mark"),
            "i have 20 items\nShip them?"
        )
    }

    func testCombinedNumbersNewlineAndQuestion() {
        // A second full-utterance combo: the number, the break, and the question
        // mark are produced by three different stages in the right order.
        XCTAssertEqual(
            pipeline().process("call twenty people, new line, are we ready question mark"),
            "call 20 people\nAre we ready?"
        )
    }

    func testNumberFormattingFeedsListItems() {
        // Numbers run before lists, so "five percent"/"two percent" are already
        // "5%"/"2%" by the time the list of "step one/two/three" is built.
        XCTAssertEqual(
            pipeline().process("step one add five percent step two subtract two percent step three done"),
            "1. Add 5%\n2. Subtract 2%\n3. Done"
        )
    }

    func testIdempotentOnCombinedUtterance() {
        // Re-processing an already-formatted combined utterance is a no-op.
        let once = pipeline().process("i have twenty items, new line, ship them question mark")
        XCTAssertEqual(pipeline().process(once), once)
    }

    func testIdempotentOnNumberedList() {
        // Re-processing an already-formatted numbered list is a no-op: the digits
        // and "N. Item" lines don't re-trigger any stage.
        let once = pipeline().process("buy one milk two eggs three bread")
        XCTAssertEqual(pipeline().process(once), once)
    }

    func testIdempotentOnNumberAndSpokenPunctuation() {
        let once = pipeline().process("i owe you twenty dollars period thanks")
        XCTAssertEqual(once, "i owe you $20. Thanks")
        XCTAssertEqual(pipeline().process(once), once)
    }

    // TODO(plan 007): current buggy behavior, update when fixed.
    // Spoken-punctuation words ("period") do not yet act as command anchors,
    // because punctuation runs AFTER the command stage — so at command time the
    // literal word "period" (not ".") sits left of "new line" and the break never
    // fires. The "period" still converts (punctuation is last), leaving the spoken
    // "new line" as literal prose.
    func testSpokenPunctuationWordDoesNotYetAnchorCommand() {
        XCTAssertEqual(
            pipeline().process("first line period new line second line"),
            "first line. New line second line"
        )
    }

    // TODO(plan 007): current buggy behavior, update when fixed.
    // A spoken "new line" landing between list counters is inserted by the command
    // stage, but the list stage (which already ran) built its items around it — the
    // injected break collapses to a double newline on the first pass. A second pass
    // normalizes it, so the pipeline is NOT idempotent for this ordering.
    func testNewlineInsideListIsNotIdempotent() {
        let once = pipeline().process("one milk, new line, two eggs three bread")
        XCTAssertEqual(once, "1. Milk\n\n2. Eggs\n3. Bread")
        let twice = pipeline().process(once)
        XCTAssertEqual(twice, "1. Milk\n2. Eggs\n3. Bread")
        XCTAssertNotEqual(once, twice)
    }

    // TODO(plan 007): current buggy behavior, update when fixed.
    // The bullet stage anchors a "bullet" marker only after sentence punctuation,
    // but the spoken "period" isn't a "." until the punctuation stage runs LAST —
    // one stage too late. So the first pass converts "period" -> "." and capitalizes
    // "Bullet" but does NOT form the list; a second pass (with the real ".") does.
    func testBulletListNeedsSecondPassForPunctuationAnchor() {
        let once = pipeline().process("bring the following period bullet milk bullet eggs bullet bread")
        XCTAssertEqual(once, "bring the following. Bullet milk bullet eggs bullet bread")
        let twice = pipeline().process(once)
        XCTAssertEqual(twice, "bring the following.\n- Milk\n- Eggs\n- Bread")
        XCTAssertNotEqual(once, twice)
    }
}
