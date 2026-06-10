//
//  OnboardingView.swift
//  Yappy
//

import SwiftUI
import ApplicationServices

/// Rolling audio levels for the onboarding mic preview, fed by AppDelegate.
@MainActor
final class OnboardingLevelModel: ObservableObject {
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: Constants.pillBarCount)

    func push(_ level: Float) {
        var updated = levels
        updated.removeFirst()
        updated.append(level)
        levels = updated
    }

    func reset() {
        levels = Array(repeating: 0, count: Constants.pillBarCount)
    }
}

/// Guided first-run flow: welcome → microphone (live waveform) →
/// accessibility → model status → try it. Each step springs in from the
/// trailing edge; the mic step shows Yappy actually hearing you, and the
/// final step lets you dictate into a practice field before finishing.
struct OnboardingView: View {
    @ObservedObject var transcriptionService: ParakeetTranscriptionService
    @ObservedObject var levelModel: OnboardingLevelModel
    let requestMicrophone: () async -> Bool
    let startLevelPreview: () -> Bool
    let stopLevelPreview: () -> Void
    let onFinish: () -> Void

    @State private var step = 0
    @State private var micGranted = AudioRecorder.hasPermission
    @State private var axGranted = AXIsProcessTrusted()
    @State private var previewActive = false
    @State private var tryItText = ""
    @State private var tryItSucceeded = false

    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
        }
        .padding(40)
        .frame(width: 460, height: 500)
        .onReceive(permissionPoll) { _ in
            micGranted = AudioRecorder.hasPermission
            axGranted = AXIsProcessTrusted()
            syncPreview()
        }
        .onChange(of: step) {
            syncPreview()
        }
        .onDisappear {
            if previewActive {
                stopLevelPreview()
                previewActive = false
            }
        }
    }

    /// The live mic waveform runs only on the microphone step once granted.
    private func syncPreview() {
        let shouldPreview = (step == 1 && micGranted)
        if shouldPreview, !previewActive {
            previewActive = startLevelPreview()
        } else if !shouldPreview, previewActive {
            stopLevelPreview()
            previewActive = false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: microphone
        case 2: accessibility
        case 3: model
        default: tryIt
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("Welcome to Yappy")
                .font(.largeTitle.bold())
            Text("Hold a hotkey, speak, and your words appear wherever your cursor is — transcribed entirely on this Mac. Let's get set up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { step = 1 }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    private var microphone: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 52))
                .foregroundStyle(micGranted ? Color.green : Color.accentColor)
            Text("Microphone access")
                .font(.title.bold())
            Text("Yappy needs your microphone to hear what you say. Audio never leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if micGranted {
                // Live proof that Yappy hears you.
                VStack(spacing: 8) {
                    WaveformBarsView(
                        levels: levelModel.levels,
                        maxHeight: 26,
                        style: AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.75, blue: 0.55), Color.accentColor],
                            startPoint: .top, endPoint: .bottom
                        )),
                        glow: Color.accentColor.opacity(0.7)
                    )
                    .frame(height: 32)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    Text("Say something — Yappy is listening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Allow Microphone") {
                    Task {
                        _ = await requestMicrophone()
                        micGranted = AudioRecorder.hasPermission
                        syncPreview()
                    }
                }
                .controlSize(.large)
            }

            Spacer()
            Button(micGranted ? "Continue" : "Skip for now") { step = 2 }
                .keyboardShortcut(micGranted ? .defaultAction : .init(.escape))
        }
    }

    private var accessibility: some View {
        VStack(spacing: 16) {
            Image(systemName: "accessibility")
                .font(.system(size: 52))
                .foregroundStyle(axGranted ? Color.green : Color.accentColor)
            Text("Accessibility access")
                .font(.title.bold())
            Text("This lets Yappy detect your hotkey and paste text into other apps. Enable Yappy in System Settings → Privacy & Security → Accessibility.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if axGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open System Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
                .controlSize(.large)
            }

            Spacer()
            Button(axGranted ? "Continue" : "Skip for now") { step = 3 }
                .keyboardShortcut(axGranted ? .defaultAction : .init(.escape))
        }
    }

    private var model: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Your speech model")
                .font(.title.bold())
            Text("Yappy transcribes with a neural model running on this Mac's Neural Engine — nothing is sent to a server.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            modelStatus

            Spacer()
            Button("Continue") { step = 4 }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    private var tryIt: some View {
        VStack(spacing: 14) {
            if tryItSucceeded {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                Text("That's it — you're dictating")
                    .font(.title.bold())
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("Try it right here")
                    .font(.title.bold())
            }

            Text(transcriptionService.modelState == .ready
                 ? "Click into the box, hold **Right ⌘**, and say: “Yappy makes dictation feel like magic.”"
                 : "The speech model is still getting ready — you can finish setup and try dictating in a minute.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            TextEditor(text: $tryItText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 88)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tryItSucceeded ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .onChange(of: tryItText) {
                    let hasText = !tryItText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hasText, !tryItSucceeded {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            tryItSucceeded = true
                        }
                    }
                }

            Spacer()
            Button(tryItSucceeded ? "Finish" : "Skip and finish", action: onFinish)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: tryItSucceeded)
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch transcriptionService.modelState {
        case .ready:
            Label("Speech model ready", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 240)
                Text("Downloading speech model (443 MB, one time)…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .loading, .notLoaded:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing speech model…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange)
        }
    }
}
