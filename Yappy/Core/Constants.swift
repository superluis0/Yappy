//
//  Constants.swift
//  Yappy
//

import Foundation
import CoreGraphics

/// Application-wide constants for UI dimensions and behavior thresholds.
enum Constants {
    // MARK: - Recording Pill

    /// Number of bars in the pill waveform visualization.
    static let pillBarCount = 14

    /// Width of the visible pill capsule in points.
    static let pillWidth: CGFloat = 200.0

    /// Height of the visible pill capsule in points.
    static let pillHeight: CGFloat = 44.0

    /// Transparent margin around the capsule inside the panel, so the drop
    /// shadow fades out instead of being clipped into a hard rectangle.
    static let pillShadowMargin: CGFloat = 28.0

    /// Distance from the bottom edge of the screen's visible frame to the pill.
    static let pillBottomMargin: CGFloat = 24.0

    // MARK: - Recording Behavior

    /// Recordings shorter than this are treated as accidental taps and discarded.
    static let minRecordingDuration: TimeInterval = 0.2

    /// Safety cap on a single recording.
    static let maxRecordingDuration: TimeInterval = 300.0

    // MARK: - Hotkey Behavior

    /// Maximum duration of a key press for it to count as a "tap" (double-tap mode).
    static let tapMaxDuration: TimeInterval = 0.3

    /// Maximum interval between two taps to register as a double tap.
    static let doubleTapWindow: TimeInterval = 0.4

    /// Key-down events arriving within this interval of the previous key-up are ignored.
    static let hotkeyDebounceInterval: TimeInterval = 0.1

    // MARK: - LM Studio

    /// Default base URL for LM Studio's local OpenAI-compatible server.
    static let defaultLMStudioBaseURL = "http://localhost:1234/v1"

    /// Timeout for LM Studio cleanup requests; on expiry the raw transcript is inserted.
    static let lmStudioTimeout: TimeInterval = 8.0

    // MARK: - History

    /// Maximum number of dictation history entries kept on disk.
    static let historyLimit = 1000
}
