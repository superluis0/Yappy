//
//  AppState.swift
//  Yappy
//

import Foundation
import Combine
import AppKit

/// Central state management for the Yappy application.
/// Manages recording state, audio visualization, transcription results, and errors.
final class AppState: ObservableObject {
    enum FailureRecoveryMode: Equatable {
        case retry
        case copy
    }

    // MARK: - Published Properties

    /// Indicates whether audio recording is currently active.
    @Published private(set) var isRecording: Bool = false

    /// Indicates whether transcription/processing is in progress.
    @Published private(set) var isProcessing: Bool = false

    /// A finer sub-phase of `isProcessing`: the AI cleanup ("polishing") pass is
    /// running. `isProcessing` stays true for the whole transcribe+cleanup window;
    /// this narrows the pill to the moment the on-device model is reshaping the
    /// words, so the wait reads as deliberate work rather than a generic spinner.
    /// Always a strict subset of `isProcessing` (never set while idle/recording).
    @Published private(set) var isPolishing: Bool = false

    /// A dictation was requested while the speech model was still loading (e.g.
    /// just after launch). Recording starts automatically once the model is ready;
    /// until then the pill shows a "preparing" indicator.
    @Published private(set) var isPreparing: Bool = false

    /// Indicates whether the app is idle (pill hidden).
    @Published var isIdle: Bool = true

    /// Recent audio amplitude levels driving the pill waveform.
    @Published private(set) var audioLevels: [Float] = Array(repeating: 0.0, count: Constants.pillBarCount)

    /// The current transcription text result.
    @Published private(set) var currentTranscription: String = ""

    /// Current error state, if any.
    @Published private(set) var error: Error?

    /// Transient user-facing failure line rendered inside the pill (e.g. "No
    /// audio from the mic" when the input device delivered pure digital
    /// silence). Set alongside the failure sound so a dead mic never LOOKS
    /// like Yappy simply ignoring the user; cleared by `reset()` and whenever
    /// a new session begins.
    @Published private(set) var failureMessage: String?

    /// When set, the pill failure is recoverable: click copies this exact string
    /// (the text that failed to insert) to the clipboard. Nil for informational
    /// failures (dead mic, empty transcript, accessibility prompt).
    @Published private(set) var failureRecoveryText: String?

    /// True after the user clicked the pill to copy `failureRecoveryText`.
    /// AppDelegate watches this to end the recovery hold early.
    @Published private(set) var failureRecoveryCopied: Bool = false

    /// The pill's current one-click recovery action. Retry is consumed at most
    /// once; a failed retry transitions to copy mode.
    @Published private(set) var failureRecoveryMode: FailureRecoveryMode?
    @Published private(set) var failureRecoveryRetryRequested: Bool = false

    /// Neutral (non-failure) pill caption — e.g. "Learned … — click to undo" or
    /// "Polished — click to use your exact words". Never uses failure styling.
    @Published private(set) var infoMessage: String?

    /// What a click on the info caption should do. AppDelegate handles the
    /// action when `infoActionTriggered` flips true.
    @Published private(set) var infoAction: InfoCaptionAction?

    /// True after the user clicked the info caption. AppDelegate watches this
    /// to perform the action and end the hold early.
    @Published private(set) var infoActionTriggered: Bool = false

    /// Timestamp of the most recent real *voice* dictation that landed (text
    /// transcribed and inserted via the hotkey path). Set by `AppDelegate` on
    /// each successful insertion; nil until the user has dictated at least once.
    /// Onboarding observes this to confirm the try-it text came from speech, not
    /// the keyboard.
    @Published var lastDictationAt: Date?

    // MARK: - Public Methods

    /// Starts the recording session.
    func startRecording() {
        guard !isRecording else { return }

        isIdle = false
        isPreparing = false
        isRecording = true
        error = nil
        failureMessage = nil
        failureRecoveryText = nil
        failureRecoveryCopied = false
        failureRecoveryMode = nil
        failureRecoveryRetryRequested = false
        clearInfoCaption()
        currentTranscription = ""
        audioLevels = Array(repeating: 0.0, count: Constants.pillBarCount)
        Self.announceForAccessibility("Recording")
    }

    /// Marks a dictation as queued while the speech model finishes loading. The
    /// pill shows a preparing indicator until `startRecording` (triggered
    /// automatically when the model is ready) or `reset` (cancelled).
    func beginPreparing() {
        isIdle = false
        isPreparing = true
        isRecording = false
        isProcessing = false
        error = nil
        currentTranscription = ""
    }

