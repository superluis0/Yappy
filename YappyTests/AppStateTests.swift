//
//  AppStateTests.swift
//  YappyTests
//
//  Created on 2026-01-27.
//

import XCTest
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
}
