//
//  WaveformView.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import SwiftUI

/// Visual representation of audio recording with animated waveform bars.
/// Displays real-time audio levels as a series of vertical bars.
struct WaveformView: View {
    // MARK: - Properties
    
    @ObservedObject var appState: AppState
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Constants.waveformBarCount, id: \.self) { index in
                WaveformBar(level: appState.audioLevels[index])
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
}

// MARK: - Waveform Bar

/// Individual bar in the waveform visualization.
struct WaveformBar: View {
    let level: Float
    
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: [.blue, .cyan],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(width: 4, height: barHeight)
            .animation(.easeInOut(duration: 0.1), value: level)
    }
    
    /// Calculates the height of the bar based on audio level.
    private var barHeight: CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 40
        let normalizedLevel = CGFloat(max(0, min(1, level)))
        return minHeight + (maxHeight - minHeight) * normalizedLevel
    }
}

// MARK: - Preview

#Preview {
    WaveformView(appState: {
        let state = AppState()
        state.startRecording()
        // Simulate some audio levels
        for _ in 0..<40 {
            state.updateAudioLevel(Float.random(in: 0...1))
        }
        return state
    }())
    .frame(width: 320, height: 80)
}
