//
//  AppStateTests.swift
//  YappyTests
//
//  Created on 2026-01-27.
//

import XCTest
import AppKit
@testable import Yappy

final class AppStateTests: XCTestCase {

    var state: AppState!

    override func setUp() {
        super.setUp()
        state = AppState()
    }

    override func tearDown() {
        state = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        // Verify initial state values
        XCTAssertFalse(state.isRecording, "isRecording should be false initially")
        XCTAssertFalse(state.isProcessing, "isProcessing should be false initially")
        XCTAssertTrue(state.isIdle, "isIdle should be true initially")
        XCTAssertEqual(state.audioLevels.count, Constants.pillBarCount, "audioLevels should have Constants.pillBarCount elements")
        XCTAssertTrue(state.audioLevels.allSatisfy { $0 == 0.0 }, "All audio levels should be zero initially")
        XCTAssertEqual(state.currentTranscription, "", "currentTranscription should be empty string initially")
        XCTAssertNil(state.error, "error should be nil initially")
    }

    // MARK: - Recording State Tests

    func testStartRecording() {
        // Start recording
        state.startRecording()

        // Verify state changes
        XCTAssertTrue(state.isRecording, "isRecording should be true after startRecording()")
        XCTAssertFalse(state.isIdle, "isIdle should be false after startRecording()")
        XCTAssertNil(state.error, "error should be nil after startRecording()")
        XCTAssertFalse(state.isProcessing, "isProcessing should remain false after startRecording()")

        // Verify audio levels reset
        XCTAssertEqual(state.audioLevels.count, Constants.pillBarCount, "audioLevels should still have Constants.pillBarCount elements")
        XCTAssertTrue(state.audioLevels.allSatisfy { $0 == 0.0 }, "All audio levels should be reset to zero")
    }

    func testStopRecording() {
        // Start and then stop recording
        state.startRecording()
        state.stopRecording()

        // Verify state changes
        XCTAssertFalse(state.isRecording, "isRecording should be false after stopRecording()")
        XCTAssertTrue(state.isProcessing, "isProcessing should be true after stopRecording()")
    }

    func testStopRecordingGuardClause() {
        // Stop recording without starting - should have no effect
        state.stopRecording()

        // Verify state remains unchanged
        XCTAssertFalse(state.isRecording, "isRecording should remain false")
        XCTAssertFalse(state.isProcessing, "isProcessing should remain false")
    }

    // MARK: - Overlap Invariant (F01)

    /// Regression guard for the "press during processing" bug. `AppState` itself
    /// does NOT make recording and processing mutually exclusive: starting a new
    /// recording while the previous utterance is still processing flips
    /// `isRecording` back on and leaves `isProcessing` true. That's precisely why
    /// the overlap guard must live in `AppDelegate.startDictation` (which also
    /// checks `isProcessing`) rather than being enforced here — if a future change
    /// made `startRecording` clear `isProcessing`, this test should fail loudly so
    /// the guard's rationale isn't silently invalidated.
    func testStartRecordingDuringProcessingDoesNotClearProcessing() {
        state.startRecording()
        state.stopRecording()
        XCTAssertTrue(state.isProcessing, "precondition: processing after stopRecording()")

        // A second recording begins while the first is still processing.
        state.startRecording()

        XCTAssertTrue(state.isRecording, "startRecording() re-enters recording even mid-processing")
        XCTAssertTrue(
            state.isProcessing,
            "AppState provides no recording/processing mutual exclusion — the overlap guard lives in startDictation"
        )
    }

    // MARK: - Polishing Sub-Phase Tests

    func testPolishingLifecycle() {
        XCTAssertFalse(state.isPolishing, "isPolishing should be false initially")

        state.beginPolishing()
        XCTAssertTrue(state.isPolishing, "isPolishing should be true after beginPolishing()")

        state.endPolishing()
        XCTAssertFalse(state.isPolishing, "isPolishing should be false after endPolishing()")
    }

