//
//  AudioLevelProcessor.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation

/// Utility for processing and smoothing audio levels for visualization.
/// Applies exponential moving average smoothing and normalization.
final class AudioLevelProcessor {
    // MARK: - Private Properties

    /// Smoothing factor for exponential moving average.
    /// Higher values (closer to 1.0) result in less smoothing.
    /// Lower values (closer to 0.0) result in more smoothing.
    private let smoothingFactor: Float = 0.3

    /// Previous level value for exponential moving average calculation.
    private var previousLevel: Float = 0.0

    // MARK: - Initialization

    init() {}

    // MARK: - Public Methods

    /// Processes a raw audio level value with smoothing and normalization.
    ///
    /// Applies exponential moving average to smooth out rapid fluctuations,
    /// then amplifies and clamps the result for optimal visualization.
    ///
    /// - Parameter rawLevel: The raw audio level from the recorder (0.0-1.0).
    /// - Returns: Processed level value (0.0-1.0) ready for visualization.
    func processLevel(_ rawLevel: Float) -> Float {
        // Apply exponential moving average smoothing
        // Formula: smoothedValue = α × newValue + (1 - α) × previousValue
        let smoothedLevel = (smoothingFactor * rawLevel) + ((1.0 - smoothingFactor) * previousLevel)

        // Store for next iteration
        previousLevel = smoothedLevel

        // Apply amplification for better visualization
        // Multiply by 2.0 to make the waveform more prominent
        let amplifiedLevel = smoothedLevel * 2.0

        // Clamp to valid range
        let processedLevel = max(0.0, min(1.0, amplifiedLevel))

        return processedLevel
    }

    /// Updates a level array with a new processed level value.
    ///
    /// Removes the oldest level (first element) and appends the new processed level,
    /// maintaining a fixed-size array for waveform visualization.
    ///
    /// - Parameters:
    ///   - levels: The level array to update (typically 40 elements).
    ///   - newLevel: The new raw level to process and add.
    func updateLevelArray(_ levels: inout [Float], newLevel: Float) {
        // Process the new level
        let processedLevel = processLevel(newLevel)

        // Shift array left (remove oldest)
        levels.removeFirst()

        // Append new processed level
        levels.append(processedLevel)
    }

    /// Resets the processor state.
    ///
    /// Call this when starting a new recording session to clear
    /// smoothing history from previous sessions.
    func reset() {
        previousLevel = 0.0
    }
}
