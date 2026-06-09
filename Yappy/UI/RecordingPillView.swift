//
//  RecordingPillView.swift
//  Yappy
//

import SwiftUI

/// The floating pill shown at the bottom of the screen while
/// recording (live waveform) and processing (breathing dots).
struct RecordingPillView: View {
    @ObservedObject var appState: AppState

    @State private var visible = false
    @State private var breathe = false

    /// Command Mode tints the pill so it's distinct from plain dictation.
    private var accent: Color {
        appState.mode == .command
            ? Color(red: 0.45, green: 0.55, blue: 1.0)
            : .white
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.black.opacity(0.88))
                .overlay(
                    Capsule()
                        .strokeBorder(accent.opacity(appState.mode == .command ? 0.45 : 0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)

            HStack(spacing: 8) {
                if appState.mode == .command {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }

                if appState.isRecording {
                    waveform
                        .transition(.opacity)
                } else if appState.isProcessing {
                    processingDots
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(width: Constants.pillWidth, height: Constants.pillHeight)
        .scaleEffect(visible ? 1.0 : 0.8)
        .opacity(visible ? 1.0 : 0.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: visible)
        .animation(.easeInOut(duration: 0.15), value: appState.isRecording)
        // Fill the (larger) panel with a clear, non-interactive container so the
        // capsule is centered and its shadow fades into transparent margin
        // rather than being clipped at the panel's rectangular edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { visible = true }
    }

    // MARK: - Recording Waveform

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(0..<Constants.pillBarCount, id: \.self) { index in
                Capsule()
                    .fill(accent)
                    .frame(width: 3, height: barHeight(at: index))
                    .animation(.spring(response: 0.25, dampingFraction: 0.7),
                               value: appState.audioLevels)
            }
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        let levels = appState.audioLevels
        guard index < levels.count else { return 3 }

        // Symmetric falloff from the center so the pill reads like a voice meter.
        let center = CGFloat(Constants.pillBarCount - 1) / 2
        let distance = abs(CGFloat(index) - center) / center
        let shape = 1.0 - distance * 0.55

        let level = CGFloat(levels[index])
        let maxHeight: CGFloat = 22
        return max(3, level * maxHeight * shape)
    }

    // MARK: - Processing Indicator

    private var processingDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 5, height: 5)
                    .scaleEffect(breathe ? 1.0 : 0.55)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: breathe
                    )
            }
        }
        .onAppear { breathe = true }
        .onDisappear { breathe = false }
    }
}
