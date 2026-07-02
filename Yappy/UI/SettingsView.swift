//
//  SettingsView.swift
//  Yappy
//

import SwiftUI
import ServiceManagement

/// Settings panel shown inside the main window's sidebar. Fully local — no API keys.
/// Bespoke "liquid glass" layout: each setting is an icon + title + inline description
/// + control, grouped into glass cards with breathing room (see `SettingsSection`).
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var transcriptionService: ParakeetTranscriptionService
    @ObservedObject var updateChecker: UpdateChecker
    /// Optional history store, used only for the "Clear history now" button. When
    /// nil (e.g. a call site that hasn't wired it yet) the button is hidden.
    var historyStore: HistoryStore? = nil
    /// Re-shows the "What's New" card; wired by MainWindowView to the presenter.
    var onShowReleaseNotes: () -> Void = {}

    @State private var microphoneGranted = AudioRecorder.hasPermission
    @State private var accessibilityGranted = AXIsProcessTrusted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                dictationSection
                aiCleanupSection
                generalSection
                privacySection
                softwareUpdateSection
                permissionsSection
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 46)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            microphoneGranted = AudioRecorder.hasPermission
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings").font(.system(size: 24, weight: .bold)).foregroundStyle(Brand.ink)
            Text("Tune how Yappy listens, formats, and writes — all on device.")
                .font(.system(size: 13.5)).foregroundStyle(Brand.ink3)
        }
    }

    // MARK: - Sections

    private var dictationSection: some View {
        SettingsSection(icon: "mic.fill", title: "Dictation") {
            SettingRow(icon: "keyboard", title: "Activation hotkey",
                       subtitle: "Hold to record, release to insert.") {
                Picker("", selection: $settings.hotkeyOption) {
                    ForEach(HotkeyOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            RowDivider()
            SettingToggle(icon: "speaker.wave.2.fill", title: "Recording sounds",
                          subtitle: "A soft chime when capture starts and stops.",
                          isOn: $settings.audioFeedbackEnabled)
            if settings.audioFeedbackEnabled {
                RowDivider()
                SettingRow(icon: "dial.medium", title: "Sound volume", active: true) {
                    Slider(value: $settings.audioFeedbackVolume, in: 0...1)
                        .frame(width: 150).tint(.accentColor)
                }
            }
            RowDivider()
            SettingToggle(icon: "number", title: "Spoken numbers as digits",
                          subtitle: "“three thirty PM” becomes 3:30 PM, “twenty dollars” becomes $20.",
                          isOn: $settings.numberFormattingEnabled)
            RowDivider()
            SettingToggle(icon: "list.number", title: "Spoken numbered lists",
                          subtitle: "Count off items and Yappy lays them out as a 1. 2. 3. list.",
                          isOn: $settings.numberedListsEnabled)
            RowDivider()
            SettingToggle(icon: "eraser", title: "Remove filler words",
                          subtitle: "Strips stray “um”, “uh”, “erm”, and “hmm”.",
                          isOn: $settings.fillerRemovalEnabled)
            RowDivider()
            SettingToggle(icon: "text.alignleft", title: "Spoken formatting commands",
                          subtitle: "Say “new line” or “new paragraph” to insert line breaks.",
                          isOn: $settings.spokenCommandsEnabled)
            RowDivider()
            SettingToggle(icon: "questionmark.circle", title: "Spoken punctuation",
                          subtitle: "Say “comma”, “period”, or “question mark” to punctuate.",
                          isOn: $settings.spokenPunctuationEnabled)
            RowDivider()
            SettingToggle(icon: "arrow.uturn.backward", title: "Voice editing commands",
                          subtitle: "“scratch that”, “delete the last word”, or “all caps that”.",
                          isOn: $settings.voiceEditingEnabled)
            RowDivider()
            SettingToggle(icon: "wand.and.rays", title: "Voice commands",
                          subtitle: "“switch to <mode> mode”, “open scratchpad”, or “new note”.",
                          isOn: $settings.voiceControlEnabled)
        }
    }

    private var aiCleanupSection: some View {
        SettingsSection(icon: "sparkles", title: "AI cleanup", tinted: true) {
            SettingToggle(icon: "wand.and.stars", title: "Clean up transcripts",
                          subtitle: "On-device polish for punctuation, casing, and phrasing. Runs with Apple Intelligence (macOS 26+); inserts the raw transcript if it isn’t available.",
                          isOn: $settings.cleanupEnabled)
            if settings.cleanupEnabled {
                RowDivider()
                SettingToggle(icon: "arrow.triangle.2.circlepath", title: "Adapt tone to the app",
                              subtitle: "Match formality to where you’re typing.",
                              isOn: $settings.contextAwareToneEnabled)
                if settings.contextAwareToneEnabled {
                    ForEach(AppCategory.allCases, id: \.self) { category in
                        RowDivider()
                        SettingRow(icon: "app", title: category.displayName) {
                            Picker("", selection: toneBinding(for: category)) {
                                Text("Auto (\(category.defaultTone.displayName))").tag(Optional<ToneStyle>.none)
                                ForEach(ToneStyle.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
                RowDivider()
                SettingToggle(icon: "arrow.uturn.left", title: "Resolve self-corrections",
                              subtitle: "“meet at 2, actually 3” becomes “Let’s meet at 3.”",
                              isOn: $settings.backtrackEnabled)
            }
        }
    }

    private var generalSection: some View {
        SettingsSection(icon: "gearshape", title: "General") {
            SettingToggle(icon: "power", title: "Launch Yappy at login", isOn: $settings.launchAtLogin)
            RowDivider()
            SettingRow(icon: "waveform", title: "Speech model",
                       subtitle: "Parakeet — English, fastest. Nemotron — multilingual, ~670 MB on first use.") {
                Picker("", selection: $settings.transcriptionModel) {
                    ForEach(TranscriptionModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            RowDivider()
            ModelStatusRow(settings: settings, transcriptionService: transcriptionService)
                .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var privacySection: some View {
        SettingsSection(icon: "lock.shield", title: "History & privacy") {
            SettingToggle(icon: "clock.arrow.circlepath", title: "Save dictation history",
                          subtitle: "Keeps a local log of your dictations for stats and history. Never leaves your Mac.",
                          isOn: $settings.saveHistoryEnabled)
            if settings.saveHistoryEnabled {
                RowDivider()
                SettingRow(icon: "calendar", title: "Keep history for",
                           subtitle: "Older dictations are removed automatically.") {
                    Picker("", selection: $settings.historyRetentionDays) {
                        Text("Forever").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if let historyStore {
                RowDivider()
                SettingRow(icon: "trash", title: "Clear history now",
                           subtitle: "Permanently deletes every stored dictation. This can’t be undone.",
                           iconColor: Brand.danger) {
                    Button("Clear history") { historyStore.clearAll() }
                }
            }
            RowDivider()
            SettingRow(icon: "key.fill", title: "Password fields are never recorded",
                       subtitle: "While a secure input field (like a password box) is focused, dictations aren’t added to your history.") {
                EmptyView()
            }
        }
    }

    private var softwareUpdateSection: some View {
        SettingsSection(icon: "arrow.down.circle", title: "Software update") {
            SettingRow(icon: "number.circle", title: "Current version") {
                Text(updateChecker.currentVersionDisplay)
                    .font(.system(size: 13)).foregroundStyle(Brand.ink3)
            }
            RowDivider()
            SettingRow(icon: "sparkles", title: "What’s new",
                       subtitle: "See the release notes for this version.") {
                Button("View") { onShowReleaseNotes() }
            }
            RowDivider()
            SettingToggle(icon: "clock.arrow.circlepath", title: "Check automatically",
                          subtitle: "Downloaded from GitHub and signature-verified before installing.",
                          isOn: $settings.autoUpdateChecksEnabled)
            RowDivider()
            SettingRow(icon: "arrow.down.circle", title: "Check for updates") {
                HStack(spacing: 10) {
                    if let release = updateChecker.available {
                        Label("v\(release.version) ready", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                    }
                    Button {
                        updateChecker.checkForUpdates()
                    } label: {
                        if updateChecker.isChecking {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                        } else {
                            Text("Check now")
                        }
                    }
                    .disabled(updateChecker.isChecking)
                }
            }
        }
    }

    private var permissionsSection: some View {
        SettingsSection(icon: "lock.shield", title: "Permissions") {
            permissionRow(title: "Microphone", granted: microphoneGranted, pane: "Privacy_Microphone")
            RowDivider()
            permissionRow(title: "Accessibility", granted: accessibilityGranted, pane: "Privacy_Accessibility")
        }
    }

    // MARK: - Helpers

    private func permissionRow(title: String, granted: Bool, pane: String) -> some View {
        SettingRow(
            icon: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            title: title,
            subtitle: granted ? "Granted." : "Required — open System Settings to enable.",
            iconColor: granted ? Brand.ready : Brand.danger
        ) {
            if !granted {
                Button("Open settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

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
}

// MARK: - Bespoke setting components

/// A titled section: an accent icon + label header above a glass card of rows.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: String
    var tinted: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 23, height: 23)
                    .overlay(Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink2)
                Spacer()
            }
            .padding(.horizontal, 4).padding(.bottom, 11)

            VStack(spacing: 0) { content() }
                .glassPanel(cornerRadius: 16, tint: tinted ? Color.accentColor.opacity(0.32) : nil)
        }
    }
}

/// One setting: an icon chip, a title with optional inline description, and a
/// trailing control. The chip tints to the accent when the setting is `active`.
private struct SettingRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var active: Bool = false
    var iconColor: Color? = nil
    @ViewBuilder var trailing: () -> Trailing

    private var highlighted: Bool { active || iconColor != nil }
    private var chip: Color { iconColor ?? Color.accentColor }

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlighted ? chip.opacity(0.18) : Color.white.opacity(0.06))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(highlighted ? chip : Brand.ink3))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(highlighted ? chip.opacity(0.25) : Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Brand.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Brand.ink4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// A `SettingRow` whose trailing control is a switch bound to `isOn`.
private struct SettingToggle: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(icon: icon, title: title, subtitle: subtitle, active: isOn) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(.accentColor)
        }
    }
}

/// Hairline between rows, inset to start under the row's text (past the icon chip).
private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 63)
    }
}
