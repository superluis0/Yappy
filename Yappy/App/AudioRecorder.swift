//
//  AudioRecorder.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import AVFoundation
import Foundation

/// Handles audio recording using AVAudioEngine.
/// Captures microphone input and saves to a temporary audio file.
final class AudioRecorder {
    // MARK: - Properties
    
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var isRecording = false
    
    /// Callback for audio level updates
    var onAudioLevelUpdate: ((Float) -> Void)?
    
    // MARK: - Public Methods
    
    /// Starts recording audio from the default microphone.
    /// - Returns: True if recording started successfully, false otherwise.
    func startRecording() -> Bool {
        // Prevent multiple simultaneous recordings
        guard !isRecording else {
            print("⚠️ Already recording")
            return false
        }
        
        // Make sure engine is stopped before reconfiguring
        if audioEngine.isRunning {
            print("⚠️ Stopping previous audio engine session")
            audioEngine.stop()
        }
        
        // Reset the engine to clear any previous configuration
        audioEngine.reset()
        
        // Check microphone permission (synchronously)
        let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        NSLog("🔐 Microphone permission status: \(permissionStatus.rawValue)")
        
        switch permissionStatus {
        case .authorized:
            NSLog("✅ Microphone permission granted")
        case .notDetermined:
            NSLog("⚠️ Microphone permission not determined - requesting...")
            // Note: This is async, so first recording attempt may fail
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog(granted ? "✅ Microphone permission granted" : "❌ Microphone permission denied")
            }
            return false
        case .denied, .restricted:
            NSLog("❌ Microphone permission denied or restricted")
            NSLog("❌ Please enable microphone access in System Settings > Privacy & Security > Microphone")
            return false
        @unknown default:
            NSLog("⚠️ Unknown microphone permission status")
            return false
        }
        
        // Create a temporary file URL for the recording (use WAV for fast recording)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "yappy_recording_\(Date().timeIntervalSince1970).wav"
        recordingURL = tempDir.appendingPathComponent(fileName)
        
        guard let url = recordingURL else {
            print("❌ Failed to create recording URL")
            return false
        }
        
        // Get the input node
        let inputNode = audioEngine.inputNode
        
        // IMPORTANT: Remove any existing tap before installing a new one
        inputNode.removeTap(onBus: 0)
        
        // Check if input is available
        guard inputNode.inputFormat(forBus: 0).channelCount > 0 else {
            print("❌ No input channels available - microphone may not be accessible")
            return false
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        print("📊 Recording format: \(recordingFormat)")
        print("📊 Sample rate: \(recordingFormat.sampleRate) Hz")
        print("📊 Channels: \(recordingFormat.channelCount)")
        
        // Verify we have a valid format
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            print("❌ Invalid recording format")
            return false
        }
        
        // Use PCM format for fast recording, we'll convert to M4A later
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: recordingFormat.sampleRate,
            channels: recordingFormat.channelCount,
            interleaved: false
        ) else {
            print("❌ Failed to create recording format")
            return false
        }
        
        print("💾 Output format: \(format)")
        
        // Create the audio file
        do {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: format.settings
            )
        } catch {
            print("❌ Failed to create audio file: \(error)")
            return false
        }
        
        // Install tap on the input node with smaller buffer for lower latency
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }
            
            do {
                // Write directly to file (no conversion for now)
                try audioFile.write(from: buffer)
                
                // Calculate audio level for visualization
                let level = self.calculateAudioLevel(from: buffer)
                
                // Call the callback on the main thread
                DispatchQueue.main.async {
                    self.onAudioLevelUpdate?(level)
                }
            } catch {
                print("❌ Failed to write audio buffer: \(error)")
            }
        }
        
        // Start the audio engine
        do {
            try audioEngine.start()
            isRecording = true
            print("🎤 Audio engine started")
            return true
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            isRecording = false
            return false
        }
    }
    
    /// Stops recording and returns the URL of the recorded audio file.
    /// - Returns: URL of the recorded audio file, or nil if recording failed.
    func stopRecording() -> URL? {
        guard isRecording else {
            print("⚠️ Not currently recording")
            return recordingURL
        }
        
        // Mark as not recording first to prevent race conditions
        isRecording = false
        
        guard audioEngine.isRunning else {
            print("⚠️ Audio engine is not running")
            return recordingURL
        }
        
        // Close the audio file first (before stopping engine)
        audioFile = nil
        
        // Stop the engine (this will implicitly stop all taps)
        audioEngine.stop()
        
        // Reset the engine to clear configuration
        audioEngine.reset()
        
        print("🛑 Audio engine stopped")
        
        return recordingURL
    }
    
    /// Cleans up temporary recording files.
    func cleanup() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
    
    // MARK: - Private Methods
    
    /// Calculates the average audio level from a buffer.
    /// - Parameter buffer: The audio buffer to analyze.
    /// - Returns: A normalized audio level between 0.0 and 1.0.
    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(
            from: 0,
            to: Int(buffer.frameLength),
            by: buffer.stride
        ).map { channelDataValue[$0] }
        
        // Calculate RMS (root mean square)
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(channelDataValueArray.count))
        
        // Convert to decibels and normalize
        let avgPower = 20 * log10(rms)
        let minDb: Float = -80.0
        let maxDb: Float = 0.0
        
        // Normalize to 0.0 - 1.0 range
        let normalized = (avgPower - minDb) / (maxDb - minDb)
        return max(0.0, min(1.0, normalized))
    }
}