    func testEndPolishingIsIdempotent() {
        // endPolishing() is called from a defer on every exit path, so it must be
        // safe even when polishing was never begun.
        state.endPolishing()
        XCTAssertFalse(state.isPolishing, "endPolishing() without a prior begin should be a no-op")
    }

    func testResetClearsPolishing() {
        state.startRecording()
        state.stopRecording()
        state.beginPolishing()
        XCTAssertTrue(state.isPolishing, "precondition: polishing after beginPolishing()")

        state.reset()
        XCTAssertFalse(state.isPolishing, "isPolishing should be cleared by reset()")
    }

    /// `isPolishing` is a strict sub-phase of `isProcessing` and must never
    /// perturb it: entering/leaving polishing leaves the processing flag alone.
    func testPolishingDoesNotDisturbProcessing() {
        state.startRecording()
        state.stopRecording()
        XCTAssertTrue(state.isProcessing, "precondition: processing after stopRecording()")

        state.beginPolishing()
        XCTAssertTrue(state.isProcessing, "beginPolishing() must not change isProcessing")

        state.endPolishing()
        XCTAssertTrue(state.isProcessing, "endPolishing() must not change isProcessing")

        // And it doesn't spuriously turn processing on when idle.
        state.reset()
        state.beginPolishing()
        XCTAssertFalse(state.isProcessing, "beginPolishing() must not turn on isProcessing while idle")
    }

    // MARK: - Reset Tests

    func testReset() {
        // Modify state
        state.startRecording()
        state.setTranscription("test text")

        // Reset
        state.reset()

        // Verify all properties reset to initial values
        XCTAssertTrue(state.isIdle, "isIdle should be true after reset()")
        XCTAssertFalse(state.isRecording, "isRecording should be false after reset()")
        XCTAssertFalse(state.isProcessing, "isProcessing should be false after reset()")
        XCTAssertEqual(state.currentTranscription, "", "currentTranscription should be empty after reset()")
        XCTAssertNil(state.error, "error should be nil after reset()")

        // Verify audio levels reset
        XCTAssertEqual(state.audioLevels.count, Constants.pillBarCount, "audioLevels should have Constants.pillBarCount elements after reset()")
        XCTAssertTrue(state.audioLevels.allSatisfy { $0 == 0.0 }, "All audio levels should be zero after reset()")
    }

    // MARK: - Audio Level Tests

    func testUpdateAudioLevel() {
        // Start with initial state (all zeros)
        let initialValue: Float = 0.0
        let lastIndex = Constants.pillBarCount - 1

        // Update with a new level
        state.updateAudioLevel(0.5)

        // Verify the array was shifted and new value appended
        XCTAssertEqual(state.audioLevels.count, Constants.pillBarCount, "audioLevels should still have Constants.pillBarCount elements")

        // All but the last element should be the initial value (shifted)
        for i in 0..<lastIndex {
            XCTAssertEqual(state.audioLevels[i], initialValue, "audioLevels[\(i)] should be initial value after shift")
        }

        // Last element should be the new value
        XCTAssertEqual(state.audioLevels[lastIndex], 0.5, "Last audio level should be the new value")

        // Update again and verify the pattern
        state.updateAudioLevel(0.75)
        XCTAssertEqual(state.audioLevels[lastIndex], 0.75, "Last audio level should be the updated value")
    }

    // MARK: - Transcription Tests

    func testSetTranscription() {
        // Set transcription
        state.setTranscription("test transcription")

        // Verify state
        XCTAssertEqual(state.currentTranscription, "test transcription", "currentTranscription should match the set value")
        XCTAssertFalse(state.isProcessing, "isProcessing should be false after setTranscription()")
    }

    // MARK: - Error Tests

