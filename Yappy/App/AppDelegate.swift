//
//  AppDelegate.swift
//  Yappy
//

import AVFoundation
import Cocoa
import Combine
import ServiceManagement
import SwiftUI

/// Coordinates the menu bar item, global hotkey, recording pipeline,
/// local Parakeet transcription, and the main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Services

    let settings = Settings()
    let appState = AppState()
    let history = HistoryStore()
    let shortcutStore = ShortcutStore()
    let dictionaryStore = DictionaryStore()
    let transformStore = TransformStore()
    let notesStore = NotesStore()
    let modeStore = ModeStore()
    let transcriptionService = ParakeetTranscriptionService()

    private let audioRecorder = AudioRecorder()
    private let textInserter = TextInserter()
    private let soundPlayer = SoundPlayer()
    private lazy var lmStudio = LMStudioService(settings: settings)
    private lazy var cleanupCoordinator = CleanupCoordinator(
        lmStudio: lmStudio, settings: settings,
        onDeviceProviders: [.appleIntelligence: FoundationModelsCleanupProvider()])
    private lazy var hotkeyManager = HotkeyManager(mode: settings.hotkeyOption)
    private lazy var commandHotkeyManager = HotkeyManager(mode: settings.commandHotkeyOption)
    private lazy var escapeInterceptor = EscapeInterceptor()
    private lazy var pillController = RecordingPillController(appState: appState)
    private lazy var scratchpadController = ScratchpadController(store: notesStore)
    private let scratchpadHotkey = ScratchpadHotkey()

    /// Precompiled custom-dictionary matcher, rebuilt only when the dictionary
    /// changes (not per dictation). Kept in sync via a `dictionaryStore` sink.
    private var dictionaryReplacer = DictionaryReplacer(terms: [])
    private lazy var mainWindowController = MainWindowController(
        settings: settings,
        history: history,
        shortcutStore: shortcutStore,
        dictionaryStore: dictionaryStore,
        transformStore: transformStore,
        modeStore: modeStore,
        transcriptionService: transcriptionService,
        lmStudio: lmStudio,
        updateChecker: updateChecker,
        whatsNewPresenter: whatsNewPresenter
    )

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var modeMenuItem: NSMenuItem?
    private var transformsMenuItem: NSMenuItem?
    /// The "Update to Yappy X.Y…" item shown at the top of the menu when an update
    /// is available, with its trailing separator. Inserted/removed dynamically.
    private var updateMenuItem: NSMenuItem?
    private var updateSeparatorItem: NSMenuItem?
    /// Small accent dot drawn over the menu-bar icon while an update is pending.
    private var updateBadgeView: NSView?

    /// Sparkle auto-updater with gentle reminders: instead of popping a surprise
    /// modal on a background check, it surfaces a found update through the menu-bar
    /// item, the icon badge, and the in-app banner. See `UpdateChecker`.
    let updateChecker = UpdateChecker()
    /// Holds the "What's New" card to show once after an update; the main window
    /// presents it. See `WhatsNew`.
    let whatsNewPresenter = WhatsNewPresenter()
    private var menuBarAnimationTimer: Timer?
    private var menuBarFrameIndex = 0
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private var maxDurationTimer: Timer?
    private var accessibilityPollTimer: Timer?
    private var setupWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    /// Live mic levels for the onboarding preview; nil once onboarding ends.
    private var onboardingLevelModel: OnboardingLevelModel?

    /// True when a dictation press is queued waiting for the speech model to finish
    /// loading; recording auto-starts when it's ready (see bindModelReadyAutostart).
    private var pendingDictationStart = false

    /// Text selected in the frontmost app when Command Mode started.
    private var pendingCommandSelection: String?
    /// Bundle id of the app that had focus when the current session started.
    private var sessionBundleID: String?
    /// Most recently activated app other than Yappy — the app you were in when
    /// you pick a mode from the menu bar (used by adaptive per-app modes).
    private var lastActiveBundleID: String?
    /// Mode resolved at the start of the current session.
    private var sessionMode: Mode = .auto

    // Dictionary-boosted final via the sliding-window manager.

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show the Dock icon for the whole time Yappy is running (alongside the
        // menu bar item), not just while the main window is open.
        NSApp.setActivationPolicy(.regular)

        setupMenuBar()
        bindStateToMenuBar()
        bindModelReadyAutostart()
        bindSettings()

        // Surface a found update through our own UI (gentle reminders). Starting
        // Sparkle and the launch-time background check are DEFERRED below so the
        // speech model + hotkey get launch priority — the model load dominates
        // time-to-first-dictation, and a press right after launch shouldn't wait
        // on update plumbing.
        bindUpdateChecker()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.updateChecker.startUpdater(autoChecks: self.settings.autoUpdateChecksEnabled)
            if self.settings.autoUpdateChecksEnabled {
                self.updateChecker.checkInBackground()
            }
        }

        audioRecorder.onAudioLevelUpdate = { [weak self] level in
            guard let self else { return }
            self.appState.updateAudioLevel(level)
            self.onboardingLevelModel?.push(level)
        }

        wireHotkeyCallbacks()

        // Load the speech model in the background; show first-run UI if downloading.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let needsDownload = await self.warmUpShowingSetupIfNeeded()
            if needsDownload {
                self.closeSetupWindowWhenReady()
            }
        }
        // Note: the on-device cleanup model is deliberately NOT warmed here.
        // Warming it loads it on a background thread, and doing that while a
        // dictation's audio engine is being torn down races CoreAudio and crashes.
        // The model is warmed only at audio-idle moments instead — when the user
        // selects Apple Intelligence (see bindSettings) and right after a cleanup
        // (see finishDictation), then held resident.

        // Onboarding shows only for new users (first launch). Returning users
        // manage permissions from Settings; just resolve mic access up front so
        // the first hotkey press works.
        if settings.onboardingComplete {
            Task { _ = await AudioRecorder.requestPermission() }
        } else {
            showOnboarding()
        }

        // If the user just updated to a version with release notes, greet them
        // with the "What's New" card by opening the main window once. (No-op on a
        // fresh install or when the version is unchanged.)
        if let entry = WhatsNew.pendingAfterLaunch(onboardingComplete: settings.onboardingComplete) {
            whatsNewPresenter.entry = entry
            showMainWindow()
        }

        // Track the frontmost app so adaptive modes can learn per-app preferences.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           front != Bundle.main.bundleIdentifier {
            lastActiveBundleID = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Build the recording pill now, while idle, so the first dictation shows
        // it instantly instead of paying SwiftUI hosting-view construction.
        DispatchQueue.main.async { [weak self] in self?.pillController.prewarm() }

        // Warm the audio input HAL now too: the first AVAudioEngine input start is
        // otherwise slow (the lag before the waveform appears on the first press).
        DispatchQueue.main.async { [weak self] in self?.audioRecorder.prewarm() }

        startHotkeyMonitoring()
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier else { return }
        lastActiveBundleID = bundle
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        commandHotkeyManager.stop()
        escapeInterceptor.stop()
        scratchpadHotkey.stop()
        notesStore.flush()
        maxDurationTimer?.invalidate()
        accessibilityPollTimer?.invalidate()
        menuBarAnimationTimer?.invalidate()
    }

    // MARK: - Hotkey

    private func wireHotkeyCallbacks() {
        hotkeyManager.onStart = { [weak self] in self?.startDictation() }
        hotkeyManager.onStop = { [weak self] in self?.finishDictation() }
        hotkeyManager.onCancel = { [weak self] in self?.cancelDictation() }

        commandHotkeyManager.onStart = { [weak self] in self?.startCommand() }
        commandHotkeyManager.onStop = { [weak self] in self?.finishCommand() }
        commandHotkeyManager.onCancel = { [weak self] in self?.cancelDictation() }

        escapeInterceptor.onEscape = { [weak self] in self?.escapeCancel() }

        scratchpadHotkey.onTrigger = { [weak self] in self?.scratchpadController.toggle() }
    }

    /// Esc pressed mid-session: deactivate both hotkey state machines first so
    /// the eventual modifier key-up doesn't fire a spurious stop, then cancel.
    private func escapeCancel() {
        guard appState.isRecording || appState.isPreparing else { return }
        hotkeyManager.deactivate()
        commandHotkeyManager.deactivate()
        cancelDictation()
    }

    /// Starts the CGEvent tap(s), prompting for accessibility permission and
    /// polling until it's granted (the tap can't be created without it).
    private func startHotkeyMonitoring() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)

        if startTaps() { return }

        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.startTaps() {
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
            }
        }
    }

    /// Starts the dictation tap, plus the command tap when enabled and not
    /// colliding with the dictation hotkey. Returns true once dictation is live.
    @discardableResult
    private func startTaps() -> Bool {
        let dictationStarted = hotkeyManager.start()
        if settings.commandModeEnabled, !settings.hotkeysCollide {
            commandHotkeyManager.start()
        } else {
            commandHotkeyManager.stop()
        }
        scratchpadHotkey.start() // idempotent; summons the floating notepad (⌥⇧S)
        return dictationStarted
    }

    // MARK: - Dictation Flow

    private func startDictation() {
        // Ignore if already capturing, or already queued waiting for the model.
        guard !appState.isRecording, !appState.isPreparing else { return }

        switch transcriptionService.modelState {
        case .ready:
            beginDictationRecording()
        case .loading, .notLoaded:
            // The speech model is still warming up (typically the first few seconds
            // after launch). Do NOT start the audio engine now: loading the model
            // while the engine later tears down races CoreAudio and crashes. Show a
            // "preparing" pill and begin recording automatically the moment the
            // model is ready (see bindModelReadyAutostart) — so a single press/hold
            // works instead of needing to retry until the model loads.
            if case .notLoaded = transcriptionService.modelState {
                Task { [weak self] in await self?.transcriptionService.warmUp() }
            }
            pendingDictationStart = true
            appState.beginPreparing()
            pillController.show()
        case .downloading, .failed:
            // A first-time model download or a load failure needs the setup window,
            // not a silent queued recording the user could wait on indefinitely.
            hotkeyManager.deactivate()
            showSetupWindowIfNotReady()
        }
    }

    /// Begins the actual audio-capture session. Precondition: the speech model is
    /// `.ready` (the audio engine must never run concurrently with a model load).
    private func beginDictationRecording() {
        guard !appState.isRecording else { return }
        // Resolve context and show the pill FIRST, so visual feedback is instant
        // on key-press; the slower audio-engine start runs right after, in the
        // same tick. If the engine fails to start, tear the pill back down.
        let frontApp = NSWorkspace.shared.frontmostApplication
        sessionBundleID = frontApp?.bundleIdentifier
        sessionMode = resolvedMode(forBundleID: sessionBundleID)
        appState.startRecording(mode: .dictation)
        pillController.show()

        guard audioRecorder.startRecording() else {
            appState.reset()
            pillController.hide()
            hotkeyManager.deactivate()
            return
        }

        recordingStartTime = Date()
        playFeedback(start: true)
        armMaxDurationTimer { [weak self] in self?.finishDictation() }
        escapeInterceptor.start()
    }

    private func finishDictation() {
        // Released while still waiting for the model to load (preparing, not yet
        // recording): cancel the queued start cleanly.
        if pendingDictationStart {
            pendingDictationStart = false
            appState.reset()
            pillController.hide()
            return
        }
        guard appState.isRecording, appState.mode == .dictation else { return }
        maxDurationTimer?.invalidate()
        escapeInterceptor.stop()

        let samples = audioRecorder.stopRecording()
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil
        let bundleID = sessionBundleID
        let targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName

        appState.stopRecording()
        playFeedback(start: false)

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Discard near-silent clips (e.g. an instant key tap) so the model
            // can't hallucinate filler words from nothing.
            guard AudioRecorder.containsSpeech(samples) else {
                self.appState.reset()
                self.pillController.hide()
                return
            }

            do {
                let raw = try await self.transcriptionService.transcribe(samples)

                // Nothing usable (too short, or discarded as low confidence).
                guard !raw.isEmpty else {
                    self.appState.reset()
                    self.pillController.hide()
                    return
                }

                // A spoken edit ("scratch that", "all caps that") acts on the
                // PREVIOUS insertion as its own utterance — never inserted,
                // never run through the pipeline, never written to history.
                if self.settings.voiceEditingEnabled,
                   let command = VoiceEditCommandParser.parse(raw),
                   self.applyVoiceEdit(command) {
                    self.playSuccessFeedback()
                    self.appState.reset()
                    self.pillController.hide()
                    return
                }

                // A spoken app-control command ("switch to email mode", "open
                // scratchpad", "new note") runs as its own utterance — never inserted.
                if self.settings.voiceControlEnabled,
                   let control = VoiceControlCommandParser.parse(raw, modes: self.modeStore.modes) {
                    self.applyVoiceControl(control)
                    self.playSuccessFeedback()
                    self.appState.reset()
                    self.pillController.hide()
                    return
                }

                // The session mode dictates cleanup/formatting; Auto defers to the
                // global settings + per-app tone (byte-identical to no modes).
                let mode = self.sessionMode
                let cleaned = TranscriptPipeline(
                    removeFillers: mode.isAuto ? self.settings.fillerRemovalEnabled : mode.fillerRemoval,
                    formatNumbers: mode.isAuto ? self.settings.numberFormattingEnabled : mode.numberFormatting,
                    formatLists: mode.isAuto ? self.settings.numberedListsEnabled : mode.numberedLists,
                    applyCommands: mode.isAuto ? self.settings.spokenCommandsEnabled : mode.spokenCommands,
                    applyPunctuation: mode.isAuto ? self.settings.spokenPunctuationEnabled : mode.spokenPunctuation
                ).process(raw)
                // Custom-dictionary corrections: rewrite known mishearings
                // (manual + voice-trained aliases) back to the canonical spelling.
                let corrected = self.settings.customDictionaryEnabled
                    ? self.dictionaryReplacer.apply(cleaned)
                    : cleaned
                // A shortcut dictated on its own is canned text — insert it
                // exactly: bypass cleanup/formatting and the leading-space
                // heuristic, so e.g. a signature lands verbatim with no stray
                // space before the first letter.
                let expander = ShortcutExpander(shortcuts: self.shortcutStore.shortcuts)
                if let canned = expander.wholeUtteranceExpansion(for: corrected) {
                    if !canned.isEmpty {
                        try self.textInserter.insert(text: canned, allowLeadingSpace: false)
                        self.playSuccessFeedback()
                        self.history.add(DictationEntry(
                            text: canned, durationSeconds: duration,
                            appName: targetAppName, bundleID: bundleID))
                    }
                    self.appState.setTranscription(canned)
                    self.appState.reset()
                    self.pillController.hide()
                    return
                }

                let expanded = expander.expand(corrected)
                let tone = mode.isAuto ? self.resolvedTone(forBundleID: bundleID) : mode.tone
                let cleanupEnabled = mode.isAuto ? nil : (mode.cleanupEnabledOverride ?? self.settings.cleanupEnabled)
                let text = await self.cleanupCoordinator.cleanup(
                    expanded, tone: tone, backtrack: self.settings.backtrackEnabled,
                    cleanupEnabled: cleanupEnabled
                )
                // If cleanup just ran, the on-device model is loaded — refresh the
                // keep-warm session so it stays resident for the next dictation.
                // Cheap here (no cold load) and safe: the audio engine stopped at
                // the top of finishDictation, so this can't race its teardown.
                if (cleanupEnabled ?? self.settings.cleanupEnabled), tone != .verbatim {
                    self.cleanupCoordinator.prewarm()
                }
                // A cleanup model can reflow a numbered list back onto one line;
                // re-apply list formatting so the structure survives (idempotent,
                // and a no-op when there's no list).
                let listsEnabled = mode.isAuto ? self.settings.numberedListsEnabled : mode.numberedLists
                let relisted = listsEnabled ? SpokenListFormatter.format(text) : text
                // Optionally pipe the result through the user's auto-transform.
                let finalText = await self.applyAutoTransform(to: relisted)

                if !finalText.isEmpty {
                    try self.textInserter.insert(text: finalText)
                    self.playSuccessFeedback()
                    self.history.add(DictationEntry(
                        text: finalText,
                        durationSeconds: duration,
                        appName: targetAppName,
                        bundleID: bundleID
                    ))
                }
                self.appState.setTranscription(finalText)
            } catch {
                self.appState.setError(error)
            }
            self.appState.reset()
            self.pillController.hide()
        }
    }

    /// Applies a spoken edit to the previous insertion. Returns false (so the
    /// caller inserts the words as literal text) when there's nothing to act on
    /// or the caret can no longer be trusted — never a destructive guess.
    private func applyVoiceEdit(_ command: VoiceEditCommand) -> Bool {
        switch command {
        case .deleteLast:
            return textInserter.deleteLastInserted()
        case .deleteLastWord:
            return textInserter.deleteLastWord()
        case .deleteLastSentence:
            return textInserter.deleteLastSentence()
        case .deleteLastLine:
            return textInserter.deleteLastLine()
        case .capitalizeThat, .allCapsThat, .lowercaseThat:
            guard let current = textInserter.lastInsertedText,
                  let rewritten = VoiceEditCommandParser.transform(command, applyingTo: current) else {
                return false
            }
            return textInserter.replaceLastInserted(with: rewritten)
        }
    }

    /// Executes a spoken app-control command (runs on the main actor — the
    /// caller's transcription Task is `@MainActor`).
    private func applyVoiceControl(_ command: VoiceControlCommand) {
        switch command {
        case .switchToMode(let id):
            settings.activeModeID = id.uuidString
        case .selectAutoMode:
            settings.activeModeID = nil
        case .openScratchpad:
            scratchpadController.show()
        case .newNote:
            notesStore.create()
            scratchpadController.show()
        }
    }

    /// The mode in effect for a session: the explicit selection, or an
    /// auto-trigger match for the frontmost app's category, else Auto.
    private func resolvedMode(forBundleID bundleID: String?) -> Mode {
        let category = AppContextClassifier.category(forBundleID: bundleID)
        let activeID = settings.activeModeID.flatMap { UUID(uuidString: $0) }
        let learnedID: UUID? = settings.adaptiveModeEnabled
            ? bundleID.flatMap { settings.appModeOverrides[$0] }.flatMap { UUID(uuidString: $0) }
            : nil
        return ModeResolver.resolve(
            activeID: activeID, learnedModeID: learnedID, in: modeStore.modes, forCategory: category)
    }

    /// Effective cleanup tone for the destination app (Auto = category default).
    private func resolvedTone(forBundleID bundleID: String?) -> ToneStyle {
        guard settings.contextAwareToneEnabled else { return .formal }
        let category = AppContextClassifier.category(forBundleID: bundleID)
        return settings.tone(for: category)
    }

    /// Pipes dictated text through the user's chosen auto-transform, if one is set
    /// and enabled. Falls back to the original text when no transform applies or
    /// the model is unavailable — dictation never breaks.
    private func applyAutoTransform(to text: String) async -> String {
        guard !text.isEmpty,
              let raw = settings.autoTransformID,
              let id = UUID(uuidString: raw),
              let transform = transformStore.transforms.first(where: { $0.id == id }),
              transform.enabled else {
            return text
        }
        let result = await cleanupCoordinator.runTransform(prompt: transform.prompt, text: text)
        return (result?.isEmpty == false) ? result! : text
    }

    private func cancelDictation() {
        maxDurationTimer?.invalidate()
        escapeInterceptor.stop()
        recordingStartTime = nil
        pendingCommandSelection = nil
        pendingDictationStart = false
        audioRecorder.stopRecording()

        appState.reset()
        pillController.hide()
    }

    // MARK: - Command Mode

    private func startCommand() {
        guard !appState.isRecording else { return }
        guard settings.commandModeEnabled, transcriptionService.modelState == .ready else {
            commandHotkeyManager.deactivate()
            return
        }

        // Capture the current selection up front (focus is about to be ours).
        let selection = (try? textInserter.copySelection()) ?? nil
        guard let selection, !selection.isEmpty else {
            // Nothing selected — flash an error state instead of recording.
            commandHotkeyManager.deactivate()
            appState.setError(CommandError.noSelection)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.appState.reset()
            }
            return
        }

        // Selection captured; show the pill before the audio-engine start so it
        // appears immediately. The pill is non-activating, so focus is unaffected.
        pendingCommandSelection = selection
        appState.startRecording(mode: .command)
        pillController.show()

        guard audioRecorder.startRecording() else {
            pendingCommandSelection = nil
            appState.reset()
            pillController.hide()
            commandHotkeyManager.deactivate()
            return
        }

        recordingStartTime = Date()
        playFeedback(start: true)
        armMaxDurationTimer { [weak self] in self?.finishCommand() }
        escapeInterceptor.start()
    }

    private func finishCommand() {
        guard appState.isRecording, appState.mode == .command else { return }
        maxDurationTimer?.invalidate()
        escapeInterceptor.stop()
        recordingStartTime = nil

        let samples = audioRecorder.stopRecording()
        let selection = pendingCommandSelection ?? ""
        pendingCommandSelection = nil

        appState.stopRecording()
        playFeedback(start: false)

        Task { @MainActor [weak self] in
            guard let self else { return }

            // No spoken instruction → leave the selection untouched.
            guard AudioRecorder.containsSpeech(samples) else {
                self.appState.reset()
                self.pillController.hide()
                return
            }

            do {
                let rawInstruction = try await self.transcriptionService.transcribe(samples)
                // Only filler-stripping applies to a spoken instruction —
                // numbers-as-words are fine for the LLM, and a literal line
                // break would corrupt the prompt.
                let instruction = self.settings.fillerRemovalEnabled
                    ? FillerWordRemover.remove(rawInstruction)
                    : rawInstruction
                if let result = await self.cleanupCoordinator.runCommand(instruction: instruction, selection: selection),
                   !result.isEmpty {
                    try self.textInserter.insert(text: result)
                    self.playSuccessFeedback()
                    self.appState.setTranscription(result)
                } else {
                    // LM Studio unavailable or returned nothing — don't destroy
                    // the user's selection; surface a brief error.
                    self.appState.setError(CommandError.unavailable)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                self.appState.setError(error)
            }
            self.appState.reset()
            self.pillController.hide()
        }
    }

    private enum CommandError: LocalizedError {
        case noSelection
        case unavailable

        var errorDescription: String? {
            switch self {
            case .noSelection: return "Select some text first, then use Command Mode."
            case .unavailable: return "Command Mode returned no result. Your text was left unchanged."
            }
        }
    }

    /// Arms the safety timer that force-stops an over-long session.
    private func armMaxDurationTimer(_ stop: @escaping () -> Void) {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.maxRecordingDuration, repeats: false
        ) { [weak self] _ in
            self?.hotkeyManager.deactivate()
            self?.commandHotkeyManager.deactivate()
            stop()
        }
    }

    // MARK: - Audio Feedback

    private func playFeedback(start: Bool) {
        guard settings.audioFeedbackEnabled else { return }
        soundPlayer.play(start ? .recordStart : .recordStop, volume: settings.audioFeedbackVolume)
    }

    /// Quieter confirmation after text lands at the cursor.
    private func playSuccessFeedback() {
        guard settings.audioFeedbackEnabled else { return }
        soundPlayer.play(.success, volume: settings.audioFeedbackVolume * 0.7)
    }

    // MARK: - Model Setup Window

    /// Kicks off model warm-up. Returns true if a download was needed (setup window shown).
    @MainActor
    private func warmUpShowingSetupIfNeeded() async -> Bool {
        async let warmUp: Void = transcriptionService.warmUp()

        // Give the cache check a beat; only show the window for real downloads.
        try? await Task.sleep(nanoseconds: 300_000_000)
        var shown = false
        if case .downloading = transcriptionService.modelState {
            showSetupWindowIfNotReady()
            shown = true
        }
        await warmUp
        return shown
    }

    @MainActor
    private func showSetupWindowIfNotReady() {
        guard transcriptionService.modelState != .ready else { return }
        if setupWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: ModelSetupView(transcriptionService: transcriptionService)
            ))
            window.title = "Yappy"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func closeSetupWindowWhenReady() {
        if transcriptionService.modelState == .ready {
            setupWindow?.orderOut(nil)
            setupWindow = nil
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuBarIcon()

        let menu = NSMenu()
        statusMenu = menu
        menu.addItem(NSMenuItem(title: "Open Yappy", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Scratchpad (⌥⇧S)", action: #selector(toggleScratchpad), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        menu.addItem(modeItem)
        modeMenuItem = modeItem
        rebuildModeMenu()

        let transformsItem = NSMenuItem(title: "Transforms", action: nil, keyEquivalent: "")
        menu.addItem(transformsItem)
        transformsMenuItem = transformsItem
        rebuildTransformsMenu()

        menu.addItem(NSMenuItem.separator())
        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(checkForUpdatesClicked),
                                     keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)
        menu.addItem(NSMenuItem(title: "About Yappy", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Yappy", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Reflect any already-known update state into the menu + icon badge.
        refreshUpdateUI()
    }

    // MARK: - Software Update UI

    /// Menu/badge actions and the gentle-reminder surfacing. The actual install
    /// runs through Sparkle's standard signed dialog (see `UpdateChecker`).

    @objc private func checkForUpdatesClicked() {
        updateChecker.checkForUpdates()
    }

    /// Subscribes to `UpdateChecker.available` so the menu item and icon badge
    /// appear/disappear as Sparkle finds (or stops offering) an update.
    private func bindUpdateChecker() {
        updateChecker.$available
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshUpdateUI() }
            .store(in: &cancellables)
    }

    /// Inserts/removes the highlighted "Update to Yappy X.Y…" item at the top of
    /// the menu and toggles the menu-bar icon's accent dot, based on whether an
    /// update is currently available.
    private func refreshUpdateUI() {
        let release = updateChecker.available
        setUpdateBadge(visible: release != nil)

        guard let menu = statusMenu else { return }
        if let release {
            let title = "Update to Yappy \(release.version)…"
            if let item = updateMenuItem {
                item.title = title
            } else {
                let item = NSMenuItem(title: title,
                                      action: #selector(checkForUpdatesClicked),
                                      keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                     accessibilityDescription: "Update available")
                menu.insertItem(item, at: 0)
                let separator = NSMenuItem.separator()
                menu.insertItem(separator, at: 1)
                updateMenuItem = item
                updateSeparatorItem = separator
            }
        } else {
            if let item = updateMenuItem { menu.removeItem(item) }
            if let separator = updateSeparatorItem { menu.removeItem(separator) }
            updateMenuItem = nil
            updateSeparatorItem = nil
        }
    }

    /// Shows/hides a small blue dot in the top-right corner of the menu-bar button
    /// while an update is pending. Added as a subview so it survives the icon's
    /// state swaps (ready/recording/processing) untouched.
    private func setUpdateBadge(visible: Bool) {
        guard let button = statusItem?.button else { return }
        if visible {
            if updateBadgeView == nil {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
                dot.layer?.cornerRadius = 3.5
                dot.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(dot)
                NSLayoutConstraint.activate([
                    dot.widthAnchor.constraint(equalToConstant: 7),
                    dot.heightAnchor.constraint(equalToConstant: 7),
                    dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                    dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
                ])
                updateBadgeView = dot
            }
            updateBadgeView?.isHidden = false
        } else {
            updateBadgeView?.isHidden = true
        }
    }

    /// Rebuilds the Mode submenu with a checkmark on the active mode. Called when
    /// the mode list or the active selection changes.
    private func rebuildModeMenu() {
        guard let modeMenuItem else { return }
        let submenu = NSMenu()
        let activeID = settings.activeModeID.flatMap { UUID(uuidString: $0) } ?? Mode.autoID
        for mode in modeStore.modes {
            let item = NSMenuItem(title: mode.name, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.representedObject = mode.id.uuidString
            item.state = (mode.id == activeID) ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        modeMenuItem.submenu = submenu
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let isAuto = (raw == Mode.autoID.uuidString)
        // Selecting Auto clears the explicit selection.
        settings.activeModeID = isAuto ? nil : raw
        // Teach the app you were just in this mode, so Auto applies it there later.
        if settings.adaptiveModeEnabled, !isAuto, let bundle = lastActiveBundleID {
            settings.appModeOverrides[bundle] = raw
        }
    }

    /// Rebuilds the Transforms submenu from the enabled transforms.
    private func rebuildTransformsMenu() {
        guard let transformsMenuItem else { return }
        let submenu = NSMenu()
        let enabled = transformStore.enabledTransforms
        if enabled.isEmpty {
            let item = NSMenuItem(title: "No transforms", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        } else {
            for transform in enabled {
                let item = NSMenuItem(
                    title: transform.name,
                    action: #selector(runTransformFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = transform.id.uuidString
                item.target = self
                submenu.addItem(item)
            }
        }
        transformsMenuItem.submenu = submenu
    }

    @objc private func runTransformFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let transform = transformStore.transforms.first(where: { $0.id == id }) else { return }
        Task { @MainActor [weak self] in await self?.runTransform(transform) }
    }

    /// Runs a transform on the current selection in the frontmost app. Captures
    /// the selection after the menu has dismissed (focus returns to the app),
    /// then replaces it with the model's result. Leaves the selection untouched
    /// on any failure, mirroring Command Mode.
    @MainActor
    private func runTransform(_ transform: Transform) async {
        guard !appState.isRecording, !appState.isProcessing else { return }

        // Let the status menu finish dismissing so focus returns to the target app.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let selection = (try? textInserter.copySelection()) ?? nil
        guard let selection, !selection.isEmpty else {
            appState.setError(CommandError.noSelection)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.appState.reset() }
            return
        }

        appState.beginProcessing()
        pillController.show()

        if let result = await cleanupCoordinator.runTransform(prompt: transform.prompt, text: selection),
           !result.isEmpty {
            try? textInserter.insert(text: result)
            playSuccessFeedback()
            appState.setTranscription(result)
        } else {
            appState.setError(CommandError.unavailable)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        appState.reset()
        pillController.hide()
    }

    private func bindStateToMenuBar() {
        Publishers.CombineLatest3(
            appState.$isRecording,
            appState.$isProcessing,
            transcriptionService.$modelState
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            self?.updateMenuBarIcon()
        }
        .store(in: &cancellables)
    }

    /// When a dictation was requested while the speech model was still loading,
    /// start recording automatically the instant the model becomes ready (if the
    /// hotkey is still held). Recording begins only once the model is fully
    /// loaded — never during the load — so the audio engine never races it.
    private func bindModelReadyAutostart() {
        transcriptionService.$modelState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.pendingDictationStart else { return }
                switch state {
                case .ready:
                    self.pendingDictationStart = false
                    self.beginDictationRecording()
                case .failed:
                    self.pendingDictationStart = false
                    self.appState.reset()
                    self.pillController.hide()
                    self.showSetupWindowIfNotReady()
                case .notLoaded, .loading, .downloading:
                    break // keep showing the preparing pill until ready/failed
                }
            }
            .store(in: &cancellables)
    }

    private enum MenuBarGlyph {
        case ready       // outline speech bubble + waveform (template)
        case recording   // solid orange bubble + cutout waveform
        case processing  // filled bubble + cutout waveform (template)
    }

    private func updateMenuBarIcon() {
        if appState.isRecording {
            startMenuBarAnimation()
            return
        }
        stopMenuBarAnimation()

        let image: NSImage
        if appState.isProcessing {
            image = Self.processingIcon
        } else {
            switch transcriptionService.modelState {
            case .ready:
                image = Self.readyIcon
            case .downloading, .loading, .notLoaded:
                image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloading model")
                    ?? Self.readyIcon
                image.isTemplate = true
            case .failed:
                image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: "Model error")
                    ?? Self.readyIcon
                image.isTemplate = true
            }
        }
        statusItem?.button?.image = image
    }

    // MARK: - Menu Bar Recording Animation

    /// Idle/processing menu-bar glyphs, drawn once and reused on every state
    /// change rather than redrawn each time (static lets initialize lazily).
    private static let readyIcon: NSImage = bubbleIcon(.ready)
    private static let processingIcon: NSImage = bubbleIcon(.processing)

    /// Precomputed frames cycling the bubble's bar heights (cheap to swap).
    private static let recordingFrames: [NSImage] = [
        [3.0, 6.0, 3.0],
        [5.0, 4.0, 6.0],
        [6.5, 3.0, 4.5],
        [4.0, 6.5, 5.5],
        [3.0, 5.0, 6.5],
    ].map { bubbleIcon(.recording, barHeights: $0) }

    private func startMenuBarAnimation() {
        guard menuBarAnimationTimer == nil else { return }
        statusItem?.button?.image = Self.recordingFrames[0]
        menuBarFrameIndex = 0
        menuBarAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.menuBarFrameIndex = (self.menuBarFrameIndex + 1) % Self.recordingFrames.count
            self.statusItem?.button?.image = Self.recordingFrames[self.menuBarFrameIndex]
        }
    }

    private func stopMenuBarAnimation() {
        menuBarAnimationTimer?.invalidate()
        menuBarAnimationTimer = nil
    }

    /// Brand orange used for the recording state (the app's accent color).
    private static let brandOrange = NSColor(named: "AccentColor")
        ?? NSColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1.0)

    /// Draws the Yappy speech-bubble glyph for a given state.
    /// Ready/processing are template images (auto light/dark); recording is solid orange.
    /// `barHeights` lets the recording animation vary the waveform.
    private static func bubbleIcon(_ glyph: MenuBarGlyph, barHeights: [CGFloat]? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let bubble = bubblePath()
            let bars = waveformBarPaths(heights: barHeights ?? [3.0, 6.0, 3.0])

            switch glyph {
            case .ready:
                // Filled silhouette (body+tail union) avoids the stroke seam at
                // the tail joint; bars are punched out as holes.
                NSColor.black.setFill()
                bubble.fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                bars.forEach { $0.fill() }

            case .processing:
                // Same shape, dimmed, to read as "working" during the brief
                // processing window (the pill shows the detailed state).
                NSColor.black.withAlphaComponent(0.4).setFill()
                bubble.fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                bars.forEach { $0.fill() }

            case .recording:
                brandOrange.setFill()
                bubble.fill()
                // Solid white bars stay legible on the orange fill (this is a
                // color image, not a template, so the white is preserved).
                NSColor.white.setFill()
                bars.forEach { $0.fill() }
            }
            return true
        }
        image.isTemplate = (glyph != .recording)
        return image
    }

    /// Rounded speech-bubble body with a tail pointing down-left, in an 18×18 box.
    private static func bubblePath() -> NSBezierPath {
        let body = NSBezierPath(
            roundedRect: NSRect(x: 2.5, y: 6.0, width: 13.0, height: 8.5),
            xRadius: 2.8, yRadius: 2.8
        )
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 5.0, y: 6.5))
        tail.line(to: NSPoint(x: 8.6, y: 6.5))
        tail.line(to: NSPoint(x: 5.0, y: 2.5))
        tail.close()
        body.append(tail)
        return body
    }

    /// Three rounded waveform bars centered inside the bubble body.
    private static func waveformBarPaths(heights: [CGFloat] = [3.0, 6.0, 3.0]) -> [NSBezierPath] {
        let centerY: CGFloat = 10.25
        let xs: [CGFloat] = [5.6, 8.2, 10.8]
        return zip(xs, heights).map { x, height in
            // Clamp so animated bars stay inside the bubble body (y 6.0–14.5).
            let clamped = min(max(height, 2.0), 7.5)
            let rect = NSRect(x: x, y: centerY - clamped / 2, width: 1.6, height: clamped)
            return NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8)
        }
    }

    // MARK: - Settings Bindings

    private func bindSettings() {
        settings.$hotkeyOption
            .removeDuplicates()
            .sink { [weak self] option in
                self?.hotkeyManager.updateMode(option)
            }
            .store(in: &cancellables)

        settings.$commandHotkeyOption
            .removeDuplicates()
            .sink { [weak self] option in
                self?.commandHotkeyManager.updateMode(option)
            }
            .store(in: &cancellables)

        // Re-evaluate which taps run when command-mode toggles or a collision
        // is introduced/resolved by changing either hotkey.
        Publishers.CombineLatest3(
            settings.$commandModeEnabled,
            settings.$commandHotkeyOption,
            settings.$hotkeyOption
        )
        .dropFirst()
        .sink { [weak self] _, _, _ in
            self?.startTaps()
        }
        .store(in: &cancellables)


        // Keep the menu-bar Mode submenu in sync with the list and selection.
        modeStore.$modes
            .sink { [weak self] _ in self?.rebuildModeMenu() }
            .store(in: &cancellables)

        // Keep the menu-bar Transforms submenu in sync with the list.
        transformStore.$transforms
            .sink { [weak self] _ in self?.rebuildTransformsMenu() }
            .store(in: &cancellables)

        // Rebuild the precompiled dictionary matcher only when terms change
        // (fires immediately with the current terms, then on every edit).
        dictionaryStore.$terms
            .sink { [weak self] terms in self?.dictionaryReplacer = DictionaryReplacer(terms: terms) }
            .store(in: &cancellables)
        settings.$activeModeID
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuildModeMenu() }
            .store(in: &cancellables)

        settings.$launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .sink { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("Launch-at-login update failed: \(error.localizedDescription)")
                }
            }
            .store(in: &cancellables)

        // Reflect the "check for updates automatically" toggle into Sparkle.
        // dropFirst: the launch code already applies the initial value.
        settings.$autoUpdateChecksEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.updateChecker.automaticallyChecksForUpdates = enabled
            }
            .store(in: &cancellables)

        // Warm up the on-device cleanup model the moment the user enables cleanup
        // or selects Apple Intelligence, so it's "ready to work" without a cold
        // start (self-gates to the on-device backends).
        Publishers.CombineLatest(settings.$cleanupEnabled, settings.$cleanupBackend)
            .dropFirst()
            .removeDuplicates(by: { $0 == $1 })
            .sink { [weak self] _, _ in self?.cleanupCoordinator.prewarm() }
            .store(in: &cancellables)
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if onboardingWindow == nil {
            let levelModel = OnboardingLevelModel()
            onboardingLevelModel = levelModel

            let view = OnboardingView(
                transcriptionService: transcriptionService,
                levelModel: levelModel,
                requestMicrophone: { await AudioRecorder.requestPermission() },
                startLevelPreview: { [weak self] in self?.audioRecorder.startLevelPreview() ?? false },
                stopLevelPreview: { [weak self] in self?.audioRecorder.stopLevelPreview() },
                onFinish: { [weak self] in
                    guard let self else { return }
                    self.audioRecorder.stopLevelPreview()
                    self.onboardingLevelModel = nil
                    self.settings.onboardingComplete = true
                    self.onboardingWindow?.close()
                    self.onboardingWindow = nil
                    self.startTaps()
                }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Yappy"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window & Menu Actions

    private func showMainWindow() {
        mainWindowController.present()
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func toggleScratchpad() {
        scratchpadController.toggle()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
