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
    /// Drives the voice-preview play/stop button (`previewingVoice`) and triggers
    /// the sample synthesis. Optional so call sites that don't wire it still build.
    @ObservedObject var askController: AskController
    /// Optional history store, used only for the "Clear history now" button. When
    /// nil (e.g. a call site that hasn't wired it yet) the button is hidden.
    var historyStore: HistoryStore? = nil
    /// Re-shows the "What's New" card; wired by MainWindowView to the presenter.
    var onShowReleaseNotes: () -> Void = {}

    @State private var microphoneGranted = AudioRecorder.hasPermission
    @State private var accessibilityGranted = AXIsProcessTrusted()

    /// One backend's connection state, for the Ask "green light". Checked
    /// silently (file probes only, no network) and re-checked whenever the app
    /// becomes active — install codex in Terminal, switch back, light turns on.
    enum AskBackendReadiness {
        case ready
        case needsLogin
        case notInstalled
    }
    enum TTSReadyState {
        case checking
        case ready
        case notInstalled
    }
    @State private var askCodexReadiness: AskBackendReadiness = .notInstalled
    @State private var askGrokReadiness: AskBackendReadiness = .notInstalled
    @State private var ttsReadiness: TTSReadyState = .checking
    @State private var copiedLoginCommand = false
    @State private var copiedTTSInstallCommand = false

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
                askSection
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 46)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onAppear {
            refreshAskReadiness()
            refreshTTSReadiness()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            microphoneGranted = AudioRecorder.hasPermission
            accessibilityGranted = AXIsProcessTrusted()
            refreshAskReadiness()
            refreshTTSReadiness()
        }
    }

    /// Silent infrastructure check for Ask: cheap file probes, no network.
    private func refreshAskReadiness() {
        askCodexReadiness = CodexAskClient.isInstalled
            ? (CodexAskClient.isSignedIn ? .ready : .needsLogin)
            : .notInstalled
        askGrokReadiness = GrokAskClient.isAvailable
            ? (GrokAskClient.isSignedIn ? .ready : .needsLogin)
            : .notInstalled
    }

    private func refreshTTSReadiness() {
        // Once confirmed ready, don't re-probe: refreshReadiness() spawns a
        // Python process that loads misaki's G2P (~1-3s of CPU), and this runs on
        // every app activation while Settings is open. Re-probe only when
        // not-yet-ready, which still catches an install completed while open.
        if ttsReadiness == .ready { return }
        ttsReadiness = .checking
        Task {
            let ok = await TTSSpeakClient.refreshReadiness()
            await MainActor.run {
                ttsReadiness = ok ? .ready : .notInstalled
            }
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
            SettingRow(icon: "sparkles", title: "Listening glow",
                       subtitle: "The ring around the pill while it listens, and around Answers through the reply. Rainbow slowly circles; White and Orange hold steady.") {
                Picker("", selection: $settings.listeningGlowStyle) {
                    ForEach(ListeningGlowStyle.allCases) { Text($0.displayName).tag($0) }
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
                              subtitle: "Match register to where you’re typing. Formal expands contractions and ends sentences with punctuation; Casual drops the trailing period on short messages; Verbatim skips cleanup.",
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
            if settings.transcriptionModel == .nemotron {
                RowDivider()
                SettingRow(icon: "lightbulb", title: "Dictating mostly in English?",
                           subtitle: "Parakeet is faster and more accurate for English, and supports dictionary boosting.") {
                    EmptyView()
                }
            }
            RowDivider()
            ModelStatusRow(settings: settings, transcriptionService: transcriptionService)
                .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    /// Ask (hold-Fn voice questions) — experimental, OFF by default. The only
    /// Yappy feature that touches the network, and only via the user's own
    /// Codex/Grok account.
    ///
    /// Setup philosophy: Yappy checks the user's Codex install silently (file
    /// probes, re-run whenever the app activates) and shows one green light.
    /// The enable toggle stays locked until something is connected, so the
    /// whole flow is "see the green light, flip the switch."
    private var askSection: some View {
        SettingsSection(icon: "questionmark.bubble", title: "Answers", tinted: true) {
            askReadinessRow
            RowDivider()
            // Locked until a backend is connected — but never locks the OFF
            // direction (a vanished codex must not trap the toggle on).
            SettingToggle(icon: "mic", title: "Hold Fn to ask",
                          subtitle: askToggleSubtitle,
                          isOn: $settings.askEnabled)
                .disabled(!askAnyBackendReady && !settings.askEnabled)
                .opacity(askAnyBackendReady || settings.askEnabled ? 1 : 0.55)
            if settings.askEnabled {
                // Offer the model choice only when there IS a choice.
                if askCodexReadiness == .ready && askGrokReadiness == .ready {
                    RowDivider()
                    SettingRow(icon: "cpu", title: "Answering model",
                               subtitle: "Both research with their own web search.") {
                        Picker("", selection: $settings.askBackend) {
                            ForEach(AskBackend.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                // Grok has two models; the choice routes every Grok answer.
                if settings.askBackend == .grok, askGrokReadiness == .ready {
                    RowDivider()
                    SettingRow(icon: "brain.head.profile", title: "Grok model",
                               subtitle: "Grok 4.5 answers best; Composer 2.5 Fast is snappier.") {
                        Picker("", selection: $settings.askGrokModel) {
                            ForEach(AskGrokModel.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                RowDivider()
                SettingToggle(icon: "clock.arrow.circlepath", title: "Save answer history",
                              subtitle: "Keeps questions and answers in a local log on this Mac. Turn off and nothing is stored.",
                              isOn: $settings.askSaveHistoryEnabled)
                RowDivider()
                ttsReadinessRow
                RowDivider()
                SettingToggle(icon: "speaker.wave.2", title: "Read answers aloud",
                              subtitle: "Adds a Speak button to the answer card, and the “read that” voice command.",
                              isOn: $settings.answersSpeakEnabled)
                    .disabled(ttsReadiness != .ready && !settings.answersSpeakEnabled)
                    .opacity(ttsReadiness == .ready || settings.answersSpeakEnabled ? 1 : 0.55)
                if settings.answersSpeakEnabled {
                    RowDivider()
                    SettingToggle(icon: "speaker.wave.2.bubble.left", title: "Speak every answer",
                                  subtitle: "Read each answer aloud automatically as it finishes.",
                                  isOn: $settings.answersAutoSpeak)
                    RowDivider()
                    SettingRow(icon: "waveform", title: "Voice",
                               subtitle: "Eight on-device voices, American and British. Tap play to hear a sample.") {
                        HStack(spacing: 10) {
                            voicePreviewButton
                            Picker("", selection: $settings.answersVoice) {
                                ForEach(AnswersVoice.allCases) { Text($0.displayName).tag($0.rawValue) }
                            }
                            .labelsHidden().fixedSize()
                            .onChange(of: settings.answersVoice) { _, _ in
                                // Switching voices cancels a sample in progress.
                                askController.stopVoicePreview()
                            }
                        }
                    }
                    RowDivider()
                    SettingRow(icon: "gauge.with.needle", title: "Voice speed",
                               subtitle: "How fast answers are read. The play button previews the current speed.") {
                        Picker("", selection: $settings.answersVoiceSpeed) {
                            ForEach(AnswersVoiceSpeed.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: settings.answersVoiceSpeed) { _, _ in
                            // A sample rendered at the old speed shouldn't keep playing.
                            askController.stopVoicePreview()
                        }
                    }
                }
                RowDivider()
                SettingRow(icon: "globe", title: "Set the Globe key free",
                           subtitle: "For reliable Fn capture, set System Settings → Keyboard → “Press 🌐 to” = Do Nothing.") {
                    Button("Open Keyboard Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        // If only one backend is connected, quietly make it the active one so
        // enabling never selects a dead backend.
        .onChange(of: settings.askEnabled) { _, enabled in
            guard enabled else { return }
            if settings.askBackend == .codex, askCodexReadiness != .ready, askGrokReadiness == .ready {
                settings.askBackend = .grok
            } else if settings.askBackend == .grok, askGrokReadiness != .ready, askCodexReadiness == .ready {
                settings.askBackend = .codex
            }
        }
    }

    private var askAnyBackendReady: Bool {
        askCodexReadiness == .ready || askGrokReadiness == .ready
    }

    private func askReadiness(for backend: AskBackend) -> AskBackendReadiness {
        switch backend {
        case .codex: askCodexReadiness
        case .grok: askGrokReadiness
        }
    }

    /// Backend the readiness row should describe: prefer the selected one when
    /// it's ready, otherwise the other ready backend, otherwise the selected one
    /// for setup messaging.
    private var effectiveAskBackendForReadiness: AskBackend {
        let selected = settings.askBackend
        if askReadiness(for: selected) == .ready { return selected }
        let other: AskBackend = selected == .codex ? .grok : .codex
        if askReadiness(for: other) == .ready { return other }
        return selected
    }

    private var askToggleSubtitle: String {
        askAnyBackendReady
            ? "Hold the Globe/Fn key, ask out loud, and the answer appears in a pill — with web search and sources. Your spoken question goes to your own model account, not Yappy."
            : "Turns on once Codex (or Grok) is connected above."
    }

    /// The "green light" row: silent check of the user's Codex install, with
    /// exactly one next step when something's missing.
    private var askReadinessRow: some View {
        let effective = effectiveAskBackendForReadiness
        let effectiveReadiness = askReadiness(for: effective)
        let selectedReady = askReadiness(for: settings.askBackend) == .ready

        let (color, title, subtitle): (Color, String, String) = {
            if askAnyBackendReady {
                if selectedReady {
                    switch settings.askBackend {
                    case .codex:
                        let grokNote = askGrokReadiness == .ready ? " Grok is connected too." : ""
                        return (Brand.ready, "Codex connected",
                                "Answers uses your own Codex (ChatGPT) sign-in — nothing to configure.\(grokNote)")
                    case .grok:
                        let codexNote = askCodexReadiness == .ready ? " Codex is connected too." : ""
                        return (Brand.ready, "Grok connected",
                                "Answers uses your own Grok sign-in — nothing to configure.\(codexNote)")
                    }
                }
                switch effective {
                case .grok:
                    return (Brand.ready, "Grok connected", "Grok is connected and will answer.")
                case .codex:
                    return (Brand.ready, "Codex connected", "Codex is connected and will answer.")
                }
            }
            switch effectiveReadiness {
            case .ready:
                return (Brand.ready, "\(effective.displayName) connected", "Answers is ready.")
            case .needsLogin:
                switch effective {
                case .codex:
                    return (Color.accentColor, "One step left: sign in",
                            "Codex is installed. Open Terminal, run codex login once, then come back — Yappy notices automatically.")
                case .grok:
                    return (Color.accentColor, "One step left: sign in",
                            "Grok is installed. Open Terminal, run grok login once, then come back — Yappy notices automatically.")
                }
            case .notInstalled:
                switch effective {
                case .codex:
                    return (Brand.ink4, "Codex not found",
                            "Install the Codex CLI or the Codex app and sign in once — Yappy detects it automatically, no paths or keys to enter.")
                case .grok:
                    return (Brand.ink4, "Grok not found",
                            "Install the Grok CLI and sign in once — Yappy detects it automatically, no paths or keys to enter.")
                }
            }
        }()

        return SettingRow(icon: "circle.fill", title: title, subtitle: subtitle, iconColor: color) {
            if askAnyBackendReady {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Brand.ready)
            } else {
                switch effectiveReadiness {
                case .ready:
                    EmptyView()
                case .needsLogin:
                    let command = effective == .codex ? "codex login" : "grok login"
                    Button(copiedLoginCommand ? "Copied" : "Copy “\(command)”") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copiedLoginCommand = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedLoginCommand = false }
                    }
                    .buttonStyle(.bordered)
                case .notInstalled:
                    if effective == .codex {
                        Button("Get Codex") {
                            if let url = URL(string: "https://github.com/openai/codex") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// Play/stop toggle beside the voice picker: hear a sample of the selected
    /// voice before committing to it.
    private var voicePreviewButton: some View {
        let isPreviewing = askController.previewingVoice == settings.answersVoice
        return Button {
            if isPreviewing {
                askController.stopVoicePreview()
            } else {
                askController.startVoicePreview(settings.answersVoice)
            }
        } label: {
            Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(isPreviewing ? "Stop the sample" : "Hear a sample of this voice")
    }

    @ViewBuilder
    private var ttsReadinessRow: some View {
        switch ttsReadiness {
        case .ready:
            SettingRow(
                icon: "speaker.wave.2",
                title: "Speak answers ready",
                subtitle: "A local neural voice reads answers aloud. Runs 100% on this Mac.",
                iconColor: Brand.ready
            ) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Brand.ready)
            }
        case .notInstalled:
            SettingRow(
                icon: "speaker.wave.2",
                title: "Install the voice engine",
                subtitle: "Reads answers aloud with a fully local voice. Needs Homebrew; a small voice model downloads on first use.",
                iconColor: Brand.ink4
            ) {
                let command = "brew install espeak-ng && pip3 install mlx-audio \"misaki[en]\" && python3 -m spacy download en_core_web_sm"
                Button(copiedTTSInstallCommand ? "Copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedTTSInstallCommand = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedTTSInstallCommand = false }
                }
                .buttonStyle(.bordered)
            }
        case .checking:
            SettingRow(
                icon: "speaker.wave.2",
                title: "Checking for the voice engine…",
                iconColor: Brand.ink4
            ) {
                EmptyView()
            }
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
