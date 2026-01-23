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
    private let cornerRadius: CGFloat = 8
    private let barCornerRadius: CGFloat = 1.5
    private let minBarHeight: CGFloat = 2
    private let maxBarHeight: CGFloat = 32
    
    // Branded Orange: #FF6B35
    private let yappyOrange = Color(red: 1.0, green: 0.42, blue: 0.21)

    // MARK: - Body

    var body: some View {
        Group {
            if appState.isIdle {
                // Persistent Idle State: Thin black line
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.black)
                    .frame(width: 120, height: 4) // Thicker for visibility
                    .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
            } else {
                // Active Pulse State: Orange bars on dark background
                ZStack {
                    // Sleek black background
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.black.opacity(0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .stroke(yappyOrange.opacity(0.2), lineWidth: 0.5)
                        )

                    // Waveform bars
                    HStack(spacing: barSpacing) {
                        ForEach(0..<40, id: \.self) { index in
                            WaveformBar(
                                level: appState.audioLevels[index],
                                isProcessing: appState.isProcessing,
                                minHeight: minBarHeight,
                                maxHeight: maxBarHeight,
                                cornerRadius: barCornerRadius,
                                color: yappyOrange
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(width: 200, height: 44)
                .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 5)
                .shadow(color: yappyOrange.opacity(0.1), radius: 15, x: 0, y: 0)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                ))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.92), value: appState.isIdle)
    }
}

// MARK: - Waveform Bar

private struct WaveformBar: View {
    let level: Float
    let isProcessing: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let cornerRadius: CGFloat
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [color, color.opacity(0.7)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3, height: barHeight)
            .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.72, blendDuration: 0.02), value: level)
    }

    private var barHeight: CGFloat {
        if isProcessing {
            return minHeight + 4 // Subtle pulse during processing
        } else {
            let normalizedLevel = CGFloat(max(0.0, min(1.0, level)))
            return minHeight + (maxHeight - minHeight) * normalizedLevel
        }
    }
}

// MARK: - Preview

#Preview {
    let idleState = AppState()
    let activeState = AppState()
    activeState.startRecording()
    
    return VStack(spacing: 40) {
        WaveformView(appState: idleState) // Idle
        WaveformView(appState: activeState) // Active
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
