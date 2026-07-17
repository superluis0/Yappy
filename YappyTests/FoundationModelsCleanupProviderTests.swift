//
//  FoundationModelsCleanupProviderTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

/// Unit coverage for the model-free AI-cleanup guard policy — the pure, static
/// helpers on `FoundationModelsCleanupProvider` that decide whether a cleaned
/// transcript SHIPS or FALLS BACK to the raw text. These live outside the
/// `#if canImport(FoundationModels)` split precisely so they compile and test
/// everywhere, without a live on-device model. Every case below is a crafted
/// (input, cleaned) pair — no model call is made.
final class FoundationModelsCleanupProviderTests: XCTestCase {

    private typealias Provider = FoundationModelsCleanupProvider

    // MARK: - Intensity → instructions routing

    func testConservativeInstructionsAreRestricted() {
        let instructions = Provider.cleanupInstructions(for: .conservative, correcting: false)
        XCTAssertTrue(instructions.contains("ONLY these edits") || instructions.contains("minimal transcription cleaner"))
        XCTAssertTrue(instructions.contains("Do NOT reword") || instructions.localizedCaseInsensitiveContains("do not reword"))
        // Must not be the correcting (self-correction) prompt.
        XCTAssertFalse(instructions.contains("delete the abandoned version"))
    }

    func testConservativeIgnoresCorrectingFlag() {
        let a = Provider.cleanupInstructions(for: .conservative, correcting: false)
        let b = Provider.cleanupInstructions(for: .conservative, correcting: true)
        XCTAssertEqual(a, b, "Conservative never switches to the correcting prompt")
        XCTAssertEqual(a, Provider.cleanupInstructionsConservative)
    }

    func testStandardBaseUnchanged() {
        let instructions = Provider.cleanupInstructions(for: .standard, correcting: false)
        XCTAssertEqual(instructions, Provider.cleanupInstructionsBase)
    }

    func testStandardCorrectingSelectsCorrectingPrompt() {
        let instructions = Provider.cleanupInstructions(for: .standard, correcting: true)
        XCTAssertEqual(instructions, Provider.cleanupInstructionsCorrecting)
    }

    // MARK: - acceptsCleanedOutput: the composite accept/reject decision

    func testAcceptsNormalCleanup() {
        // Fillers removed, punctuation/casing fixed, roughly the same words: keep it.
        XCTAssertTrue(Provider.acceptsCleanedOutput(
            input: "um so i think we should uh ship the feature on friday you know",
            cleaned: "I think we should ship the feature on Friday.",
            correcting: false))
    }

