//
//  AppState.swift
//  Yappy
//
//  Created on 2026-01-04.
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
    
    /// Indicates whether the app is in idle mode (showing persistent line).
    @Published var isIdle: Bool = true

    /// Array of audio level values for waveform visualization.
    /// Contains 40 float values representing recent audio amplitude levels.
    @Published private(set) var audioLevels: [Float] = Array(repeating: 0.0, count: 40)

    /// The current transcription text result.
    @Published private(set) var currentTranscription: String = ""

    /// Current error state, if any.
    @Published private(set) var error: Error?

    // MARK: - Initialization

    init() {
        // Initialize with default values
    }

    // MARK: - Public Methods

    /// Starts the recording session.
    /// Updates the recording state and resets any previous errors.
    func startRecording() {
        guard !isRecording else { return }

        isIdle = false
        isRecording = true
        error = nil
        currentTranscription = ""
        audioLevels = Array(repeating: 0.0, count: 40)
    }

    /// Stops the recording session.
    /// Marks the state as processing to indicate transcription is beginning.
    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        isProcessing = true
    }

    /// Resets all state to initial values.
    /// Clears recording status, transcription, errors, and audio levels.
    func reset() {
        isIdle = true
        isRecording = false
        isProcessing = false
        audioLevels = Array(repeating: 0.0, count: 40)
        currentTranscription = ""
        error = nil
    }

    /// Updates the audio level visualization with a new sample.
    /// The array is shifted left (removing the oldest value) and the new level is appended.
    ///
    /// - Parameter level: The new audio level value to add to the visualization.
    func updateAudioLevel(_ level: Float) {
        // Create a new array to trigger SwiftUI update
        var newLevels = audioLevels
        newLevels.removeFirst()
        newLevels.append(level)
        audioLevels = newLevels
    }

    // MARK: - Internal State Updates

    /// Updates the transcription result.
    /// Called when transcription is complete.
    ///
    /// - Parameter transcription: The transcribed text.
    func setTranscription(_ transcription: String) {
        currentTranscription = transcription
        isProcessing = false
    }

    /// Sets an error state.
    ///
    /// - Parameter error: The error that occurred.
    func setError(_ error: Error) {
        self.error = error
        isProcessing = false
        isRecording = false
    }
}