    func testSetError() {
        // Create a test error
        let testError = NSError(domain: "TestDomain", code: 123, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        state.setError(testError)

        // Verify error state
        XCTAssertNotNil(state.error, "error should be set")
        XCTAssertEqual((state.error as NSError?)?.domain, "TestDomain", "error domain should match")
        XCTAssertEqual((state.error as NSError?)?.code, 123, "error code should match")
        XCTAssertFalse(state.isProcessing, "isProcessing should be false after setError()")
        XCTAssertFalse(state.isRecording, "isRecording should be false after setError()")
    }

    func testSetErrorWithCustomError() {
        // Create a custom error type
        enum CustomError: Error {
            case transcriptionFailed
        }

        state.setError(CustomError.transcriptionFailed)

        // Verify error state
        XCTAssertNotNil(state.error, "error should be set")
        XCTAssertFalse(state.isProcessing, "isProcessing should be false after setError()")
        XCTAssertFalse(state.isRecording, "isRecording should be false after setError()")
    }

    // MARK: - Failure message (visible dead-mic state)

    func testShowFailureSetsMessageAndStopsProcessing() {
        state.startRecording()
        state.stopRecording() // enters processing

        state.showFailure("No audio from the mic")

        XCTAssertEqual(state.failureMessage, "No audio from the mic")
        XCTAssertFalse(state.isProcessing, "the pill must stop reading as 'working' while the failure shows")
        XCTAssertFalse(state.isPolishing)
        XCTAssertNil(state.failureRecoveryText)
        XCTAssertFalse(state.failureRecoveryCopied)
    }

    func testShowFailureWithRecoveryText() {
        state.startRecording()
        state.stopRecording()

        state.showFailure("Couldn't insert — click to copy", recoveryText: "hello world")

        XCTAssertEqual(state.failureMessage, "Couldn't insert — click to copy")
        XCTAssertEqual(state.failureRecoveryText, "hello world")
        XCTAssertFalse(state.failureRecoveryCopied)
        XCTAssertEqual(state.failureRecoveryMode, .copy)
    }

    func testInsertRetrySuccessStateClears() {
        state.showFailure(
            "Couldn't insert — click to retry",
            recoveryText: "same text",
            recoveryMode: .retry
        )
        state.activateFailureRecovery()

        XCTAssertTrue(state.failureRecoveryRetryRequested)
        XCTAssertEqual(state.failureRecoveryMode, .retry)

        state.completeFailureRecoveryRetry()
        XCTAssertNil(state.failureRecoveryText)
        XCTAssertNil(state.failureRecoveryMode)
        XCTAssertFalse(state.failureRecoveryRetryRequested)
    }

    func testInsertRetryFailureTransitionsToCopyAndAllowsNoSecondRetry() {
        state.showFailure(
            "Couldn't insert — click to retry",
            recoveryText: "same text",
            recoveryMode: .retry
        )
        state.activateFailureRecovery()
        state.activateFailureRecovery()
        XCTAssertTrue(state.failureRecoveryRetryRequested)

        state.transitionRetryFailureToCopy()
        XCTAssertEqual(state.failureMessage, "Couldn't insert — click to copy")
        XCTAssertEqual(state.failureRecoveryMode, .copy)

        // The next activation copies; it can never request another retry.
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        state.activateFailureRecovery()
        XCTAssertTrue(state.failureRecoveryCopied)
        XCTAssertNil(state.failureRecoveryMode)
    }

    func testPillAccessibilityLabelReflectsState() {
        XCTAssertEqual(state.pillAccessibilityLabel, "Yappy")
        state.startRecording()
        XCTAssertEqual(state.pillAccessibilityLabel, "Recording")
        state.stopRecording()
        XCTAssertEqual(state.pillAccessibilityLabel, "Processing")
        state.beginPolishing()
        XCTAssertEqual(state.pillAccessibilityLabel, "Processing, polishing")
        state.showFailure("Couldn't insert — click to retry")
        XCTAssertEqual(state.pillAccessibilityLabel, "Couldn't insert — click to retry")
    }

    func testCopyFailureRecoveryWritesPasteboardAndMarksCopied() {
        // This test writes to the REAL general pasteboard — snapshot the
        // user's clipboard string and put it back, or every test run silently
        // replaces whatever they had copied.
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        state.showFailure("Couldn't insert — click to copy", recoveryText: "paste me")

        state.copyFailureRecovery()

        XCTAssertEqual(state.failureMessage, "Copied")
        XCTAssertNil(state.failureRecoveryText, "recovery text clears after copy so a second tap is a no-op")
        XCTAssertTrue(state.failureRecoveryCopied)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "paste me")
    }

