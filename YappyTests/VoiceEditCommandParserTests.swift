//
//  VoiceEditCommandParserTests.swift
//  YappyTests
//

import AppKit
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

    func testUseRawTranscriptPhrases() {
        XCTAssertEqual(p("use what I said"), .useRawTranscript)
        XCTAssertEqual(p("use what I actually said"), .useRawTranscript)
        XCTAssertEqual(p("undo the cleanup"), .useRawTranscript)
        XCTAssertEqual(p("undo that cleanup"), .useRawTranscript)
    }

    func testUseRawTranscriptNearMissesAreNotCommands() {
        // Whole-utterance rule: extra words make it prose, not a command.
        XCTAssertNil(p("use what I said about the budget"))
        XCTAssertNil(p("undo the cleanup and start over"))
        XCTAssertNil(p("I'll use what I said earlier"))
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
        // Reverting to the raw transcript isn't a string transform (AppDelegate
        // holds the pre-cleanup words), so transform returns nil.
        XCTAssertNil(VoiceEditCommandParser.transform(.useRawTranscript, applyingTo: "hello"))
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

// MARK: - TransformEngine (Voice Edit Anywhere)

final class TransformEngineTests: XCTestCase {

    // MARK: parse — deterministic intents + phrasing variants

    func testParseBulletVariants() {
        for phrase in ["make this bullets", "make this bullet points", "bullet these",
                       "turn this into a list", "make a list", "make it a list", "as a list"] {
            XCTAssertEqual(TransformEngine.parse(phrase), .bullets, phrase)
        }
    }

    func testParseNumberedListBeatsGenericList() {
        for phrase in ["make this a numbered list", "numbered list", "ordered list",
                       "number these", "make it a numbered list"] {
            XCTAssertEqual(TransformEngine.parse(phrase), .numberedList, phrase)
        }
    }

    func testParseJoinLines() {
        for phrase in ["make this one line", "put it on one line", "single line",
                       "make it one paragraph", "join these lines", "merge these lines",
                       "combine into one paragraph"] {
            XCTAssertEqual(TransformEngine.parse(phrase), .joinLines, phrase)
        }
    }

    func testParseCaseTransforms() {
        XCTAssertEqual(TransformEngine.parse("make this uppercase"), .uppercase)
        XCTAssertEqual(TransformEngine.parse("all caps this"), .uppercase)
        XCTAssertEqual(TransformEngine.parse("make it all caps"), .uppercase)
        XCTAssertEqual(TransformEngine.parse("in capital letters"), .uppercase)
        XCTAssertEqual(TransformEngine.parse("lowercase this"), .lowercase)
        XCTAssertEqual(TransformEngine.parse("make it lower case"), .lowercase)
        XCTAssertEqual(TransformEngine.parse("title case this"), .titleCase)
        XCTAssertEqual(TransformEngine.parse("capitalize this"), .titleCase)
        XCTAssertEqual(TransformEngine.parse("capitalize each word"), .titleCase)
    }

    func testParseRemoveFiller() {
        XCTAssertEqual(TransformEngine.parse("remove the filler words"), .removeFiller)
        XCTAssertEqual(TransformEngine.parse("remove the ums"), .removeFiller)
    }

    func testParseTrailingPunctuationIsIgnored() {
        XCTAssertEqual(TransformEngine.parse("make this bullets."), .bullets)
        XCTAssertEqual(TransformEngine.parse("Make it uppercase!"), .uppercase)
    }

    func testUnknownInstructionsFallToGenerative() {
        XCTAssertEqual(TransformEngine.parse("make it more formal"),
                       .generative(instruction: "make it more formal"))
        XCTAssertEqual(TransformEngine.parse("summarize this in one sentence for me"),
                       .generative(instruction: "summarize this in one sentence for me"))
        XCTAssertEqual(TransformEngine.parse("translate to spanish"),
                       .generative(instruction: "translate to spanish"))
    }

    func testEmptyInstructionIsGenerative() {
        XCTAssertEqual(TransformEngine.parse(""), .generative(instruction: ""))
        XCTAssertEqual(TransformEngine.parse("   "), .generative(instruction: ""))
    }

    // MARK: apply — deterministic ops

    func testGenerativeApplyReturnsNil() {
        XCTAssertNil(TransformEngine.apply(.generative(instruction: "x"), to: "anything"))
    }

    func testBulletsFromNewlines() {
        XCTAssertEqual(TransformEngine.apply(.bullets, to: "a\nb\nc"), "- a\n- b\n- c")
    }

    func testBulletsFromSentences() {
        XCTAssertEqual(TransformEngine.apply(.bullets, to: "Buy milk. Call mom. Sleep."),
                       "- Buy milk\n- Call mom\n- Sleep")
    }

    func testBulletsFromCommasWhenNoSentences() {
        XCTAssertEqual(TransformEngine.apply(.bullets, to: "milk, eggs, bread"),
                       "- milk\n- eggs\n- bread")
    }

    func testBulletsSingleItem() {
        XCTAssertEqual(TransformEngine.apply(.bullets, to: "just one thing"), "- just one thing")
    }

    func testNumberedList() {
        XCTAssertEqual(TransformEngine.apply(.numberedList, to: "milk, eggs, bread"),
                       "1. milk\n2. eggs\n3. bread")
    }

    func testNewlinesTakePriorityOverCommas() {
        // Explicit line structure wins over commas within a line.
        XCTAssertEqual(TransformEngine.apply(.numberedList, to: "a, b\nc, d"),
                       "1. a, b\n2. c, d")
    }

    func testJoinLinesCollapsesWhitespace() {
        XCTAssertEqual(TransformEngine.apply(.joinLines, to: "line one\nline two"),
                       "line one line two")
        XCTAssertEqual(TransformEngine.apply(.joinLines, to: "a  b\tc\n\nd"), "a b c d")
    }

    func testCaseApply() {
        XCTAssertEqual(TransformEngine.apply(.uppercase, to: "Hello there"), "HELLO THERE")
        XCTAssertEqual(TransformEngine.apply(.lowercase, to: "HeLLo THERE"), "hello there")
        XCTAssertEqual(TransformEngine.apply(.titleCase, to: "hello there world"), "Hello There World")
    }

    func testRemoveFillerMatchesFillerWordRemover() {
        let input = "um hello uh there you know world"
        XCTAssertEqual(TransformEngine.apply(.removeFiller, to: input),
                       FillerWordRemover.remove(input))
    }

    // MARK: sanitizeGenerative

    func testSanitizeStripsPreambleColonLine() {
        XCTAssertEqual(
            TransformEngine.sanitizeGenerative("Here is the formal version:\nGood morning, team.",
                                               original: "hi team"),
            "Good morning, team.")
    }

    func testSanitizeStripsInlinePreamble() {
        XCTAssertEqual(
            TransformEngine.sanitizeGenerative("Sure, here's the rewrite: Hello there.",
                                               original: "yo"),
            "Hello there.")
    }

    func testSanitizeRejectsEmpty() {
        XCTAssertNil(TransformEngine.sanitizeGenerative("   ", original: "x"))
    }

    func testSanitizeRejectsIdenticalEcho() {
        XCTAssertNil(TransformEngine.sanitizeGenerative("hello world", original: "hello world"))
        XCTAssertNil(TransformEngine.sanitizeGenerative("  hello world  ", original: "hello world"))
    }

    func testSanitizeKeepsGenuineTransform() {
        XCTAssertEqual(TransformEngine.sanitizeGenerative("Greetings, everyone.", original: "hi all"),
                       "Greetings, everyone.")
    }

    func testSanitizeLeavesNonPreambleContentIntact() {
        // A line ending in ":" that isn't a preamble ("Shopping list:") is kept.
        XCTAssertEqual(
            TransformEngine.sanitizeGenerative("Shopping list:\n- milk", original: "milk"),
            "Shopping list:\n- milk")
    }
}

// MARK: - SelectionTransformController fakes

final class FakeVoiceEditRecorder: VoiceEditRecording {
    var startResult = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var samples: [Float] = [0.1, 0.2, 0.3]
    func startRecording() -> Bool { startCount += 1; return startResult }
    func stopRecording() -> [Float] { stopCount += 1; return samples }
}

@MainActor
final class FakeVoiceEditTranscriber: VoiceEditTranscribing {
    var transcript = ""
    var error: Error?
    private(set) var calls = 0
    var gate: CheckedContinuation<Void, Never>?
    var waitForGate = false
    func transcribe(_ samples: [Float]) async throws -> String {
        calls += 1
        if waitForGate { await withCheckedContinuation { gate = $0 } }
        if let error { throw error }
        return transcript
    }
}

@MainActor
final class FakeVoiceEditInserter: VoiceEditInserting {
    /// Simulates whether the origin app is (still) frontmost when Replace runs.
    var frontmost = true
    private(set) var activateCount = 0
    private(set) var pasted: [String] = []
    private(set) var copied: [String] = []
    func activateOrigin(_ origin: NSRunningApplication?) async { activateCount += 1 }
    func isFrontmost(_ origin: NSRunningApplication?) -> Bool { frontmost }
    func paste(_ text: String) { pasted.append(text) }
    func copyToClipboard(_ text: String) { copied.append(text) }
}

@MainActor
final class FakeVoiceEditSelection: VoiceEditSelecting {
    var text = ""
    private(set) var captureCount = 0
    /// Invoked inside `captureSelection`, to simulate a hotkey release/cancel
    /// dispatched while the (run-loop-pumping) capture is still in flight.
    var onCapture: (() -> Void)?
    func captureSelection() -> VoiceEditSelection {
        captureCount += 1
        onCapture?()
        return VoiceEditSelection(text: text, origin: nil)
    }
}

@MainActor
final class FakeVoiceEditGenerative: VoiceEditGenerating {
    var available = true
    var output: String?
    private(set) var transformCalls = 0
    var gate: CheckedContinuation<Void, Never>?
    var waitForGate = false
    func isAvailable() async -> Bool { available }
    func transform(_ text: String, instruction: String) async -> String? {
        transformCalls += 1
        if waitForGate { await withCheckedContinuation { gate = $0 } }
        return output
    }
}

// MARK: - SelectionTransformController state machine

@MainActor
final class SelectionTransformControllerTests: XCTestCase {

    private func makeController() -> (SelectionTransformController,
                                      FakeVoiceEditRecorder,
                                      FakeVoiceEditTranscriber,
                                      FakeVoiceEditInserter,
                                      FakeVoiceEditSelection,
                                      FakeVoiceEditGenerative) {
        let recorder = FakeVoiceEditRecorder()
        let transcriber = FakeVoiceEditTranscriber()
        let inserter = FakeVoiceEditInserter()
        let selection = FakeVoiceEditSelection()
        let generative = FakeVoiceEditGenerative()
        let controller = SelectionTransformController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            selection: selection, generative: generative)
        return (controller, recorder, transcriber, inserter, selection, generative)
    }

    private func yieldUntil(_ condition: () -> Bool, max: Int = 60,
                            file: StaticString = #file, line: UInt = #line) async {
        for _ in 0..<max {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition not met", file: file, line: line)
    }

    // MARK: Busy guard

    func testBusyGuardBlocksCaptureAndRecording() {
        let (controller, recorder, _, _, selection, _) = makeController()
        controller.isBusy = { true }
        selection.text = "hello"

        controller.begin()

        XCTAssertEqual(controller.stage, .idle)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(selection.captureCount, 0, "busy is checked before touching the selection")
    }

    // MARK: Empty selection

    func testEmptySelectionShowsCaptionAndDoesNotRecord() {
        let (controller, recorder, _, _, selection, _) = makeController()
        selection.text = "   "

        controller.begin()

        XCTAssertEqual(controller.stage, .idle)
        XCTAssertEqual(controller.caption, "Select some text first")
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(selection.captureCount, 1)
    }

    // MARK: Happy deterministic path + one-replace

    func testDeterministicBulletsPreviewThenSingleReplace() async {
        let (controller, recorder, transcriber, inserter, selection, _) = makeController()
        var feedback: [VoiceEditFeedback] = []
        controller.onFeedback = { feedback.append($0) }
        selection.text = "a\nb"

        controller.begin()
        XCTAssertEqual(controller.stage, .listening)
        XCTAssertEqual(recorder.startCount, 1)

        transcriber.transcript = "make this bullets"
        controller.endListening()
        await yieldUntil { controller.stage == .preview }

        XCTAssertEqual(controller.original, "a\nb")
        XCTAssertEqual(controller.instruction, "make this bullets")
        XCTAssertEqual(controller.result, "- a\n- b")

        controller.replace()   // async: re-activate origin, verify frontmost, paste
        await yieldUntil { controller.stage == .idle }
        XCTAssertEqual(inserter.pasted, ["- a\n- b"])
        XCTAssertTrue(inserter.copied.isEmpty)

        controller.replace()   // one-shot: stage is .idle, no second paste
        await Task.yield()
        XCTAssertEqual(inserter.pasted.count, 1)

        XCTAssertEqual(feedback, [.listeningStarted, .listeningStopped, .replaced])
    }

    func testReplaceCopiesWhenOriginLostFocus() async {
        // The origin app is no longer frontmost (user typed/clicked/switched) —
        // the selection is dead, so Replace must copy, never paste blind.
        let (controller, _, transcriber, inserter, selection, _) = makeController()
        inserter.frontmost = false
        selection.text = "hi"

        controller.begin()
        transcriber.transcript = "make it uppercase"
        controller.endListening()
        await yieldUntil { controller.stage == .preview }

        controller.replace()
        await yieldUntil { controller.caption != nil }

        XCTAssertTrue(inserter.pasted.isEmpty, "must not paste over a stale selection")
        XCTAssertEqual(inserter.copied, ["HI"])
        XCTAssertEqual(controller.caption, "Selection changed — result copied instead")
    }

    // MARK: Generative path

    func testGenerativePathShowsPreview() async {
        let (controller, _, transcriber, _, selection, generative) = makeController()
        selection.text = "hi all"
        generative.available = true
        generative.output = "Greetings, everyone."

        controller.begin()
        transcriber.transcript = "make it more formal"
        controller.endListening()
        await yieldUntil { controller.stage == .preview }

        XCTAssertEqual(controller.result, "Greetings, everyone.")
        XCTAssertEqual(generative.transformCalls, 1)
    }

    func testGenerativeUnavailableShowsAppleIntelligenceCaption() async {
        let (controller, _, transcriber, _, selection, generative) = makeController()
        selection.text = "hi all"
        generative.available = false

        controller.begin()
        transcriber.transcript = "make it more formal"
        controller.endListening()
        await yieldUntil { controller.caption != nil }

        XCTAssertEqual(controller.caption, "Needs Apple Intelligence (macOS 26)")
        XCTAssertNotEqual(controller.stage, .preview)
        XCTAssertEqual(generative.transformCalls, 0)
    }

    func testGenerativeEchoIsRejected() async {
        let (controller, _, transcriber, _, selection, generative) = makeController()
        selection.text = "hello"
        generative.available = true
        generative.output = "hello"   // identical echo

        controller.begin()
        transcriber.transcript = "make it more formal"
        controller.endListening()
        await yieldUntil { controller.caption != nil }

        XCTAssertNotEqual(controller.stage, .preview)
    }

    // MARK: Empty transcript

    func testEmptyTranscriptDiscardsWithoutPreview() async {
        let (controller, _, transcriber, _, selection, _) = makeController()
        selection.text = "x"

        controller.begin()
        transcriber.transcript = "   "
        controller.endListening()
        await yieldUntil { controller.stage == .cancelled }

        XCTAssertNotEqual(controller.stage, .preview)
    }

    // MARK: Cancel at every stage

    func testCancelWhileListeningStopsRecorder() {
        let (controller, recorder, _, _, selection, _) = makeController()
        selection.text = "x"

        controller.begin()
        XCTAssertEqual(controller.stage, .listening)
        controller.cancel()

        XCTAssertEqual(controller.stage, .cancelled)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertFalse(controller.isActive)
    }

    func testCancelWhileTransformingDropsResult() async {
        let (controller, _, transcriber, _, selection, _) = makeController()
        selection.text = "x"
        transcriber.waitForGate = true

        controller.begin()
        transcriber.transcript = "make this bullets"
        controller.endListening()
        XCTAssertEqual(controller.stage, .transforming)
        await yieldUntil { transcriber.gate != nil }

        controller.cancel()
        transcriber.gate?.resume()
        await Task.yield()
        await Task.yield()

        XCTAssertNotEqual(controller.stage, .preview)
        XCTAssertEqual(controller.result, "")
    }

    func testCancelWhilePreviewClears() async {
        let (controller, _, transcriber, inserter, selection, _) = makeController()
        selection.text = "x"

        controller.begin()
        transcriber.transcript = "make it uppercase"
        controller.endListening()
        await yieldUntil { controller.stage == .preview }

        controller.cancel()
        XCTAssertEqual(controller.stage, .cancelled)
        XCTAssertTrue(inserter.pasted.isEmpty)
        XCTAssertFalse(controller.isActive)
    }

    // MARK: Stale generation

    func testStaleGenerativeCannotTouchCancelledSession() async {
        let (controller, _, transcriber, inserter, selection, generative) = makeController()
        selection.text = "hello"
        generative.available = true
        generative.output = "Greetings."
        generative.waitForGate = true

        controller.begin()
        transcriber.transcript = "make it more formal"
        controller.endListening()
        await yieldUntil { generative.gate != nil }   // parked inside transform()

        controller.cancel()                            // bumps the generation
        generative.gate?.resume()                      // stale result arrives late
        await Task.yield()
        await Task.yield()

        XCTAssertNotEqual(controller.stage, .preview)
        XCTAssertEqual(controller.result, "")
        XCTAssertTrue(inserter.pasted.isEmpty)
    }

    // MARK: Try again reuses the same selection

    func testTryAgainReusesSelectionWithoutRecapture() async {
        let (controller, _, transcriber, _, selection, _) = makeController()
        selection.text = "a, b, c"

        controller.begin()
        transcriber.transcript = "make this bullets"
        controller.endListening()
        await yieldUntil { controller.stage == .preview }
        let capturesAfterFirst = selection.captureCount

        controller.tryAgain()
        XCTAssertEqual(controller.stage, .idle)

        transcriber.transcript = "make it uppercase"
        controller.begin()
        XCTAssertEqual(controller.stage, .listening)
        XCTAssertEqual(selection.captureCount, capturesAfterFirst,
                       "try again reuses the retained selection, no new capture")

        controller.endListening()
        await yieldUntil { controller.stage == .preview }
        XCTAssertEqual(controller.result, "A, B, C")
    }

    // MARK: Escape-interceptor lifecycle

    func testActiveChangedFiresOnListeningAndCancel() {
        let (controller, _, _, _, selection, _) = makeController()
        selection.text = "x"
        var active: [Bool] = []
        controller.onActiveChanged = { active.append($0) }

        controller.begin()
        controller.cancel()

        XCTAssertEqual(active, [true, false])
    }

    // MARK: P2-5 — retry prompt must not swallow Escape

    func testTryAgainDisarmsEscapeAndReListeningRearms() async {
        let (controller, _, transcriber, _, selection, _) = makeController()
        var active: [Bool] = []
        controller.onActiveChanged = { active.append($0) }
        selection.text = "a, b"

        controller.begin()
        transcriber.transcript = "make this bullets"
        controller.endListening()
        await yieldUntil { controller.stage == .preview }

        controller.tryAgain()
        XCTAssertEqual(active, [true, false],
                       "try again must disarm Escape so it isn't swallowed system-wide")

        controller.begin()   // re-hold on the retained selection
        XCTAssertEqual(active, [true, false, true], "re-listening re-arms Escape")
    }

    // MARK: P1-2 — unbounded recording is capped

    func testMaxDurationTimeoutStopsAndTranscribes() async {
        let (controller, recorder, transcriber, _, selection, _) = makeController()
        controller.maxRecordingDuration = 0.05
        selection.text = "x"
        transcriber.transcript = "make it uppercase"

        controller.begin()
        XCTAssertEqual(controller.stage, .listening)
        // Never release the key — the max-duration timer must stop it.
        try? await Task.sleep(nanoseconds: 250_000_000)
        await yieldUntil { controller.stage == .preview }

        XCTAssertEqual(recorder.stopCount, 1, "the timeout stops the recorder like a key-up")
        XCTAssertEqual(controller.result, "X")
    }

    // MARK: P1-3 — release during the capture run-loop pump

    func testReleaseDuringCaptureDoesNotRecord() {
        let (controller, recorder, _, _, selection, _) = makeController()
        selection.text = "x"
        // Simulate the Right Option release dispatched while captureSelection is
        // still pumping the run loop (Cmd+C fallback).
        selection.onCapture = { [weak controller] in controller?.endListening() }

        controller.begin()

        XCTAssertEqual(controller.stage, .idle, "a release during capture must abort, not record")
        XCTAssertEqual(recorder.startCount, 0)
    }

    // MARK: P2-6 — silent clip doesn't hallucinate an instruction

    func testSilentClipShowsDidntCatchAndRetries() async {
        let (controller, _, transcriber, _, selection, _) = makeController()
        controller.hasSpeech = { _ in false }
        selection.text = "hello"

        controller.begin()
        transcriber.transcript = "this must never be read"
        controller.endListening()

        XCTAssertEqual(controller.caption, "Didn't catch that")
        XCTAssertNotEqual(controller.stage, .preview)
        XCTAssertEqual(transcriber.calls, 0, "a silent clip must not be transcribed")

        // The retry reuses the same selection on the next hold.
        let capturesBefore = selection.captureCount
        controller.hasSpeech = { _ in true }
        transcriber.transcript = "make it uppercase"
        controller.begin()
        controller.endListening()
        await yieldUntil { controller.stage == .preview }

        XCTAssertEqual(selection.captureCount, capturesBefore, "silent-clip retry reuses the selection")
        XCTAssertEqual(controller.result, "HELLO")
    }
}
