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
    @ObservedObject var updateChecker: UpdateChecker

    @State private var lmStudioModels: [String] = []
    @State private var lmStudioReachable: Bool?
    @State private var microphoneGranted = AudioRecorder.hasPermission
    @State private var accessibilityGranted = AXIsProcessTrusted()

    /// LM Studio server config only matters when LM Studio can actually run a
    /// request — i.e. the user picked it, or picked Automatic (which falls back to it).
    private var usesLMStudio: Bool {
        settings.cleanupBackend == .lmStudio || settings.cleanupBackend == .automatic
    }

    /// One-line explanation of the selected cleanup engine.
    private var cleanupBackendHint: String {
        switch settings.cleanupBackend {
        case .automatic:
            return "Uses Apple Intelligence when available, otherwise your LM Studio server."
        case .appleIntelligence:
            return "On-device Apple Intelligence — requires macOS 26+ with Apple Intelligence enabled."
        case .lmStudio:
            return "A model you run locally in LM Studio."
        }
    }

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

                Toggle("Format spoken numbered lists", isOn: $settings.numberedListsEnabled)
                Text("Counting off items \u{2014} \u{201c}one milk two eggs three bread\u{201d} \u{2014} becomes a 1./2./3. list. Works best with spoken numbers on.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Remove filler words", isOn: $settings.fillerRemovalEnabled)
                Text("Strips standalone \u{201c}um\u{201d}, \u{201c}uh\u{201d}, \u{201c}erm\u{201d}, and \u{201c}hmm\u{201d} from transcripts.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Spoken formatting commands", isOn: $settings.spokenCommandsEnabled)
                Text("Say \u{201c}new line\u{201d} or \u{201c}new paragraph\u{201d} to insert line breaks.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Spoken punctuation", isOn: $settings.spokenPunctuationEnabled)
                Text("Say \u{201c}comma\u{201d}, \u{201c}period\u{201d}, or \u{201c}question mark\u{201d} to insert punctuation. Turn off if you dictate those words literally.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Voice editing commands", isOn: $settings.voiceEditingEnabled)
                Text("Say \u{201c}scratch that\u{201d}, \u{201c}delete the last word\u{201d}, or \u{201c}all caps that\u{201d} to fix what you just dictated.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Voice commands", isOn: $settings.voiceControlEnabled)
                Text("Say \u{201c}switch to <mode> mode\u{201d}, \u{201c}open scratchpad\u{201d}, or \u{201c}new note\u{201d} to control Yappy hands-free.")
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
                LabeledContent("Current version", value: updateChecker.currentVersionDisplay)
                Toggle("Check for updates automatically", isOn: $settings.autoUpdateChecksEnabled)
                HStack {
                    Button {
                        updateChecker.checkForUpdates()
                    } label: {
                        if updateChecker.isChecking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking\u{2026}")
                            }
                        } else {
                            Text("Check Now")
                        }
                    }
                    .disabled(updateChecker.isChecking)

                    Spacer()

                    if let release = updateChecker.available {
                        Label("Version \(release.version) ready", systemImage: "arrow.down.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text("Updates are downloaded from GitHub and verified with a cryptographic signature before installing. Nothing about you is sent \u{2014} only a version check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Clean up transcripts with a local AI model", isOn: $settings.cleanupEnabled)

                if settings.cleanupEnabled {
                    Picker("Engine", selection: $settings.cleanupBackend) {
                        Text(CleanupBackend.automatic.displayName).tag(CleanupBackend.automatic)
                        Text(CleanupBackend.appleIntelligence.displayName).tag(CleanupBackend.appleIntelligence)
                        Text(CleanupBackend.lmStudio.displayName).tag(CleanupBackend.lmStudio)
                    }
                    .listRowBackground(Color.accentColor.opacity(0.04))

                    Text(cleanupBackendHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.accentColor.opacity(0.04))

                    if usesLMStudio {
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
                    }

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

                    Toggle("Resolve spoken self-corrections", isOn: $settings.backtrackEnabled)
                        .listRowBackground(Color.accentColor.opacity(0.04))
                    Text("\u{201c}Let\u{2019}s meet at 2, actually 3\u{201d} becomes \u{201c}Let\u{2019}s meet at 3.\u{201d}")
                        .font(.caption).foregroundStyle(.secondary)
                        .listRowBackground(Color.accentColor.opacity(0.04))
                }
            } header: {
                Text("AI Cleanup")
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
        .task(id: "\(settings.cleanupEnabled)-\(settings.cleanupBackend.rawValue)") {
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
