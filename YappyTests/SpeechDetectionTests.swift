//
//  SpeechDetectionTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class SpeechDetectionTests: XCTestCase {

    private func sine(amplitude: Float, seconds: Double, freq: Float = 180) -> [Float] {
        let count = Int(16000 * seconds)
        return (0..<count).map { amplitude * sin(2 * .pi * freq * Float($0) / 16000) }
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
}
