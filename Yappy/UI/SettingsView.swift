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
    /// Shared sidebar-selection state — lets the collapsed voice-commands
    /// group's "See every phrase" link jump to the Commands tab.
    @ObservedObject var windowState: MainWindowState

    @State private var microphoneGranted = AudioRecorder.hasPermission
    @State private var accessibilityGranted = AXIsProcessTrusted()
    /// Whether the collapsed "Voice commands & formatting" group is expanded.
    /// Intentionally plain `@State` (not persisted) — resets each time Settings
    /// is opened, which is fine for a disclosure group.
    @State private var voiceCommandsExpanded = false
    @State private var confirmClearHistory = false
    @State private var confirmClearAnswersRuntime = false
    /// `nil` until the first `StorageInventory.measure()` completes.
    @State private var storageItems: [StorageItem]?

    /// One backend's connection state, for the Ask "green light". Checked
    /// silently (file probes only, no network) and re-checked whenever the app
    /// becomes active — install codex in Terminal, switch back, light turns on.
    enum AskBackendReadiness: Equatable {
        case ready
        case authExpired
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
        .onReceive(askController.$codexHealth) { _ in refreshAskReadiness() }
        .onReceive(askController.$grokHealth) { _ in refreshAskReadiness() }
    }

    /// Silent infrastructure check for Ask: cheap file probes, no network.
    private func refreshAskReadiness() {
        askController.updateInstallationState(installed: CodexAskClient.isInstalled, for: .codex)
        askController.updateInstallationState(installed: GrokAskClient.isAvailable, for: .grok)
        askCodexReadiness = Self.lightState(
            fileSignedIn: CodexAskClient.isSignedIn,
            health: CodexAskClient.isInstalled ? askController.codexHealth : .notInstalled
        )
        askGrokReadiness = Self.lightState(
            fileSignedIn: GrokAskClient.isSignedIn,
            health: GrokAskClient.isAvailable ? askController.grokHealth : .notInstalled
        )
    }

    static func lightState(
        fileSignedIn: Bool,
        health: AskBackendHealth
    ) -> AskBackendReadiness {
        if health == .notInstalled { return .notInstalled }
        if health == .authExpired { return .authExpired }
        return fileSignedIn ? .ready : .needsLogin
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

    /// One-line explainer for the Activation picker, plus the shared
    /// max-duration safety note — a locked (double-tap) recording still
    /// force-stops after the same cap as a held one (`armMaxDurationTimer`
    /// deactivates the hotkey on a fixed wall-clock timer regardless of mode).
    private var activationSubtitle: String {
        let minutes = Int(Constants.maxRecordingDuration / 60)
        return "\(settings.hotkeyActivation.explainer) Auto-stops after \(minutes) minutes either way."
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
                       subtitle: settings.hotkeyActivation == .doubleTapLock
                           ? "Double-tap to start, tap again to stop."
                           : "Hold to record, release to insert.") {
                Picker("", selection: $settings.hotkeyOption) {
                    ForEach(HotkeyOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(icon: "hand.tap", title: "Activation",
                       subtitle: activationSubtitle) {
                Picker("", selection: $settings.hotkeyActivation) {
                    ForEach(HotkeyActivation.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(icon: "sparkles", title: "Listening glow",
                       subtitle: "The ring around the pill while it listens, and around Answers through the reply. Rainbow slowly circles; White and Orange hold steady.") {
                Picker("", selection: $settings.listeningGlowStyle) {
                    ForEach(ListeningGlowStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingToggle(icon: "speaker.wave.2.fill", title: "Recording sounds",
                          subtitle: "A soft chime when capture starts and stops.",
                          isOn: $settings.audioFeedbackEnabled)
            if settings.audioFeedbackEnabled {
                NestedSettingGroup {
                    SettingRow(icon: "dial.medium", title: "Sound volume", active: true) {
                        Slider(value: $settings.audioFeedbackVolume, in: 0...1)
                            .frame(width: 150).tint(.accentColor)
                    }
                }
            }
            DisclosureGroup(isExpanded: $voiceCommandsExpanded) {
                VStack(spacing: 0) {
                    SettingToggle(icon: "number", title: "Spoken numbers as digits",
                                  subtitle: "“three thirty PM” becomes 3:30 PM, “twenty dollars” becomes $20.",
                                  isOn: $settings.numberFormattingEnabled)
                    SettingToggle(icon: "list.number", title: "Spoken numbered lists",
                                  subtitle: "Count off items and Yappy lays them out as a 1. 2. 3. list.",
                                  isOn: $settings.numberedListsEnabled)
                    SettingToggle(icon: "eraser", title: "Remove filler words",
                                  subtitle: "Strips stray “um”, “uh”, “erm”, and “hmm”.",
                                  isOn: $settings.fillerRemovalEnabled)
                    SettingToggle(icon: "text.alignleft", title: "Spoken formatting commands",
                                  subtitle: "Say “new line” or “new paragraph” to insert line breaks.",
                                  isOn: $settings.spokenCommandsEnabled)
                    SettingToggle(icon: "questionmark.circle", title: "Spoken punctuation",
                                  subtitle: "Say “comma”, “period”, or “question mark” to punctuate.",
                                  isOn: $settings.spokenPunctuationEnabled)
                    SettingToggle(icon: "arrow.uturn.backward", title: "Voice editing commands",
                                  subtitle: "“scratch that”, “delete the last word”, or “all caps that”.",
                                  isOn: $settings.voiceEditingEnabled)
                    SettingToggle(icon: "wand.and.rays", title: "Voice commands",
                                  subtitle: "“switch to <mode> mode”, “open scratchpad”, or “new note”.",
                                  isOn: $settings.voiceControlEnabled)
                    SettingRow(icon: "text.book.closed", title: "See every phrase",
                               subtitle: "The full list of spoken commands and formatting Yappy understands.") {
                        Button("Open Commands") { windowState.select(.commands) }
                    }
                }
            } label: {
                HStack(spacing: 13) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: "gearshape.2").font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Brand.ink3))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06)))
                    Text("Voice commands & formatting")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Brand.ink)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .tint(Brand.ink3)
            SettingToggle(icon: "wand.and.stars", title: "Voice Edit (experimental)",
                          subtitle: settings.hotkeyOption == .rightOptionHold
                              ? "Right Option is your dictation key — pick a different activation hotkey above to free it for Voice Edit."
                              : "Select text in any app, hold Right Option, and speak an edit (“make this bullets”, “make it more formal”). A preview card shows the change before you Replace.",
                          isOn: $settings.voiceEditAnywhereEnabled)
        }
    }

    private var aiCleanupSection: some View {
        SettingsSection(icon: "sparkles", title: "AI cleanup") {
            SettingToggle(icon: "wand.and.stars", title: "Clean up transcripts",
                          subtitle: "On-device polish for punctuation, casing, and phrasing. Runs with Apple Intelligence (macOS 26+); inserts the raw transcript if it isn’t available.",
                          isOn: $settings.cleanupEnabled)
            if settings.cleanupEnabled {
                NestedSettingGroup {
                    SettingRow(icon: "slider.horizontal.3", title: "How much cleanup",
                               subtitle: "Standard polishes lightly. Conservative only fixes punctuation, capitalization, and standalone fillers — no rewording.") {
                        Picker("", selection: $settings.cleanupIntensity) {
                            ForEach(CleanupIntensity.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    SettingToggle(icon: "text.magnifyingglass", title: "Show polish caption",
                                  subtitle: "After insert, briefly offer “use your exact words” when cleanup changed the text.",
                                  isOn: $settings.cleanupDiffCaptionEnabled)
                    SettingToggle(icon: "arrow.triangle.2.circlepath", title: "Adapt tone to the app",
                                  subtitle: "Match register to where you’re typing. Formal expands contractions and ends sentences with punctuation; Casual drops the trailing period on short messages; Verbatim skips cleanup.",
                                  isOn: $settings.contextAwareToneEnabled)
                    if settings.contextAwareToneEnabled {
                        NestedSettingGroup(nested: true) {
                            ForEach(AppCategory.allCases, id: \.self) { category in
                                SettingRow(icon: "app", title: category.displayName) {
                                    Picker("", selection: toneBinding(for: category)) {
                                        Text("Auto (\(category.defaultTone.displayName))").tag(Optional<ToneStyle>.none)
                                        ForEach(ToneStyle.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                                    }
                                    .labelsHidden().fixedSize()
                                }
                            }
                        }
                    }
                    SettingToggle(icon: "arrow.uturn.left", title: "Resolve self-corrections",
                                  subtitle: "“meet at 2, actually 3” becomes “Let’s meet at 3.”",
                                  isOn: $settings.backtrackEnabled)
                }
            }
            SettingToggle(icon: "character.book.closed", title: "Auto-learn dictionary corrections",
                          subtitle: "High-confidence “scratch that” fixes become aliases immediately (click the pill to undo). Low-confidence ones stay as Dictionary suggestions.",
                          isOn: $settings.dictionaryAutoLearnEnabled)
        }
    }

    private var generalSection: some View {
        SettingsSection(icon: "gearshape", title: "General") {
            SettingToggle(icon: "power", title: "Launch Yappy at login", isOn: $settings.launchAtLogin)
            SettingRow(icon: "waveform", title: "Speech model",
                       subtitle: "Parakeet — English, fastest. Nemotron — multilingual, ~670 MB on first use.") {
                Picker("", selection: $settings.transcriptionModel) {
                    ForEach(TranscriptionModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if settings.transcriptionModel == .nemotron {
                SettingRow(icon: "lightbulb", title: "Dictating mostly in English?",
                           subtitle: "Parakeet is faster and more accurate for English, and supports dictionary boosting.") {
                    EmptyView()
                }
            }
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
        SettingsSection(icon: "questionmark.bubble", title: "Answers") {
            askReadinessRow
            // Locked until a backend is connected — but never locks the OFF
            // direction (a vanished codex must not trap the toggle on).
            SettingToggle(icon: "mic", title: "Hold \(settings.askHotkeyOption.shortName) to ask",
                          subtitle: askToggleSubtitle,
                          isOn: $settings.askEnabled)
                .disabled(!askAnyBackendReady && !settings.askEnabled)
                .opacity(askAnyBackendReady || settings.askEnabled ? 1 : 0.55)
            if settings.askEnabled {
                NestedSettingGroup {
                    SettingRow(icon: "keyboard", title: "Ask key",
                               subtitle: askKeySubtitle) {
                        Picker("", selection: $settings.askHotkeyOption) {
                            ForEach(AskHotkeyOption.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    // Offer the model choice only when there IS a choice.
                    if askCodexReadiness == .ready && askGrokReadiness == .ready {
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
                        SettingRow(icon: "brain.head.profile", title: "Grok model",
                                   subtitle: "Grok 4.5 answers best; Composer 2.5 Fast is snappier.") {
                            Picker("", selection: $settings.askGrokModel) {
                                ForEach(AskGrokModel.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    SettingToggle(icon: "clock.arrow.circlepath", title: "Save answer history",
                                  subtitle: "On keeps a local log on this Mac. Off also wipes backend runtime files whenever an answer closes, which may make the next answer start a little slower.",
                                  isOn: $settings.askSaveHistoryEnabled)
                    ttsReadinessRow
                    SettingToggle(icon: "speaker.wave.2", title: "Read answers aloud",
                                  subtitle: "Adds a Speak button to the answer card, and the “read that” voice command.",
                                  isOn: $settings.answersSpeakEnabled)
                        .disabled(ttsReadiness != .ready && !settings.answersSpeakEnabled)
                        .opacity(ttsReadiness == .ready || settings.answersSpeakEnabled ? 1 : 0.55)
                    if settings.answersSpeakEnabled {
                        NestedSettingGroup(nested: true) {
                            SettingToggle(icon: "speaker.wave.2.bubble.left", title: "Speak every answer",
                                          subtitle: "Read each answer aloud automatically as it finishes.",
                                          isOn: $settings.answersAutoSpeak)
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
                    }
                    if settings.askHotkeyOption == .fnGlobe {
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
        if askReadiness(for: selected) == .authExpired { return selected }
        if askReadiness(for: selected) == .ready { return selected }
        let other: AskBackend = selected == .codex ? .grok : .codex
        if askReadiness(for: other) == .ready { return other }
        return selected
    }

    private var askToggleSubtitle: String {
        guard askAnyBackendReady else {
            return "Turns on once Codex (or Grok) is connected above."
        }
        let key = settings.askHotkeyOption == .fnGlobe
            ? "the Globe/Fn key" : settings.askHotkeyOption.shortName
        return "Hold \(key), ask out loud, and the answer appears in a pill — with web search and sources. Your spoken question goes to your own model account, not Yappy."
    }

    /// Conflict warning when the chosen Ask key is taken; otherwise explains
    /// why anyone would change it (firmware-local Fn on many external boards).
    private var askKeySubtitle: String {
        if let reason = settings.askHotkeyOption.conflict(
            dictation: settings.hotkeyOption,
            voiceEditEnabled: settings.voiceEditAnywhereEnabled
        ) {
            return reason + " Answers stays off this key until the clash is resolved."
        }
        return "No Fn key on your keyboard? Many external boards handle Fn in firmware, so macOS never sees it — pick a right-side modifier instead."
    }

    /// The "green light" row: silent check of the user's Codex install, with
    /// exactly one next step when something's missing.
    private var askReadinessRow: some View {
        let effective = effectiveAskBackendForReadiness
        let effectiveReadiness = askReadiness(for: effective)
        let selectedReady = askReadiness(for: settings.askBackend) == .ready

        let (color, title, subtitle): (Color, String, String) = {
            if effectiveReadiness == .authExpired {
                return (
                    Color.accentColor,
                    "\(effective == .codex ? "Codex" : "Grok") session expired",
                    "Signed in session expired — run `\(effective.rawValue)` in Terminal to re-login."
                )
            }
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
            case .authExpired:
                return (Color.accentColor, "Session expired", "Re-login in Terminal, then return to Yappy.")
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
            if effectiveReadiness == .authExpired {
                let command = effective.rawValue
                Button(copiedLoginCommand ? "Copied" : "Copy “\(command)”") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedLoginCommand = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedLoginCommand = false }
                }
                .buttonStyle(.bordered)
            } else if askAnyBackendReady {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Brand.ready)
            } else {
                switch effectiveReadiness {
                case .ready:
                    EmptyView()
                case .authExpired:
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
        .accessibilityLabel(isPreviewing ? "Stop voice sample" : "Play voice sample")
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
                SettingRow(icon: "trash", title: "Clear history now",
                           subtitle: "Permanently deletes every stored dictation. This can’t be undone.",
                           iconColor: Brand.danger) {
                    Button("Clear history") { confirmClearHistory = true }
                        .confirmationDialog(
                            "Delete all \(historyStore.entries.count) dictations? This can't be undone.",
                            isPresented: $confirmClearHistory,
                            titleVisibility: .visible
                        ) {
                            Button("Delete All", role: .destructive) {
                                historyStore.clearAll()
                                // Re-measure: the storage rows below would
                                // otherwise keep showing the deleted history's
                                // size until Settings is reopened.
                                Task { await refreshStorageInventory() }
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                }
            }
            SettingRow(icon: "key.fill", title: "Password fields are never recorded",
                       subtitle: "While a secure input field (like a password box) is focused, dictations aren’t added to your history.") {
                EmptyView()
            }

            // MARK: Storage on this Mac (Phase C)
            storageTotalRow
            ForEach(storageDisplayRows) { row in
                storageItemRow(row)
            }
            SettingRow(icon: "trash", title: "Clear Answers runtime data",
                       subtitle: "Wipes temporary session files Answers backends keep on this Mac. Answer history is separate.",
                       iconColor: Brand.danger) {
                Button("Clear runtime data") { confirmClearAnswersRuntime = true }
                    .confirmationDialog(
                        "Clear Answers runtime data? Temporary session files used by Answers will be deleted. This can’t be undone.",
                        isPresented: $confirmClearAnswersRuntime,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Runtime Data", role: .destructive) {
                            askController.clearRuntimeAndHistory()
                            Task { await refreshStorageInventory() }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        }
        .task { await refreshStorageInventory() }
    }

    /// Measured items when ready; otherwise placeholder rows from `locations`
    /// so empty paths still appear as honest "Empty" proof once sized.
    /// The `-1` is a view-local "not measured yet" marker: `StorageInventory`
    /// never returns a negative count, so a negative can only mean these
    /// synthesized rows.
    private var storageDisplayRows: [StorageItem] {
        if let storageItems { return storageItems }
        return StorageInventory.locations.map {
            StorageItem(id: $0.id, title: $0.title, detail: $0.detail, bytes: -1)
        }
    }

    private var storageTotalBytes: Int64? {
        guard let storageItems else { return nil }
        return storageItems.reduce(0) { $0 + $1.bytes }
    }

    private var storageTotalRow: some View {
        SettingRow(
            icon: "internaldrive",
            title: "Storage on this Mac",
            subtitle: "Your voice is never recorded to a file. This is everything Yappy keeps on this Mac."
        ) {
            if let total = storageTotalBytes {
                Text(StorageInventory.formatted(total))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.ink3)
                    .monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(storageTotalAccessibilityLabel)
    }

    private var storageTotalAccessibilityLabel: String {
        if let total = storageTotalBytes {
            return "Storage on this Mac, \(StorageInventory.formatted(total))"
        }
        return "Storage on this Mac, measuring"
    }

    private func storageItemRow(_ item: StorageItem) -> some View {
        let isPlaceholder = item.bytes < 0
        let sizeText: String = {
            if isPlaceholder { return "—" }
            if item.isEmpty { return "Empty" }
            return StorageInventory.formatted(item.bytes)
        }()
        let sizeColor: Color = {
            if isPlaceholder { return Brand.ink4 }
            if item.isEmpty { return Brand.ink4 }
            return Brand.ink3
        }()
        return SettingRow(
            icon: "doc",
            title: item.title,
            subtitle: item.detail,
            iconColor: isPlaceholder ? Brand.ink4 : nil
        ) {
            Text(sizeText)
                .font(.system(size: 13))
                .foregroundStyle(sizeColor)
                .monospacedDigit()
                .opacity(isPlaceholder ? 0.55 : 1)
        }
        .opacity(isPlaceholder ? 0.72 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(isPlaceholder ? "measuring" : sizeText)")
    }

    /// Sizes via `StorageInventory.measure()` only — no file I/O on the main thread.
    private func refreshStorageInventory() async {
        let items = await StorageInventory.measure()
        // Assign without animation so Reduce Motion / size flips never animate.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            storageItems = items
        }
    }

    private var softwareUpdateSection: some View {
        SettingsSection(icon: "arrow.down.circle", title: "Software update") {
            SettingRow(icon: "number.circle", title: "Current version") {
                Text(updateChecker.currentVersionDisplay)
                    .font(.system(size: 13)).foregroundStyle(Brand.ink3)
            }
            SettingRow(icon: "sparkles", title: "What’s new",
                       subtitle: "See the release notes for this version.") {
                Button("View") { onShowReleaseNotes() }
            }
            SettingToggle(icon: "clock.arrow.circlepath", title: "Check automatically",
                          subtitle: "Downloaded from GitHub and signature-verified before installing.",
                          isOn: $settings.autoUpdateChecksEnabled)
            SettingRow(icon: "arrow.down.circle", title: "Check for updates") {
                HStack(spacing: 10) {
                    if let release = updateChecker.available {
                        Label("v\(release.version) ready", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                    } else if case .upToDate = updateChecker.lastCheckResult, !updateChecker.isChecking {
                        Text("You're on the latest version")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.ink3)
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
    /// Retained for call-site compatibility; no longer paints an accent tint —
    /// every section now uses the same neutral glass so no two sections read as
    /// "special" (the old orange-tinted AI cleanup / Answers looked out of place
    /// next to the neutral ones).
    var tinted: Bool = false
    @ViewBuilder var content: () -> Content

    /// Ephemeral, defaults expanded so nothing is hidden on open (and the
    /// Settings UI test still finds every section's content). Collapsing is a
    /// convenience for a long page, not a persisted preference.
    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 23, height: 23)
                        .overlay(Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor))
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink2)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.ink4)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 4).padding(.bottom, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(expanded ? "Expanded. Activate to collapse." : "Collapsed. Activate to expand.")
            .accessibilityAddTraits(expanded ? [.isSelected] : [])

            if expanded {
                VStack(spacing: 0) { content() }
                    .glassPanel(cornerRadius: 16)
            }
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
            // labelsHidden() drops the (empty) inline label — without an explicit
            // accessibilityLabel VoiceOver announces a bare "switch, off/on" with
            // no name. Single-point fix: every SettingToggle call site inherits it.
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .accessibilityLabel(title)
        }
    }
}

/// Hairline between rows, inset to start under the row's text (past the icon chip).
private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 63)
    }

}
/// Indented container for dependent settings, with a left accent rail.
/// Rows inside separate by their own padding; no RowDividers.
private struct NestedSettingGroup<Content: View>: View {
    var nested: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        // A thin rail at the LEADING edge (an HStack sibling, so it always
        // matches content height — no overlay geometry to misplace). Neutral,
        // not accent, so nested groups don't pile more orange onto the page.
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .frame(width: 2)
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
        .padding(.leading, nested ? 14 : 20)
        .padding(.vertical, 2)
    }
}

/// A compact toggle chip for boolean settings in a chip row.
private struct SettingChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? Color.accentColor : Color.white.opacity(0.2))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isOn ? Brand.ink2 : Brand.ink4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.07))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A wrapping row of SettingChips.
private struct SettingChipRow: View {
    let chips: [SettingChip]

    init(_ chips: SettingChip...) {
        self.chips = chips
    }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(chips.indices, id: \.self) { i in
                chips[i]
                if i < chips.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
