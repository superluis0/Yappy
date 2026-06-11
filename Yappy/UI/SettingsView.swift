//
//  SettingsView.swift
//  Yappy
//

import SwiftUI
import ServiceManagement

/// Settings panel shown inside the main window's sidebar. Fully local — no API keys.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var transcriptionService: ParakeetTranscriptionService
    let lmStudio: LMStudioService

    @State private var lmStudioModels: [String] = []
    @State private var lmStudioReachable: Bool?
    @State private var microphoneGranted = AudioRecorder.hasPermission
    @State private var accessibilityGranted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hotkey", selection: $settings.hotkeyOption) {
                    ForEach(HotkeyOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Toggle("Play sounds when recording starts and stops", isOn: $settings.audioFeedbackEnabled)

                if settings.audioFeedbackEnabled {
                    HStack {
                        Text("Sound volume")
                        Slider(value: $settings.audioFeedbackVolume, in: 0...1)
                            .frame(width: 160)
                    }
                }

                Toggle("Write spoken numbers as digits", isOn: $settings.numberFormattingEnabled)
                Text("Turns \u{201c}eleven point six\u{201d} into \u{201c}11.6\u{201d}, \u{201c}twenty dollars\u{201d} into \u{201c}$20\u{201d}, and \u{201c}three thirty PM\u{201d} into \u{201c}3:30 PM.\u{201d}")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Remove filler words", isOn: $settings.fillerRemovalEnabled)
                Text("Strips standalone \u{201c}um\u{201d}, \u{201c}uh\u{201d}, \u{201c}erm\u{201d}, and \u{201c}hmm\u{201d} from transcripts.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Spoken formatting commands", isOn: $settings.spokenCommandsEnabled)
                Text("Say \u{201c}new line\u{201d} or \u{201c}new paragraph\u{201d} to insert line breaks.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Voice editing commands", isOn: $settings.voiceEditingEnabled)
                Text("Say \u{201c}scratch that\u{201d}, \u{201c}delete the last word\u{201d}, or \u{201c}all caps that\u{201d} to fix what you just dictated.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable Command Mode", isOn: $settings.commandModeEnabled)
                if settings.commandModeEnabled {
                    Picker("Command hotkey", selection: $settings.commandHotkeyOption) {
                        ForEach(HotkeyOption.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    if settings.hotkeysCollide {
                        Label("Command hotkey must differ from the dictation hotkey.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Command Mode")
            } footer: {
                Text("Select text in any app, hold the command hotkey, and speak an instruction (\u{201c}make this concise\u{201d}, \u{201c}translate to Spanish\u{201d}). Requires LM Studio running.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch Yappy at login", isOn: $settings.launchAtLogin)
                ModelStatusRow(transcriptionService: transcriptionService)
            }

            Section {
                Toggle("Clean up transcripts with a local AI model", isOn: $settings.cleanupEnabled)

                if settings.cleanupEnabled {
                    LabeledContent("Status") {
                        switch lmStudioReachable {
                        case .some(true):
                            Label("Connected", systemImage: "circle.fill")
                                .foregroundStyle(.green)
                        case .some(false):
                            Label("Not running", systemImage: "circle.fill")
                                .foregroundStyle(.orange)
                        case .none:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(
                        Group {
                            switch lmStudioReachable {
                            case .some(true): Color.green.opacity(0.07)
                            case .some(false): Color.orange.opacity(0.09)
                            case .none: Color.clear
                            }
                        }
                    )

                    Picker("Model", selection: modelBinding) {
                        Text("First available").tag("")
                        ForEach(lmStudioModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .listRowBackground(Color.accentColor.opacity(0.04))

                    TextField("Server URL", text: $settings.lmStudioBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .listRowBackground(Color.accentColor.opacity(0.04))

                    Toggle("Adapt tone to the app I'm typing in", isOn: $settings.contextAwareToneEnabled)
                        .listRowBackground(Color.accentColor.opacity(0.04))

                    if settings.contextAwareToneEnabled {
                        ForEach(AppCategory.allCases, id: \.self) { category in
                            Picker(category.displayName, selection: toneBinding(for: category)) {
                                Text("Auto (\(category.defaultTone.displayName))").tag(Optional<ToneStyle>.none)
                                ForEach(ToneStyle.allCases, id: \.self) { tone in
                                    Text(tone.displayName).tag(Optional(tone))
                                }
                            }
                            .listRowBackground(Color.accentColor.opacity(0.04))
                        }
                    }
                }
            } header: {
                Text("AI Cleanup (LM Studio)")
            } footer: {
                Text("Requires LM Studio running locally with its server enabled. If it isn't available, the raw transcript is inserted — dictation never breaks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Microphone",
                    granted: microphoneGranted,
                    pane: "Privacy_Microphone"
                )
                permissionRow(
                    title: "Accessibility",
                    granted: accessibilityGranted,
                    pane: "Privacy_Accessibility"
                )
            }
        }
        .formStyle(.grouped)
        .task(id: settings.cleanupEnabled) {
            await refreshLMStudio()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            microphoneGranted = AudioRecorder.hasPermission
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    // MARK: - Helpers

    private func toneBinding(for category: AppCategory) -> Binding<ToneStyle?> {
        Binding(
            get: { settings.toneOverrides[category] },
            set: { newValue in
                if let newValue {
                    settings.toneOverrides[category] = newValue
                } else {
                    settings.toneOverrides.removeValue(forKey: category)
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.lmStudioModelID ?? "" },
            set: { settings.lmStudioModelID = $0.isEmpty ? nil : $0 }
        )
    }

    private func refreshLMStudio() async {
        guard settings.cleanupEnabled else { return }
        lmStudioReachable = nil
        let reachable = await lmStudio.isReachable()
        lmStudioReachable = reachable
        lmStudioModels = reachable ? await lmStudio.availableModels() : []
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
            }
            Spacer()
            if !granted {
                Button("Open System Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
                    if let url = URL(string: url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
