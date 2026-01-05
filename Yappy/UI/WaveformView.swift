//
//  WaveformView.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import SwiftUI

/// SwiftUI view that displays an animated audio waveform visualization.
/// Shows 40 vertical bars that respond to audio levels in real-time.
struct WaveformView: View {
    // MARK: - Properties

    /// The application state containing audio level data.
    @ObservedObject var appState: AppState

    // MARK: - Constants

    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let cornerRadius: CGFloat = 12
    private let barCornerRadius: CGFloat = 2
    private let minBarHeight: CGFloat = 4
    private let maxBarHeight: CGFloat = 50

    // MARK: - Body

    var body: some View {
        ZStack {
            // Translucent blurred background
            VisualEffectBackground(
                material: .hudWindow,
                blendingMode: .behindWindow
            )

            // Waveform bars
            HStack(spacing: barSpacing) {
                ForEach(0..<Constants.waveformBarCount, id: \.self) { index in
                    WaveformBar(
                        level: appState.audioLevels[index],
                        isProcessing: appState.isProcessing,
                        minHeight: minBarHeight,
                        maxHeight: maxBarHeight,
                        cornerRadius: barCornerRadius
                    )
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(
            width: Constants.waveformWindowWidth,
            height: Constants.waveformWindowHeight
        )
        .cornerRadius(cornerRadius)
    }
}

// MARK: - Waveform Bar

/// Individual bar in the waveform visualization.
/// Animates its height based on the audio level.
private struct WaveformBar: View {
    // MARK: - Properties

    let level: Float
    let isProcessing: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let cornerRadius: CGFloat

    // MARK: - Body

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.9))
            .frame(width: 4, height: barHeight)
            .animation(.easeInOut(duration: 0.1), value: level)
            .animation(.easeInOut(duration: 0.3), value: isProcessing)
    }

    // MARK: - Computed Properties

    /// Calculates the bar height based on audio level and processing state.
    private var barHeight: CGFloat {
        if isProcessing {
            // When processing, animate bars to collapse/pulse
            return minHeight + (maxBarHeight - minHeight) * 0.2
        } else {
            // During recording, map level (0.0-1.0) to bar height range
            let normalizedLevel = CGFloat(max(0.0, min(1.0, level)))
            return minHeight + (maxBarHeight - minHeight) * normalizedLevel
        }
    }
}

// MARK: - Preview

#Preview {
    WaveformView(appState: AppState())
        .frame(width: 320, height: 60)
}
