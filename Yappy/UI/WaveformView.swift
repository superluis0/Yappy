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

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 16
    private let barCornerRadius: CGFloat = 1.5
    private let minBarHeight: CGFloat = 3
    private let maxBarHeight: CGFloat = 36

    // MARK: - Body

    var body: some View {
        ZStack {
            // Dark translucent background with subtle orange glow
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.black.opacity(0.85), location: 0.0),
                            .init(color: Color(red: 0.08, green: 0.06, blue: 0.04).opacity(0.9), location: 0.5),
                            .init(color: Color.black.opacity(0.85), location: 1.0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.orange.opacity(0.3),
                                    Color.orange.opacity(0.1),
                                    Color.orange.opacity(0.3)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1
                        )
                )

            // Waveform bars with orange gradient
            HStack(spacing: barSpacing) {
                ForEach(0..<Constants.waveformBarCount, id: \.self) { index in
                    WaveformBar(
                        level: appState.audioLevels[index],
                        isProcessing: appState.isProcessing,
                        minHeight: minBarHeight,
                        maxHeight: maxBarHeight,
                        cornerRadius: barCornerRadius,
                        barIndex: index,
                        totalBars: Constants.waveformBarCount
                    )
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(
            width: Constants.waveformWindowWidth,
            height: Constants.waveformWindowHeight
        )
        .shadow(color: Color.orange.opacity(0.15), radius: 12, x: 0, y: 4)
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
    let barIndex: Int
    let totalBars: Int

    // MARK: - Gradient Colors

    /// Creates a dynamic orange gradient based on bar position for visual depth
    private var barGradient: LinearGradient {
        let progress = CGFloat(barIndex) / CGFloat(totalBars - 1)
        
        // Center bars are brighter, edge bars slightly dimmer for depth
        let centerDistance = abs(progress - 0.5) * 2.0
        let brightness = 1.0 - (centerDistance * 0.2)
        
        return LinearGradient(
            gradient: Gradient(colors: [
                Color(red: 1.0 * brightness, green: 0.6 * brightness, blue: 0.1 * brightness), // Vibrant orange
                Color(red: 1.0 * brightness, green: 0.4 * brightness, blue: 0.0)  // Deep orange
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Body

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(barGradient)
            .frame(width: 3, height: barHeight)
            .shadow(color: Color.orange.opacity(0.4), radius: 2, x: 0, y: 0)
            .animation(.easeInOut(duration: 0.08), value: level)
            .animation(.easeInOut(duration: 0.25), value: isProcessing)
    }

    // MARK: - Computed Properties

    /// Calculates the bar height based on audio level and processing state.
    private var barHeight: CGFloat {
        if isProcessing {
            // When processing, animate bars to a subtle pulse
            return minHeight + (maxHeight - minHeight) * 0.15
        } else {
            // During recording, map level (0.0-1.0) to bar height range
            let normalizedLevel = CGFloat(max(0.0, min(1.0, level)))
            return minHeight + (maxHeight - minHeight) * normalizedLevel
        }
    }
}

// MARK: - Preview

#Preview {
    WaveformView(appState: AppState())
        .frame(width: 180, height: 48)
        .background(Color.black)
}