    /// Stops the recording session and marks the state as processing.
    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        isProcessing = true
        Self.announceForAccessibility("Processing")
    }

    /// Enters the "polishing" sub-phase (AI cleanup is running). Only meaningful
    /// while already processing; the pill uses it to show a distinct look.
    func beginPolishing() {
        isPolishing = true
    }

    /// Leaves the "polishing" sub-phase. Safe to call even if it wasn't set, so
    /// callers can `defer` it on every exit path.
    func endPolishing() {
        isPolishing = false
    }

    /// Resets all state to initial values.
    func reset() {
        isIdle = true
        isRecording = false
        isProcessing = false
        isPolishing = false
        isPreparing = false
        audioLevels = Array(repeating: 0.0, count: Constants.pillBarCount)
        currentTranscription = ""
        error = nil
        failureMessage = nil
        failureRecoveryText = nil
        failureRecoveryCopied = false
        failureRecoveryMode = nil
        failureRecoveryRetryRequested = false
        clearInfoCaption()
    }

    /// Appends a new audio level sample, dropping the oldest.
    func updateAudioLevel(_ level: Float) {
        var newLevels = audioLevels
        newLevels.removeFirst()
        newLevels.append(level)
        audioLevels = newLevels
    }

    /// Updates the transcription result when transcription is complete.
    func setTranscription(_ transcription: String) {
        currentTranscription = transcription
        isProcessing = false
    }

    /// Shows a short failure line in the pill (with `isProcessing` cleared so
    /// the pill stops reading as "working"). The caller keeps the pill visible
    /// briefly and then calls `reset()`.
    /// - Parameter recoveryText: when non-nil, the pill is clickable to copy
    ///   this text (the string that failed to insert).
    func showFailure(_ message: String, recoveryText: String? = nil,
                     recoveryMode: FailureRecoveryMode = .copy) {
        isProcessing = false
        isPolishing = false
        clearInfoCaption()
        failureMessage = message
        failureRecoveryText = recoveryText
        failureRecoveryCopied = false
        failureRecoveryMode = recoveryText == nil ? nil : recoveryMode
        failureRecoveryRetryRequested = false
        Self.announceForAccessibility(message)
    }

    /// Activates the pill's current recovery affordance. Retry is represented as
    /// a request for AppDelegate (which owns insertion); copy remains local.
    func activateFailureRecovery() {
        guard failureRecoveryText != nil else { return }
        switch failureRecoveryMode {
        case .retry where !failureRecoveryRetryRequested:
            failureRecoveryRetryRequested = true
        case .copy:
            copyFailureRecovery()
        case .retry, .none:
            break
        }
    }

    /// A failed retry gets one safe fallback: copy the preserved text. Keeping
    /// this as an explicit transition makes the one-retry rule testable.
    func transitionRetryFailureToCopy() {
        guard failureRecoveryRetryRequested, failureRecoveryText != nil else { return }
        failureMessage = "Couldn't insert — click to copy"
        failureRecoveryMode = .copy
        // The retry→copy handoff must be audible too, like every failure state.
        Self.announceForAccessibility(failureMessage ?? "")
    }

    /// Completes the retry-success transition and clears the recovery pill.
    func completeFailureRecoveryRetry() {
        guard failureRecoveryRetryRequested else { return }
        reset()
    }

    /// Copies `failureRecoveryText` to the general pasteboard and swaps the
    /// caption to "Copied". No-op when there is nothing to recover.
    func copyFailureRecovery() {
        guard let text = failureRecoveryText else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        failureMessage = "Copied"
        failureRecoveryText = nil
        failureRecoveryCopied = true
        failureRecoveryMode = nil
    }

    /// Runs when the info caption is clicked. Executed AT CLICK TIME (not
    /// after the display hold) so a click can never be discarded because a
    /// new session cleared the caption state mid-hold. One-shot.
    private var infoActionHandler: (() -> Void)?

    /// Neutral info caption (not failure-styled). Clears any failure state so
    /// the pill never mixes the two modes. Click runs `handler` immediately
    /// and flips `infoActionTriggered` (which the display hold observes).
    func showInfo(
        _ message: String,
        action: InfoCaptionAction,
        handler: (() -> Void)? = nil
    ) {
        isProcessing = false
        isPolishing = false
        failureMessage = nil
        failureRecoveryText = nil
        failureRecoveryCopied = false
        infoMessage = message
        infoAction = action
        infoActionTriggered = false
        infoActionHandler = handler
        Self.announceForAccessibility(message)
    }

    /// Click entry point: performs the caption's action NOW and marks it
    /// triggered so the display hold can end early.
    func triggerInfoAction() {
        guard infoAction != nil else { return }
        infoActionTriggered = true
        let handler = infoActionHandler
        infoActionHandler = nil
        handler?()
    }

    /// Clears neutral info caption state.
    func clearInfoCaption() {
        infoMessage = nil
        infoAction = nil
        infoActionTriggered = false
        infoActionHandler = nil
    }

    func setError(_ error: Error) {
        self.error = error
        isProcessing = false
        isRecording = false
    }

    /// Terse label for the pill's single accessibility element.
    var pillAccessibilityLabel: String {
        if let failureMessage { return failureMessage }
        if isRecording { return "Recording" }
        if isPolishing { return "Processing, polishing" }
        if isProcessing { return "Processing" }
        if isPreparing { return "Preparing" }
        return "Yappy"
    }

    /// Posts a VoiceOver announcement so pill failures are audible, not only visual.
    private static func announceForAccessibility(_ message: String) {
        guard NSApp != nil else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

/// Click action for a neutral pill info caption. Handled by AppDelegate when
/// the user taps the pill during the hold window.
enum InfoCaptionAction: Equatable {
    /// Undo an auto-learned dictionary alias (exact reverse of what was added).
    case undoLearnedAlias(AppliedAlias)
    /// Revert the last insertion to the pre-cleanup raw transcript.
    case useRawTranscript
    /// Fallback: copy the raw pre-cleanup text to the pasteboard when revert
    /// can't run (e.g. caret focus assumptions fail).
    case copyRaw(String)
}