    func testCopyFailureRecoveryNoopsWithoutRecoveryText() {
        state.showFailure("Didn't catch that")
        state.copyFailureRecovery()
        XCTAssertEqual(state.failureMessage, "Didn't catch that")
        XCTAssertFalse(state.failureRecoveryCopied)
    }

    func testResetClearsFailureMessage() {
        state.showFailure("No audio from the mic", recoveryText: "stale")
        state.reset()
        XCTAssertNil(state.failureMessage)
        XCTAssertNil(state.failureRecoveryText)
        XCTAssertFalse(state.failureRecoveryCopied)
    }

    func testStartRecordingClearsFailureMessage() {
        state.showFailure("No audio from the mic", recoveryText: "stale")
        state.startRecording()
        XCTAssertNil(state.failureMessage, "a new session must never carry the previous failure line")
        XCTAssertNil(state.failureRecoveryText, "a new session must never carry prior recovery text")
        XCTAssertFalse(state.failureRecoveryCopied)
    }

    // MARK: - Neutral info caption

    func testShowInfoSetsMessageWithoutFailureStylingFields() {
        state.startRecording()
        state.stopRecording()

        let applied = AppliedAlias(heard: "lewis", corrected: "Luis", createdTerm: false)
        state.showInfo("Learned \u{201c}Luis\u{201d} — click to undo", action: .undoLearnedAlias(applied))

        XCTAssertEqual(state.infoMessage, "Learned \u{201c}Luis\u{201d} — click to undo")
        XCTAssertEqual(state.infoAction, .undoLearnedAlias(applied))
        XCTAssertFalse(state.infoActionTriggered)
        XCTAssertNil(state.failureMessage, "info must not set failure fields")
        XCTAssertNil(state.failureRecoveryText)
        XCTAssertFalse(state.isProcessing)
    }

    func testShowInfoClearsPriorFailure() {
        state.showFailure("No audio from the mic", recoveryText: "x")
        state.showInfo("Polished — click to use your exact words", action: .useRawTranscript)
        XCTAssertNil(state.failureMessage)
        XCTAssertNil(state.failureRecoveryText)
        XCTAssertEqual(state.infoAction, .useRawTranscript)
    }

    func testTriggerInfoActionSetsFlag() {
        state.showInfo("Polished — click to use your exact words", action: .useRawTranscript)
        state.triggerInfoAction()
        XCTAssertTrue(state.infoActionTriggered)
    }

    func testTriggerInfoActionNoopsWithoutAction() {
        state.triggerInfoAction()
        XCTAssertFalse(state.infoActionTriggered)
    }

    func testResetClearsInfoCaption() {
        state.showInfo("Learned x", action: .copyRaw("x"))
        state.reset()
        XCTAssertNil(state.infoMessage)
        XCTAssertNil(state.infoAction)
        XCTAssertFalse(state.infoActionTriggered)
    }

    func testStartRecordingClearsInfoCaption() {
        state.showInfo("Learned x", action: .useRawTranscript)
        state.startRecording()
        XCTAssertNil(state.infoMessage)
        XCTAssertNil(state.infoAction)
    }

    // MARK: - Dictation failure captions

