//
//  Constants.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation
import CoreGraphics

/// Application-wide constants for API endpoints, UI dimensions, and behavior thresholds.
enum Constants {
    // MARK: - API Endpoints

    /// OpenAI Whisper API endpoint for audio transcription.
    static let whisperAPIEndpoint = "https://api.openai.com/v1/audio/transcriptions"

    /// OpenRouter API endpoint for chat completions.
    static let grokAPIEndpoint = "https://openrouter.ai/api/v1/chat/completions"

    /// Grok model identifier for OpenRouter API requests.
    static let grokModel = "x-ai/grok-4.1-fast"

    // MARK: - Waveform Visualization

    /// Number of bars in the audio waveform visualization.
    static let waveformBarCount = 20

    /// Width of the waveform window in points.
    static let waveformWindowWidth: CGFloat = 180.0

    /// Height of the waveform window in points.
    static let waveformWindowHeight: CGFloat = 48.0

    // MARK: - Hotkey Behavior

    /// Maximum time interval (in seconds) between two key presses to register as a double tap.
    static let doubleTapThreshold: TimeInterval = 0.3
}
