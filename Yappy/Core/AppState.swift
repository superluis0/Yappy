//
//  AppState.swift
//  Yappy
//

import Foundation
import Combine

/// Central state management for the Yappy application.
/// Manages recording state, audio visualization, transcription results, and errors.
final class AppState: ObservableObject {
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
        currentTranscription = ""
        audioLevels = Array(repeating: 0.0, count: Constants.pillBarCount)
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

    /// Sets an error state.
    /// Shows a short failure line in the pill (with `isProcessing` cleared so
    /// the pill stops reading as "working"). The caller keeps the pill visible
    /// briefly and then calls `reset()`.
    func showFailure(_ message: String) {
        isProcessing = false
        isPolishing = false
        failureMessage = message
    }

    func setError(_ error: Error) {
        self.error = error
        isProcessing = false
        isRecording = false
    }
}
