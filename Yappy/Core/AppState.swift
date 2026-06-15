//
//  AppState.swift
//  Yappy
//

import Foundation
import Combine

/// Central state management for the Yappy application.
/// Manages recording state, audio visualization, transcription results, and errors.
final class AppState: ObservableObject {
    /// What the current capture session is for.
    enum Mode {
        case dictation
        case command
    }

    // MARK: - Published Properties

    /// What the active (or most recent) session is doing — dictation vs. an
    /// AI command applied to the current selection.
    @Published private(set) var mode: Mode = .dictation

    /// Indicates whether audio recording is currently active.
    @Published private(set) var isRecording: Bool = false

    /// Indicates whether transcription/processing is in progress.
    @Published private(set) var isProcessing: Bool = false

    /// Indicates whether the app is idle (pill hidden).
    @Published var isIdle: Bool = true

    /// Recent audio amplitude levels driving the pill waveform.
    @Published private(set) var audioLevels: [Float] = Array(repeating: 0.0, count: Constants.pillBarCount)

    /// The current transcription text result.
    @Published private(set) var currentTranscription: String = ""

    /// Current error state, if any.
    @Published private(set) var error: Error?

    // MARK: - Public Methods

    /// Starts the recording session.
    func startRecording(mode: Mode = .dictation) {
        guard !isRecording else { return }

        self.mode = mode
        isIdle = false
        isRecording = true
        error = nil
        currentTranscription = ""
        audioLevels = Array(repeating: 0.0, count: Constants.pillBarCount)
    }

    /// Stops the recording session and marks the state as processing.
    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        isProcessing = true
    }

    /// Begins a processing-only session with no recording — e.g. running a
    /// transform on selected text. The pill shows its processing state until reset.
    func beginProcessing(mode: Mode = .command) {
        self.mode = mode
        isIdle = false
        isRecording = false
        isProcessing = true
        error = nil
        currentTranscription = ""
    }

    /// Resets all state to initial values.
    func reset() {
        isIdle = true
        isRecording = false
        isProcessing = false
        mode = .dictation
        audioLevels = Array(repeating: 0.0, count: Constants.pillBarCount)
        currentTranscription = ""
        error = nil
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
    func setError(_ error: Error) {
        self.error = error
        isProcessing = false
        isRecording = false
    }
}
