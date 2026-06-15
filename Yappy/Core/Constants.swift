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

    /// A clip must clear all of these to count as speech; below them it's
    /// treated as silence and discarded, so a near-instant key tap (or a stray
    /// click) can't make the model hallucinate filler words ("Mm-hmm", "Okay").
    static let speechRMSFloor: Float = 0.005      // ≈ -46 dBFS average level
    static let speechVoiceFloor: Float = 0.02     // per-sample amplitude counted as "voiced"
    static let speechVoicedFraction: Float = 0.02 // ≥ 2% of the clip must be voiced (rejects transients)

    /// ASR results below this confidence are discarded as probable noise
    /// decodes. Clean speech typically scores well above 0.7, and the energy
    /// gate above already drops silence, so this floor only catches the
    /// in-between: breath/rustle that decoded into garbage. Erring low —
    /// silently dropping real speech is worse than rare garbage text.
    static let transcriptionConfidenceFloor: Float = 0.3

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

    // MARK: - Scratchpad

    /// Virtual key code for the Scratchpad summon hotkey (⌥⇧S). kVK_ANSI_S = 1.
    static let scratchpadKeyCode: Int64 = 1
}
