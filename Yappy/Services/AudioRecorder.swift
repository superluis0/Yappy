//
//  AudioRecorder.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation
import AVFoundation

/// Errors that can occur during audio recording operations.
enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case microphoneUnavailable
    case audioEngineStartFailed(Error)
    case fileCreationFailed(Error)
    case noRecordingAvailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access denied. Please enable microphone permissions in System Preferences."
        case .microphoneUnavailable:
            return "No microphone input device available."
        case .audioEngineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .fileCreationFailed(let error):
            return "Failed to create audio file: \(error.localizedDescription)"
        case .noRecordingAvailable:
            return "No recording available to retrieve."
        }
    }
}

/// AVFoundation-based audio recorder with real-time level monitoring.
/// Captures audio in WAV format optimized for Whisper API transcription.
final class AudioRecorder {
    // MARK: - Private Properties

    /// Audio engine for capturing input audio.
    private var audioEngine: AVAudioEngine?

    /// Audio file for writing recorded samples.
    private var audioFile: AVAudioFile?

    /// URL of the current recording file.
    private var recordingURL: URL?

    /// Callback for real-time audio level updates.
    private var levelCallback: ((Float) -> Void)?

    /// Audio format for recording (16kHz mono PCM).
    private let recordingFormat: AVAudioFormat = {
        // Whisper-optimized format: 16kHz, mono, linear PCM
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Failed to create audio format")
        }
        return format
    }()

    // MARK: - Initialization

    init() {}

    deinit {
        // Ensure resources are cleaned up
        cleanup()
    }

    // MARK: - Public Methods

    /// Starts audio recording with real-time level monitoring.
    ///
    /// - Parameter levelCallback: Closure called with RMS level (0.0-1.0) approximately 60 times per second.
    /// - Throws: `AudioRecorderError` if microphone is unavailable, permission denied, or engine fails to start.
    func startRecording(levelCallback: @escaping (Float) -> Void) throws {
        // Request microphone permission
        try checkMicrophonePermission()

        // Store the callback
        self.levelCallback = levelCallback

        // Create temporary file URL for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "yappy_recording_\(UUID().uuidString).wav"
        recordingURL = tempDir.appendingPathComponent(fileName)

        guard let recordingURL = recordingURL else {
            throw AudioRecorderError.fileCreationFailed(
                NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create recording URL"])
            )
        }

        // Initialize audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode

        // Verify input is available
        guard inputNode.inputFormat(forBus: 0).channelCount > 0 else {
            throw AudioRecorderError.microphoneUnavailable
        }

        // Get the input format (device's native format)
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // Create audio file for writing
        do {
            audioFile = try AVAudioFile(
                forWriting: recordingURL,
                settings: recordingFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioRecorderError.fileCreationFailed(error)
        }

        // Install tap on input node to capture audio buffers
        // Buffer size of 4096 frames gives ~60 callbacks/sec at 16kHz
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            // Convert buffer to our recording format and write to file
            self.processAudioBuffer(buffer, inputFormat: inputFormat)

            // Calculate and report RMS level
            let rmsLevel = self.calculateRMSLevel(from: buffer)
            DispatchQueue.main.async {
                self.levelCallback?(rmsLevel)
            }
        }

        // Configure audio session for recording
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioRecorderError.audioEngineStartFailed(error)
        }

        // Start the audio engine
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioRecorderError.audioEngineStartFailed(error)
        }
    }

    /// Stops the current recording and returns the file URL.
    ///
    /// - Returns: URL of the recorded WAV file.
    func stopRecording() -> URL? {
        guard let engine = audioEngine, let url = recordingURL else {
            return nil
        }

        // Remove tap from input node
        engine.inputNode.removeTap(onBus: 0)

        // Stop and reset engine
        engine.stop()

        // Close audio file
        audioFile = nil

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false)

        // Clear engine reference
        audioEngine = nil
        levelCallback = nil

        return url
    }

    /// Retrieves the recorded audio data for API upload.
    ///
    /// - Returns: Audio data in WAV format.
    /// - Throws: `AudioRecorderError.noRecordingAvailable` if no recording exists.
    func getAudioData() throws -> Data {
        guard let url = recordingURL else {
            throw AudioRecorderError.noRecordingAvailable
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw AudioRecorderError.fileCreationFailed(error)
        }
    }

    // MARK: - Private Methods

    /// Checks and requests microphone permission.
    ///
    /// - Throws: `AudioRecorderError.microphonePermissionDenied` if permission is not granted.
    private func checkMicrophonePermission() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return

        case .notDetermined:
            // Request permission synchronously using a semaphore
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)

            AVCaptureDevice.requestAccess(for: .audio) { result in
                granted = result
                semaphore.signal()
            }

            semaphore.wait()

            if !granted {
                throw AudioRecorderError.microphonePermissionDenied
            }

        case .denied, .restricted:
            throw AudioRecorderError.microphonePermissionDenied

        @unknown default:
            throw AudioRecorderError.microphonePermissionDenied
        }
    }

    /// Converts audio buffer to recording format and writes to file.
    ///
    /// - Parameters:
    ///   - buffer: Input audio buffer from microphone.
    ///   - inputFormat: Format of the input buffer.
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let audioFile = audioFile else { return }

        // Convert to recording format if necessary
        if inputFormat.sampleRate != recordingFormat.sampleRate ||
           inputFormat.channelCount != recordingFormat.channelCount {

            // Create converter
            guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
                return
            }

            // Calculate output buffer capacity
            let capacity = AVAudioFrameCount(
                Double(buffer.frameLength) * recordingFormat.sampleRate / inputFormat.sampleRate
            )

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: recordingFormat,
                frameCapacity: capacity
            ) else {
                return
            }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

            if error == nil {
                try? audioFile.write(from: convertedBuffer)
            }
        } else {
            // Direct write if formats match
            try? audioFile.write(from: buffer)
        }
    }

    /// Calculates root mean square (RMS) level from audio buffer.
    ///
    /// - Parameter buffer: Audio buffer to analyze.
    /// - Returns: RMS level normalized to 0.0-1.0 range.
    private func calculateRMSLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0.0
        }

        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)

        // Calculate sum of squares
        var sum: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelDataValue[i]
            sum += sample * sample
        }

        // Calculate RMS
        let rms = sqrt(sum / Float(frameLength))

        // Normalize to 0.0-1.0 range
        // Typical speech RMS is around 0.1-0.3, so we scale accordingly
        let normalizedRMS = min(rms * 5.0, 1.0)

        return normalizedRMS
    }

    /// Cleans up audio resources.
    private func cleanup() {
        if let engine = audioEngine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        audioFile = nil
        audioEngine = nil
        levelCallback = nil

        // Clean up temporary file if it exists
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
}
