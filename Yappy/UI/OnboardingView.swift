//
//  OnboardingView.swift
//  Yappy
//

import SwiftUI
import ApplicationServices

/// Guided first-run flow: welcome → microphone → accessibility → hotkey → done.
/// Folds in the model status so first launch is one coherent experience.
struct OnboardingView: View {
    @ObservedObject var transcriptionService: ParakeetTranscriptionService
    let requestMicrophone: () async -> Bool
    let onFinish: () -> Void

    @State private var step = 0
    @State private var micGranted = AudioRecorder.hasPermission
    @State private var axGranted = AXIsProcessTrusted()

    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            content
        }
        .padding(40)
        .frame(width: 460, height: 420)
        .onReceive(permissionPoll) { _ in
            micGranted = AudioRecorder.hasPermission
            axGranted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: microphone
        case 2: accessibility
        default: ready
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Welcome to Yappy")
                .font(.largeTitle.bold())
            Text("Hold a hotkey, speak, and your words appear wherever your cursor is — transcribed entirely on this Mac. Let's grant two quick permissions.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { step = 1 }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    private var microphone: some View {
        permissionStep(
            icon: "mic.fill",
            title: "Microphone access",
            detail: "Yappy needs your microphone to hear what you say. Audio never leaves your Mac.",
            granted: micGranted,
            actionTitle: "Allow Microphone"
        ) {
            Task {
                _ = await requestMicrophone()
                micGranted = AudioRecorder.hasPermission
            }
        }
    }

    private var accessibility: some View {
        permissionStep(
            icon: "accessibility",
            title: "Accessibility access",
            detail: "This lets Yappy detect your hotkey and paste text into other apps. Enable Yappy in System Settings → Privacy & Security → Accessibility.",
            granted: axGranted,
            actionTitle: "Open System Settings"
        ) {
            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }
    }

    private var ready: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.largeTitle.bold())
            Text("Hold **Right ⌘** anywhere and start talking. Release to insert your text. You can change the hotkey and more in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            modelStatus

            Spacer()
            Button("Start Using Yappy", action: onFinish)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
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

    // MARK: - Reusable Permission Step

    @ViewBuilder
    private func permissionStep(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
            Text(title).font(.title.bold())
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .controlSize(.large)
            }

            Spacer()
            Button(granted ? "Continue" : "Skip for now") { step += 1 }
                .keyboardShortcut(granted ? .defaultAction : .init(.escape))
        }
    }
}