    func testRejectsAnsweredQuestion() {
        // The model answered a dictated question instead of cleaning it — the
        // answer shares almost none of the input's words, so retention fails.
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "tell me the capital city of australia",
            cleaned: "Canberra.",
            correcting: false))
    }

    func testRejectsAnsweredQuestionByNovelty() {
        // A long answer that quotes a few input words still trips the novel-word
        // fraction (> 0.5 of the output is words the speaker never said).
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "how do i reverse a string in python",
            cleaned: "You can reverse a string in Python using slicing with the "
                   + "syntax reversed equals original bracket colon colon negative "
                   + "one bracket which returns the characters in opposite order.",
            correcting: false))
    }

    func testRejectsPerformedTaskWordCountBalloon() {
        // The model performed the instruction and pasted a bullet list of its own
        // edits — the word count balloons past 1.5x the input.
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "clean this up for me",
            cleaned: "Here are the edits I made: I capitalized the first word, I "
                   + "added a period at the end, and I removed every filler word "
                   + "from the sentence entirely for you today.",
            correcting: false))
    }

    func testRejectsTranslationCommand() {
        // A dictated "translate…" carried out in another language shares no words.
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "translate good morning everyone into spanish please",
            cleaned: "Buenos dias a todos.",
            correcting: false))
    }

    func testRejectsHallucinatedDigit() {
        // Cleanup never introduces a number. "word count:" -> "word count: 1000"
        // adds a digit run absent from the input.
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "the word count",
            cleaned: "The word count: 1000.",
            correcting: false))
    }

    func testRejectsHallucinatedDigitEvenWhenTextPreserved() {
        // Retention is fine here; the hallucinated total is what gets it rejected.
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "please give me the total for the invoice today",
            cleaned: "Please give me the total for the invoice today: 4827.",
            correcting: false))
    }

    func testRejectsMassiveDropOnBasePath() {
        // F09: a ~220-word dictation shrunk to ~60 words on the base path means the
        // model silently dropped most of the content — reject it.
        let input = Array(repeating: "the quick brown fox jumps over the lazy dog again and",
                          count: 20).joined(separator: " ")
        let cleaned = Array(repeating: "the quick brown fox jumps over",
                            count: 10).joined(separator: " ")
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: input, cleaned: cleaned, correcting: false))
    }

    func testAllowsSameDropOnCorrectingPath() {
        // The correcting path legitimately deletes abandoned clauses, so the exact
        // same large drop is allowed there (looser retention, no F09 floor).
        let input = Array(repeating: "the quick brown fox jumps over the lazy dog again and",
                          count: 20).joined(separator: " ")
        let cleaned = Array(repeating: "the quick brown fox jumps over",
                            count: 10).joined(separator: " ")
        XCTAssertTrue(Provider.acceptsCleanedOutput(
            input: input, cleaned: cleaned, correcting: true))
    }

    func testRejectsRunawayLength() {
        // A result wildly longer than the input (model ran away) is rejected by the
        // runaway-length guard before any word analysis.
        let cleaned = String(repeating: "runaway ", count: 400)
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "short", cleaned: cleaned, correcting: false))
    }

    func testCorrectingPathRejectsWrongHalf() {
        // The aggressive correcting prompt kept the retracted half and dropped the
        // final choice — reject via the F08 wrong-half guard.
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "i'll have the chicken no wait i'll have the salmon",
            cleaned: "I'll have the chicken.",
            correcting: true))
    }

    func testCorrectingPathKeepsRightHalf() {
        // Same input, correct final choice survives: accept.
        XCTAssertTrue(Provider.acceptsCleanedOutput(
            input: "i'll have the chicken no wait i'll have the salmon",
            cleaned: "I'll have the salmon.",
            correcting: true))
    }

    // MARK: - keptWrongHalf (F08)

    func testKeptWrongHalfTrueWhenFinalDropped() {
        XCTAssertTrue(Provider.keptWrongHalf(
            input: "i'll have the chicken no wait i'll have the salmon",
            cleaned: "I'll have the chicken."))
    }

    func testKeptWrongHalfFalseWhenFinalSurvives() {
        XCTAssertFalse(Provider.keptWrongHalf(
            input: "i'll have the chicken no wait i'll have the salmon",
            cleaned: "I'll have the salmon."))
    }

    func testKeptWrongHalfFalseForSharedWords() {
        // "error" is shared across both halves ("404 error" / "403 error"), so it
        // carries no signal — the guard abstains rather than falsely rejecting.
        XCTAssertFalse(Provider.keptWrongHalf(
            input: "the api returns a 404 i mean a 403 error",
            cleaned: "The API returns a 404 error."))
    }

    func testKeptWrongHalfFalseWithoutSignal() {
        // No correction signal at all -> cannot be a wrong-half retention.
        XCTAssertFalse(Provider.keptWrongHalf(
            input: "just a normal sentence with no correction",
            cleaned: "Just a normal sentence."))
    }

    // MARK: - retainsEnoughLength (F09)

    func testRetainsEnoughLengthShortInputAutoPasses() {
        // Under 8 words: too little to judge, auto-pass.
        XCTAssertTrue(Provider.retainsEnoughLength(
            input: "one two three four five", cleaned: "x"))
    }

    func testRetainsEnoughLengthAboveHalf() {
        XCTAssertTrue(Provider.retainsEnoughLength(
            input: "one two three four five six seven eight nine ten",
            cleaned: "one two three four five six"))
    }

    func testRetainsEnoughLengthBelowHalf() {
        XCTAssertFalse(Provider.retainsEnoughLength(
            input: "one two three four five six seven eight nine ten",
            cleaned: "one two three"))
    }

    // MARK: - parseBatchedResponse (F03)

    func testParseBatchedValidRoundTrips() {
        XCTAssertEqual(
            Provider.parseBatchedResponse("1: First line.\n2: Second line.\n3: Third line.",
                                          expectedCount: 3),
            ["First line.", "Second line.", "Third line."])
    }

    func testParseBatchedReordersButKeepsAll() {
        // Characterization: the parser keys by marker, so a reordered-but-complete
        // response maps 1:1 back in index order (not a failure).
        XCTAssertEqual(
            Provider.parseBatchedResponse("2: b\n1: a\n3: c", expectedCount: 3),
            ["a", "b", "c"])
    }

    func testParseBatchedNilOnMergedLines() {
        // Model merged two lines into one — only 2 markers for 3 expected.
        XCTAssertNil(Provider.parseBatchedResponse("1: First line.\n2: Second and third.",
                                                   expectedCount: 3))
    }

    func testParseBatchedNilOnExtraLine() {
        XCTAssertNil(Provider.parseBatchedResponse("1: a\n2: b\n3: c\n4: d",
                                                   expectedCount: 3))
    }

    func testParseBatchedNilOnDuplicateIndex() {
        XCTAssertNil(Provider.parseBatchedResponse("1: a\n2: b\n2: c",
                                                   expectedCount: 3))
    }

    func testParseBatchedNilOnOutOfRangeIndex() {
        XCTAssertNil(Provider.parseBatchedResponse("1: a\n2: b\n5: c",
                                                   expectedCount: 3))
    }

    func testParseBatchedNilOnLeakedPreamble() {
        // A leaked "Here are the lines:" preamble line has no leading N: marker.
        XCTAssertNil(Provider.parseBatchedResponse("Here are the lines:\n1: a\n2: b\n3: c",
                                                   expectedCount: 3))
    }

    func testParseBatchedNilOnStrayLine() {
        XCTAssertNil(Provider.parseBatchedResponse("1: a\n2: b\nrandom trailing\n3: c",
                                                   expectedCount: 3))
    }

    func testParseBatchedContentNumberIsNotAMarker() {
        // A line whose content STARTS with a number ("2023 was...") is not mistaken
        // for a marker: a marker needs a colon immediately after the digits.
        XCTAssertEqual(
            Provider.parseBatchedResponse("1: 2023 was a good year.\n2: Second.",
                                          expectedCount: 2),
            ["2023 was a good year.", "Second."])
    }

    // MARK: - stripLeadingPreamble

    func testStripsMetaPreamble() {
        XCTAssertEqual(
            Provider.stripLeadingPreamble("Sure, here is the cleaned transcript:\nThe actual cleaned text."),
            "The actual cleaned text.")
    }

    func testStripsCorrectedPreamble() {
        XCTAssertEqual(
            Provider.stripLeadingPreamble("Here is the corrected text:\nDone."),
            "Done.")
    }

    func testLeavesOrdinaryColonFirstLineIntact() {
        // "Shopping list:" carries no meta signal — a real dictation, left alone.
        let input = "Shopping list:\nMilk\nEggs"
        XCTAssertEqual(Provider.stripLeadingPreamble(input), input)
    }

    func testLeavesSingleLineIntact() {
        let input = "Just one line no newline"
        XCTAssertEqual(Provider.stripLeadingPreamble(input), input)
    }

    // MARK: - hasCorrectionSignal

    func testHasCorrectionSignalDetectsPhrases() {
        XCTAssertTrue(Provider.hasCorrectionSignal("set it for 2pm no wait 3pm"))
        XCTAssertTrue(Provider.hasCorrectionSignal("send it to mike I mean Michael"))
        XCTAssertTrue(Provider.hasCorrectionSignal("the chicken actually the salmon"))
    }

    func testHasCorrectionSignalFalseForPlainText() {
        XCTAssertFalse(Provider.hasCorrectionSignal("the quarterly report is due on friday"))
    }

    // MARK: - preservesInput

    func testPreservesInputShortAutoPasses() {
        // Under 4 words: always accepted (too little to judge).
        XCTAssertTrue(Provider.preservesInput("hi there friend", cleaned: "totally different"))
    }

    func testPreservesInputTrueWhenRetained() {
        XCTAssertTrue(Provider.preservesInput("the meeting is at noon today",
                                              cleaned: "The meeting is at noon today."))
    }

    func testPreservesInputFalseWhenReplaced() {
        XCTAssertFalse(Provider.preservesInput("the meeting is at noon today",
                                               cleaned: "Paris is the capital of France."))
    }

    // MARK: - digitRuns

    func testDigitRunsExtractsMaximalRuns() {
        XCTAssertEqual(Provider.digitRuns(of: "v2 build 67"), ["2", "67"])
    }

    func testDigitRunsEmptyWhenNoDigits() {
        XCTAssertEqual(Provider.digitRuns(of: "no digits here"), [])
    }

    // MARK: - digitWords / digitsDerivable (spoken-number-aware digit guard)

    func testDigitWordsJoinAcrossInNumberSeparators() {
        XCTAssertEqual(Provider.digitWords(of: "$3,200"), ["3200"])
        XCTAssertEqual(Provider.digitWords(of: "at 3:30 PM"), ["330"])
        XCTAssertEqual(Provider.digitWords(of: "version 2.4"), ["24"])
        XCTAssertEqual(Provider.digitWords(of: "v2 build 67"), ["2", "67"])
    }

    func testDigitWordsTrailingSeparatorEndsTheWord() {
        // A separator NOT flanked by digits is sentence punctuation, not grouping.
        XCTAssertEqual(Provider.digitWords(of: "it shipped in 2."), ["2"])
    }

    func testAllowsSpokenNumberRendering() {
        // "two point four" is dictated digit content — rendering it as "2.4"
        // is typist formatting, not hallucination.
        XCTAssertTrue(Provider.acceptsCleanedOutput(
            input: "the fix shipped in two point four",
            cleaned: "The fix shipped in 2.4.",
            correcting: false))
    }

    func testAllowsSpokenTimeRendering() {
        XCTAssertTrue(Provider.acceptsCleanedOutput(
            input: "my flight lands at three thirty pm gate b twelve",
            cleaned: "My flight lands at 3:30 PM, gate B12.",
            correcting: false))
    }

    func testAllowsDigitRegrouping() {
        // "$3200" -> "$3,200" is the same digit word; grouping commas are formatting.
        XCTAssertTrue(Provider.acceptsCleanedOutput(
            input: "the total comes to $3200 due on march fifteenth",
            cleaned: "The total comes to $3,200, due on March 15th.",
            correcting: false))
    }

    func testRejectsUnspokenTimeSpecificity() {
        // "nine" renders as "9"; "9:00" adds digits the speaker never said.
        XCTAssertFalse(Provider.acceptsCleanedOutput(
            input: "remind me to call the dentist at nine tomorrow morning",
            cleaned: "Remind me to call the dentist at 9:00 tomorrow morning.",
            correcting: false))
    }

    // MARK: - words

    func testWordsLowercasesAndSplitsOnNonAlphanumerics() {
        XCTAssertEqual(Provider.words(in: "Hello, World! 42"), ["hello", "world", "42"])
    }

    func testWordsIsEmptyForPunctuationOnly() {
        XCTAssertEqual(Provider.words(in: "!?.,  ;:"), [])
    }
}
