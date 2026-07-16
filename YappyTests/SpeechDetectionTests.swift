//
//  SpeechDetectionTests.swift
//  YappyTests
//

import AVFoundation
import XCTest
@testable import Yappy

final class SpeechDetectionTests: XCTestCase {

    private func sine(amplitude: Float, seconds: Double, freq: Float = 180) -> [Float] {
        let count = Int(16000 * seconds)
        return (0..<count).map { amplitude * sin(2 * .pi * freq * Float($0) / 16000) }
    }

    /// A long, otherwise-silent clip with a short voiced burst embedded in it —
    /// models the push-to-talk pattern of holding the key while thinking, then
    /// giving a brief spoken answer.
    private func silentHoldWithBurst(
        totalSeconds: Double,
        burstAmplitude: Float,
        burstSeconds: Double
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(16000 * totalSeconds))
        let burst = sine(amplitude: burstAmplitude, seconds: burstSeconds)
        let start = min(samples.count / 2, samples.count - burst.count)
        for (offset, value) in burst.enumerated() where start + offset < samples.count {
            samples[start + offset] = value
        }
        return samples
    }

    func testPureSilenceIsRejected() {
        XCTAssertFalse(AudioRecorder.containsSpeech([Float](repeating: 0, count: 16000)))
    }

    func testRoomToneIsRejected() {
        // Very low-level steady tone (≈ -54 dBFS) — below the speech floor.
        XCTAssertFalse(AudioRecorder.containsSpeech(sine(amplitude: 0.002, seconds: 0.6)))
    }

    func testTooShortIsRejected() {
        XCTAssertFalse(AudioRecorder.containsSpeech(sine(amplitude: 0.2, seconds: 0.05)))
    }

    func testIsolatedClickInSilenceIsRejected() {
        // One loud transient surrounded by silence: high peak but tiny overall RMS.
        var samples = [Float](repeating: 0, count: 16000)
        for i in 4000..<4060 { samples[i] = 0.6 }
        XCTAssertFalse(AudioRecorder.containsSpeech(samples))
    }

    func testNormalSpeechIsAccepted() {
        XCTAssertTrue(AudioRecorder.containsSpeech(sine(amplitude: 0.15, seconds: 0.5)))
    }

    // MARK: - Long hold, short answer (F06 — absolute voiced floor)

    /// A short real answer after a long silent hold must pass. Under the old
    /// voiced-*fraction* rule the burst was diluted by the 20 s hold and the clip
    /// was wrongly dropped as silence; the absolute floor accepts it.
    func testShortBurstAfterLongHoldIsAccepted() {
        let samples = silentHoldWithBurst(totalSeconds: 20, burstAmplitude: 0.2, burstSeconds: 0.4)
        XCTAssertTrue(AudioRecorder.containsSpeech(samples))
    }

    /// A long clip that is near-silent throughout (only room tone, no real
    /// voiced content) must still be rejected regardless of its length.
    func testLongNearSilentClipIsRejected() {
        XCTAssertFalse(AudioRecorder.containsSpeech(sine(amplitude: 0.002, seconds: 20)))
    }

    /// A single brief loud click inside a long clip must still fail: its voiced
    /// span is far below the absolute floor even though its peak is loud.
    func testBriefClickInLongClipIsRejected() {
        var samples = [Float](repeating: 0, count: Int(16000 * 20))
        for i in 40_000..<40_060 { samples[i] = 0.6 }
        XCTAssertFalse(AudioRecorder.containsSpeech(samples))
    }

    // MARK: - Confidence floor

    func testConfidenceFloorBoundary() {
        XCTAssertFalse(ParakeetTranscriptionService.acceptsTranscript(confidence: 0.29))
        XCTAssertTrue(ParakeetTranscriptionService.acceptsTranscript(confidence: 0.30))
        XCTAssertTrue(ParakeetTranscriptionService.acceptsTranscript(confidence: 0.95))
    }

    // MARK: - Digital silence (dead input device, 2026-07-16 login-boot regression)

    /// Exact zeros of any meaningful length = the device delivered no audio at
    /// all. Distinct from a quiet room: real mics always carry self-noise.
    func testAllZeroClipIsDigitalSilence() {
        XCTAssertTrue(AudioRecorder.isDigitalSilence([Float](repeating: 0, count: 16000)))
    }

    /// Room tone — tiny but nonzero — is NOT digital silence; it must keep
    /// today's silent-discard path, never the loud device-failure path.
    func testRoomToneIsNotDigitalSilence() {
        XCTAssertFalse(AudioRecorder.isDigitalSilence(sine(amplitude: 0.002, seconds: 0.6)))
        // Even a single nonzero sample disqualifies the clip.
        var samples = [Float](repeating: 0, count: 16000)
        samples[9000] = 0.0001
        XCTAssertFalse(AudioRecorder.isDigitalSilence(samples))
    }

    /// "Nothing recorded" is a different condition from "recorded nothing".
    func testEmptyClipIsNotDigitalSilence() {
        XCTAssertFalse(AudioRecorder.isDigitalSilence([]))
    }

    // MARK: - Zero-buffer detection (the self-heal's audio-thread arm)

    private func buffer(channels: AVAudioChannelCount, frames: AVAudioFrameCount,
                        fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = fill(ch, i) }
        }
        return buffer
    }

    func testZeroBufferIsDetected() {
        XCTAssertTrue(AudioRecorder.bufferIsEntirelyZero(
            buffer(channels: 2, frames: 2048) { _, _ in 0 }
        ))
    }

    /// Audio on ANY channel disarms the detector — a stereo device delivering
    /// on only one channel is alive (the converter downmixes it), so rebuilding
    /// the engine then would cut into real speech.
    func testAudioOnSecondChannelOnlyIsNotZero() {
        XCTAssertFalse(AudioRecorder.bufferIsEntirelyZero(
            buffer(channels: 2, frames: 2048) { ch, i in ch == 1 && i == 1500 ? 0.01 : 0 }
        ))
    }

    func testEmptyBufferCountsAsZero() {
        XCTAssertTrue(AudioRecorder.bufferIsEntirelyZero(
            buffer(channels: 1, frames: 0) { _, _ in 0.5 }
        ))
    }
}
