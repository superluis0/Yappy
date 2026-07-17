//
//  RecordingPillView.swift
//  Yappy
//

import SwiftUI

/// The floating "molten glass" pill shown at the bottom of the screen while
/// recording (glowing waveform) and processing (breathing dots). Built from
/// layered fills rather than materials: in a transparent borderless panel,
/// SwiftUI materials can't blur the wallpaper and render flat.
/// The glowing rim shown around a pill while it listens — shared by the
/// dictation pill (capsule) and the Ask pill (rounded rectangle). The rainbow
/// style is animated with `hueRotation` rather than rotating the gradient: on
/// a red→…→red spectrum, cycling every point's hue is visually identical to
/// the colors traveling around the ring, but the flow speed stays uniform
/// along the perimeter (a rotated conic gradient sprints across a pill's long
/// edges and lingers at the round ends) and it costs one Core Animation
/// color-matrix pass — no per-frame SwiftUI redraws. White and orange are
/// static: hue-cycling white is a no-op, and hue-cycling orange would turn it
/// back into a rainbow. The blur is fixed (GPU-cheap) and bleeds outward, so
/// the host panel must be larger than the shape (both pill panels keep a
/// 28–40pt shadow margin). Under Reduce Motion the rainbow holds static: a
/// 360° hue rotation is the identity.
struct ListeningGlowRing<S: InsettableShape>: View {
    let shape: S
    let style: ListeningGlowStyle

    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tempered full-wheel spectrum, wrapped so the ends meet seamlessly
    /// around the shape. Desaturated a notch so it sits inside the molten-
    /// glass look instead of reading as neon.
    private var rainbowGradient: AngularGradient {
        let hues: [Double] = [0, 1.0 / 6, 2.0 / 6, 3.0 / 6, 4.0 / 6, 5.0 / 6, 1]
        return AngularGradient(
            gradient: Gradient(colors: hues.map {
                Color(hue: $0, saturation: 0.7, brightness: 0.95)
            }),
            center: .center
        )
    }

    /// Stroke for the selected glow style. White and orange are solid rims;
    /// only rainbow carries the animated spectrum.
    private var glowStroke: AnyShapeStyle {
        switch style {
        case .rainbow: AnyShapeStyle(rainbowGradient)
        case .white: AnyShapeStyle(Color.white.opacity(0.85))
        case .orange: AnyShapeStyle(Color(red: 1.0, green: 0.58, blue: 0.2))
        }
    }

    var body: some View {
        let animateHue = style == .rainbow && !reduceMotion
        ZStack {
            // Soft halo outside the rim.
            shape
                .stroke(glowStroke, lineWidth: 3)
                .blur(radius: 9)
                .opacity(0.55)
            // Sharp rim on the shape's edge.
            shape
                .strokeBorder(glowStroke, lineWidth: 2)
        }
        .hueRotation(.degrees(animateHue && phase ? 360 : 0))
        .animation(
            animateHue
                ? .linear(duration: 8).repeatForever(autoreverses: false)
                : nil,
            value: phase
        )
        .onAppear { phase = true }
        .onDisappear { phase = false }
    }
}

struct RecordingPillView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: Settings

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

            // Glowing rim while listening (rainbow colors slowly circle;
            // white/orange hold steady). Style comes from Settings.
            if appState.isRecording {
                listeningGlow
                    .transition(.opacity)
            }

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
                } else if let failure = appState.failureMessage {
                    // Visible failure state: a dead input device (pure digital
                    // silence) must not read as Yappy ignoring the user.
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(failure)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.35))
                    .transition(.opacity)
                } else if let info = appState.infoMessage {
                    // Neutral info caption (learned alias, polished diff) —
                    // deliberately NOT failure-styled (no warning triangle / orange).
                    Text(info)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transition(.opacity)
                } else if appState.isProcessing || appState.isPreparing {
                    processingIndicator
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(width: Constants.pillWidth, height: Constants.pillHeight)
        // Insert recovery / neutral info action: the tap target is the ENTIRE
        // visible capsule (the caption says "click" — clicking anywhere on the
        // pill must work, not just the text). The panel only receives mouse
        // events during those hold windows; the guards keep every other state
        // inert, so this gesture can live at capsule scope safely.
        .contentShape(Capsule())
        .onTapGesture {
            if appState.failureRecoveryText != nil {
                appState.activateFailureRecovery()
            } else if appState.infoAction != nil {
                appState.triggerInfoAction()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appState.pillAccessibilityLabel)
        .accessibilityAddTraits(
            appState.failureRecoveryText == nil && appState.infoAction == nil ? [] : .isButton
        )
        .scaleEffect(visible ? 1.0 : 0.8)
        .opacity(visible ? 1.0 : 0.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: visible)
        .animation(.easeInOut(duration: 0.15), value: appState.isRecording)
        // Cross-fade the neutral dots into the accent-tinted "Polishing" look when
        // AI cleanup starts, so the sub-phase reads without any layout jump.
        .animation(.easeInOut(duration: 0.2), value: appState.isPolishing)
        .animation(.easeInOut(duration: 0.2), value: appState.failureMessage)
        .animation(.easeInOut(duration: 0.2), value: appState.infoMessage)
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

    // MARK: - Listening Glow

    private var listeningGlow: some View {
        ListeningGlowRing(shape: Capsule(), style: settings.listeningGlowStyle)
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
