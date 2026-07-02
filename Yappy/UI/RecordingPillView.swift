//
//  RecordingPillView.swift
//  Yappy
//

import SwiftUI

/// The floating "molten glass" pill shown at the bottom of the screen while
/// recording (glowing waveform) and processing (breathing dots). Built from
/// layered fills rather than materials: in a transparent borderless panel,
/// SwiftUI materials can't blur the wallpaper and render flat.
struct RecordingPillView: View {
    @ObservedObject var appState: AppState

    @State private var visible = false
    @State private var breathe = false

    private var accent: Color { .accentColor }

    /// Gradient for the waveform bars: bright molten tips fading into the accent.
    private var barStyle: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(
            colors: [Color(red: 1.0, green: 0.75, blue: 0.55), Color.accentColor],
            startPoint: .top, endPoint: .bottom
        ))
    }

    /// Mean recent level, drives the ambient bloom's brightness.
    private var averageLevel: CGFloat {
        let levels = appState.audioLevels
        guard !levels.isEmpty else { return 0 }
        return CGFloat(levels.reduce(0, +)) / CGFloat(levels.count)
    }

    var body: some View {
        ZStack {
            glassCapsule

            // Ambient bloom behind the content: fixed blur, only opacity
            // animates (GPU-cheap), breathing with the voice level.
            if appState.isRecording {
                Capsule()
                    .fill(accent)
                    .frame(width: 120, height: 16)
                    .blur(radius: 12)
                    .opacity(0.15 + 0.5 * averageLevel)
                    .animation(.easeOut(duration: 0.12), value: averageLevel)
            }

            HStack(spacing: 8) {
                if appState.isRecording {
                    WaveformBarsView(
                        levels: appState.audioLevels,
                        style: barStyle,
                        glow: accent.opacity(0.7)
                    )
                    .transition(.opacity)
                } else if appState.isProcessing || appState.isPreparing {
                    processingIndicator
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(width: Constants.pillWidth, height: Constants.pillHeight)
        .scaleEffect(visible ? 1.0 : 0.8)
        .opacity(visible ? 1.0 : 0.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: visible)
        .animation(.easeInOut(duration: 0.15), value: appState.isRecording)
        // Cross-fade the neutral dots into the accent-tinted "Polishing" look when
        // AI cleanup starts, so the sub-phase reads without any layout jump.
        .animation(.easeInOut(duration: 0.2), value: appState.isPolishing)
        // Fill the (larger) panel with a clear, non-interactive container so the
        // capsule is centered and its shadow fades into transparent margin
        // rather than being clipped at the panel's rectangular edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { visible = true }
    }

    // MARK: - Glass Body

    private var glassCapsule: some View {
        Capsule()
            .fill(LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.12, blue: 0.12),
                    Color(red: 0.07, green: 0.06, blue: 0.06),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(
                // Warm interior tint, like light caught inside the glass.
                Capsule().fill(accent.opacity(0.06))
            )
            .overlay(
                // Glass rim: bright top edge fading out, warm at the base.
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.35),
                            .white.opacity(0.05),
                            accent.opacity(0.25),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    // MARK: - Processing Indicator

    /// The breathing dots shown while transcribing/preparing, plus a quiet
    /// "Polishing" caption once the AI-cleanup sub-phase begins. Keeping one
    /// container (dots always present, caption fades in) means the polishing
    /// state reads as a subtle shift, not a swap that shoves the layout around.
    private var processingIndicator: some View {
        HStack(spacing: 7) {
            processingDots
            if appState.isPolishing {
                Text("Polishing")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(accent.opacity(0.9))
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
    }

    /// Three breathing dots. During the polishing sub-phase they warm to the
    /// accent tint (from the neutral molten cream used while transcribing), so the
    /// same motion signals "now reshaping your words" without changing the beat.
    private var processingDots: some View {
        let dotColor = appState.isPolishing
            ? accent
            : Color(red: 1.0, green: 0.8, blue: 0.62)
        return HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(dotColor)
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