    func testDictationFailureCaptionAccessibilityDenied() {
        let caption = AppDelegate.dictationFailureCaption(
            for: TextInserter.InsertionError.accessibilityPermissionDenied
        )
        XCTAssertEqual(caption, "Enable Accessibility to insert")
        XCTAssertFalse(AppDelegate.isRecoverableInsertionFailure(
            TextInserter.InsertionError.accessibilityPermissionDenied
        ))
    }

    func testDictationFailureCaptionGenericInsert() {
        let caption = AppDelegate.dictationFailureCaption(
            for: TextInserter.InsertionError.eventCreationFailed
        )
        XCTAssertEqual(caption, "Couldn't insert — saved to History")
        XCTAssertTrue(AppDelegate.isRecoverableInsertionFailure(
            TextInserter.InsertionError.eventCreationFailed
        ))
    }

    func testDictationFailureCaptionTranscription() {
        enum FakeTranscriptionError: Error { case boom }
        let caption = AppDelegate.dictationFailureCaption(for: FakeTranscriptionError.boom)
        XCTAssertEqual(caption, "Transcription failed — try again")
        XCTAssertFalse(AppDelegate.isRecoverableInsertionFailure(FakeTranscriptionError.boom))
    }

    func testEmptyTranscriptCaptionConstant() {
        XCTAssertEqual(AppDelegate.emptyTranscriptCaption, "Didn't catch that")
        XCTAssertEqual(AppDelegate.insertFailureRetryCaption, "Couldn't insert — click to retry")
    }

    // MARK: - UpdateChecker quiet "up to date" feedback

    @MainActor
    func testUpdateCheckerDidNotFindUpdatePublishesUpToDateForManualCheck() {
        let checker = UpdateChecker()
        checker.prepareUserInitiatedCheck()
        checker.didNotFindUpdate()
        guard case .upToDate = checker.lastCheckResult else {
            return XCTFail("expected .upToDate after a user-initiated didNotFindUpdate")
        }
        XCTAssertNil(checker.available)
    }

    @MainActor
    func testUpdateCheckerBackgroundNoUpdateStaysQuiet() {
        // A scheduled/background cycle finding nothing must NOT publish the
        // "You're up to date" line — that answer belongs only to a question
        // the user asked via Check Now.
        let checker = UpdateChecker()
        checker.didNotFindUpdate()
        XCTAssertNil(checker.lastCheckResult)
    }

    @MainActor
    func testUpdateCheckerManualFlagResetsWhenCycleFinishes() {
        let checker = UpdateChecker()

        // Manual cycle: publishes, then a new Check Now clears the quiet line.
        checker.prepareUserInitiatedCheck()
        checker.didNotFindUpdate()
        checker.cycleFinished()
        checker.prepareUserInitiatedCheck()
        XCTAssertNil(checker.lastCheckResult, "a new Check Now must clear the prior quiet line")
        XCTAssertTrue(checker.isChecking)
        checker.cycleFinished()

        // The manual flag died with the cycle: a later background no-update
        // result must stay quiet.
        checker.didNotFindUpdate()
        XCTAssertNil(checker.lastCheckResult)
    }
}

// MARK: - MainWindowState

/// `MainWindowState` is the hoisted sidebar-selection object shared by
/// `MainWindowView`, the Home getting-started checklist, the Commands tab,
/// Settings' "See every phrase" link, and the menu bar's "Commands…" item.
final class MainWindowStateTests: XCTestCase {

    func testDefaultSelectionIsHome() {
        XCTAssertEqual(MainWindowState().selection, .home)
    }

    func testSelectNavigatesToTheGivenItem() {
        let state = MainWindowState()
        state.select(.commands)
        XCTAssertEqual(state.selection, .commands)
    }

    func testSelectCanNavigateRepeatedly() {
        let state = MainWindowState()
        state.select(.modes)
        XCTAssertEqual(state.selection, .modes)
        state.select(.dictionary)
        XCTAssertEqual(state.selection, .dictionary)
        state.select(.home)
        XCTAssertEqual(state.selection, .home)
    }
}
