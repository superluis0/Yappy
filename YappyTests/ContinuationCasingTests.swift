//
//  ContinuationCasingTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class ContinuationCasingTests: XCTestCase {

    func testInsertTimingFormatterContainsOnlyDeclaredMetrics() {
        let timing = TextInserter.InsertTiming(
            transcribeMs: 210, audioMs: 4300,
            cleanupMs: 12, classifyMs: 3, spaceMs: 1,
            snapMs: 4, snapBytes: 2048, confirmMs: 51,
            restoreMs: 2, opaque: false, polls: 2,
            field: FocusedFieldKind.singleLine, words: 3
        )

        XCTAssertEqual(
            timing.formattedLine,
            "insert-timing transcribe_ms=210 audio_ms=4300 cleanup_ms=12 "
                + "classify_ms=3 space_ms=1 snap_ms=4 "
                + "snap_bytes=2048 confirm_ms=51 restore_ms=2 opaque=0 polls=2 "
                + "field=singleLine words=3"
        )
        XCTAssertFalse(timing.formattedLine.contains("transcript"))
    }

    // MARK: - continuesSentence(after:)

    func testContinuesAfterWord() {
        XCTAssertTrue(ContinuationCasing.continuesSentence(after: "have a"))
    }

    func testContinuesAfterWordAndTrailingSpace() {
        XCTAssertTrue(ContinuationCasing.continuesSentence(after: "have a "))
    }

    func testContinuesAfterComma() {
        XCTAssertTrue(ContinuationCasing.continuesSentence(after: "well,"))
    }

    func testContinuesAfterDigit() {
        XCTAssertTrue(ContinuationCasing.continuesSentence(after: "at 7"))
    }

    func testDoesNotContinueAfterPeriod() {
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: "done."))
    }

    func testDoesNotContinueAfterPeriodAndSpace() {
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: "done. "))
    }

    func testDoesNotContinueAfterQuestionMark() {
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: "right?"))
    }

    func testDoesNotContinueAfterExclamation() {
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: "wow!"))
    }

    func testDoesNotContinueAfterNewline() {
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: "line\n"))
    }

    func testDoesNotContinueAfterNewlineAndSpaces() {
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: "line\n  "))
    }

    func testDoesNotContinueAfterClosingQuote() {
        // Conservative: a closing quote usually follows a terminator.
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: "said.\""))
    }

    func testDoesNotContinueOnEmpty() {
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: ""))
    }

    func testDoesNotContinueOnWhitespaceOnly() {
        XCTAssertFalse(ContinuationCasing.continuesSentence(after: "   "))
    }

    // MARK: - decapitalized(_:protecting:)

    func testDecapitalizesSentenceCasedWord() {
        XCTAssertEqual(ContinuationCasing.decapitalized("Tomorrow at seven"),
                       "tomorrow at seven")
    }

    func testDecapitalizesSingleLetterArticle() {
        XCTAssertEqual(ContinuationCasing.decapitalized("A quick note"), "a quick note")
    }

    func testDecapitalizesContraction() {
        XCTAssertEqual(ContinuationCasing.decapitalized("Don't forget"), "don't forget")
    }

    func testKeepsPronounI() {
        XCTAssertEqual(ContinuationCasing.decapitalized("I think so"), "I think so")
    }

    func testKeepsIContraction() {
        XCTAssertEqual(ContinuationCasing.decapitalized("I'm not sure"), "I'm not sure")
        XCTAssertEqual(ContinuationCasing.decapitalized("I'll check"), "I'll check")
    }

    func testKeepsAcronym() {
        XCTAssertEqual(ContinuationCasing.decapitalized("HTTP requests fail"),
                       "HTTP requests fail")
    }

    func testKeepsMixedCaseName() {
        XCTAssertEqual(ContinuationCasing.decapitalized("McRae said no"), "McRae said no")
    }

    func testKeepsLowercaseStart() {
        XCTAssertEqual(ContinuationCasing.decapitalized("already lowercase"),
                       "already lowercase")
    }

    func testKeepsNonLetterStart() {
        XCTAssertEqual(ContinuationCasing.decapitalized("7:30 works for me"),
                       "7:30 works for me")
    }

    func testKeepsProtectedWord() {
        XCTAssertEqual(ContinuationCasing.decapitalized("Cigna is my insurer",
                                                        protecting: ["Cigna"]),
                       "Cigna is my insurer")
    }

    func testProtectionIsCaseSensitiveExactWord() {
        // A protected word only shields itself, not other words.
        XCTAssertEqual(ContinuationCasing.decapitalized("Tomorrow works",
                                                        protecting: ["Cigna"]),
                       "tomorrow works")
    }

    func testEmptyTextUntouched() {
        XCTAssertEqual(ContinuationCasing.decapitalized(""), "")
    }

    // MARK: - isJoinEligibleTail(_:)

    func testSinglePeriodTailIsEligible() {
        XCTAssertTrue(ContinuationCasing.isJoinEligibleTail("I have a call with Cigna tomorrow."))
    }

    func testQuestionMarkTailNotEligible() {
        XCTAssertFalse(ContinuationCasing.isJoinEligibleTail("does that work?"))
    }

    func testExclamationTailNotEligible() {
        XCTAssertFalse(ContinuationCasing.isJoinEligibleTail("that's great!"))
    }

    func testEllipsisTailNotEligible() {
        XCTAssertFalse(ContinuationCasing.isJoinEligibleTail("I was going to..."))
    }

    func testNoPunctuationTailNotEligible() {
        XCTAssertFalse(ContinuationCasing.isJoinEligibleTail("tomorrow at"))
    }

    // MARK: - startsAsStandaloneReply(_:)

    func testReplyWordsAreStandalone() {
        XCTAssertTrue(ContinuationCasing.startsAsStandaloneReply("Nope, still not working."))
        XCTAssertTrue(ContinuationCasing.startsAsStandaloneReply("Okay, next topic"))
        XCTAssertTrue(ContinuationCasing.startsAsStandaloneReply("yes that works"))
        XCTAssertTrue(ContinuationCasing.startsAsStandaloneReply("Actually, four."))
        XCTAssertTrue(ContinuationCasing.startsAsStandaloneReply("Wait a second"))
    }

    func testContinuationsAreNotStandaloneReplies() {
        XCTAssertFalse(ContinuationCasing.startsAsStandaloneReply("I can't stop"))
        XCTAssertFalse(ContinuationCasing.startsAsStandaloneReply("7:30 A.M."))
        XCTAssertFalse(ContinuationCasing.startsAsStandaloneReply("Seven thirty"))
        XCTAssertFalse(ContinuationCasing.startsAsStandaloneReply("tomorrow at noon"))
    }

    func testEmptyIsNotStandaloneReply() {
        XCTAssertFalse(ContinuationCasing.startsAsStandaloneReply(""))
        XCTAssertFalse(ContinuationCasing.startsAsStandaloneReply("…"))
    }

    func testStandaloneReplyBlocksEvenFunctionWordRepair() {
        // "…tomorrow at." + "Nope, still not working." — the reply word wins:
        // the pivot to a new message must never be glued onto the fragment,
        // even though "at." alone would qualify for the deterministic repair.
        XCTAssertTrue(ContinuationCasing.endsWithMidSentencePeriod("call with Cigna tomorrow at."))
        XCTAssertTrue(ContinuationCasing.startsAsStandaloneReply("Nope, still not working."))
    }

    // MARK: - endsWithMidSentencePeriod(_:)

    func testFragmentEndingInPrepositionPlusPeriod() {
        // The exact case from the wild: cleanup appended "." to a fragment.
        XCTAssertTrue(ContinuationCasing.endsWithMidSentencePeriod(
            "I have a call with Signa tomorrow at."))
    }

    func testFragmentEndingInArticle() {
        XCTAssertTrue(ContinuationCasing.endsWithMidSentencePeriod("Hand me the."))
    }

    func testFragmentEndingInConjunction() {
        XCTAssertTrue(ContinuationCasing.endsWithMidSentencePeriod("I wanted to go and."))
    }

    func testCompleteSentenceNotFlagged() {
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod("I have a call tomorrow."))
    }

    func testAuxiliaryEndingIsLegitimate() {
        // "I will." / "You should." are complete sentences — never repaired.
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod("Yes, I will."))
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod("I think so."))
    }

    func testNoTrailingPeriodNotFlagged() {
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod("tomorrow at"))
    }

    func testQuestionMarkNotFlagged() {
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod("what are you looking at?"))
    }

    func testEllipsisNotFlagged() {
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod("I was going to..."))
    }

    func testDigitBeforePeriodNotFlagged() {
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod("meet at 7."))
    }

    func testCaseInsensitiveFunctionWord() {
        XCTAssertTrue(ContinuationCasing.endsWithMidSentencePeriod("The."))
    }

    func testBarePeriodNotFlagged() {
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod("."))
        XCTAssertFalse(ContinuationCasing.endsWithMidSentencePeriod(""))
    }

    // MARK: - End-to-end shape of the reported bug

    func testReportedScenario() {
        // First dictation ended mid-sentence: "...call with Cigna tomorrow at"
        // Second dictation arrives sentence-capitalized: "Seven thirty."
        let preceding = "tomorrow at"
        XCTAssertTrue(ContinuationCasing.continuesSentence(after: preceding))
        XCTAssertEqual(ContinuationCasing.decapitalized("Seven thirty."), "seven thirty.")
    }
}
