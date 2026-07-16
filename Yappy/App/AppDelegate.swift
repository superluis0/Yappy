//
//  AppDelegate.swift
//  Yappy
//

import AVFoundation
import Carbon.HIToolbox
import Cocoa
import CoreAudio
import Combine
import os
import QuartzCore
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
    let notesStore = NotesStore()
    let modeStore = ModeStore()
    let transcriptionService = ParakeetTranscriptionService()

    private let audioRecorder = AudioRecorder()
    private let textInserter = TextInserter()
    private let continuationJudge = ContinuationJudge()
    private let soundPlayer = SoundPlayer()
    private let ttsClient = TTSSpeakClient()
    private lazy var cleanupCoordinator = CleanupCoordinator(
        settings: settings, provider: FoundationModelsCleanupProvider())
    private lazy var hotkeyManager = HotkeyManager(mode: settings.hotkeyOption)
    private lazy var escapeInterceptor = EscapeInterceptor()
    private lazy var pillController = RecordingPillController(appState: appState, settings: settings)
    private lazy var scratchpadController = ScratchpadController(store: notesStore)
    private let scratchpadHotkey = ScratchpadHotkey()

    // Ask (hold-Fn voice questions) — experimental, OFF by default. The Fn tap
    // is armed only while askEnabled; until then nothing here touches the network.
    // Grok routes through the warm stdio agent with automatic one-shot fallback
    // (model switch, think-harder, or a cold/wedged warm process).
    let askController = AskController(
        grokClient: GrokClientRouter(warm: GrokAgentClient(), oneShot: GrokAskClient())
    )
    private let askHotkey = AskHotkey()
    private lazy var askPillController = AskPillController(controller: askController, settings: settings)
    /// True while an Ask capture is recording audio (distinct from dictation's
    /// appState.isRecording — Ask drives its own pill via askController).
    private var askRecording = false
    /// True when Fn is held waiting for the speech model to finish loading;
    /// recording auto-starts when it's ready (see bindModelReadyAutostart).
    private var pendingAskStart = false
    private var askGeneration = 0
    private var askProcessingTask: Task<Void, Never>?
    private var askRecordingStartTime: Date?
    private var speakGeneration = 0
    private var speakPipelineTask: Task<Void, Never>?
    private var streamingSpeechQueue: [String] = []
    private var streamingSpeechFinished = false
    private var streamingFirstChunkEver = true
    /// When Fn went down for an Ask — used to log the press→listening latency.
    private var askFnDownAt: Double?
    private var previewGeneration = 0
    private var previewPipelineTask: Task<Void, Never>?
    /// False until the speech (dictation) model finishes its launch load, so the
    /// Answers backend prewarm never competes with it. Flipped true at the end of
    /// the launch model-load Task; setting-toggle sinks warm the backend only after.
    private var readyToPrewarmAsk = false

    /// Precompiled custom-dictionary matcher, rebuilt only when the dictionary
    /// changes (not per dictation). Kept in sync via a `dictionaryStore` sink.
    private var dictionaryReplacer = DictionaryReplacer(terms: [])
    private lazy var mainWindowController = MainWindowController(
        settings: settings,
        history: history,
        shortcutStore: shortcutStore,
        dictionaryStore: dictionaryStore,
        modeStore: modeStore,
        transcriptionService: transcriptionService,
        updateChecker: updateChecker,
        whatsNewPresenter: whatsNewPresenter,
        askController: askController,
        openScratchpad: { [weak self] in self?.openScratchpadFromHome() }
    )

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var modeMenuItem: NSMenuItem?
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
    /// Listen-only global mouse monitor feeding `TextInserter.noteUserInputOccurred()`
    /// — a click moves the caret, so the opaque-app insertion fallbacks must reset.
    private var clickMonitor: Any?
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

    /// Monotonic id for the live dictation session. Bumped when a new recording
    /// actually begins (and when one is cancelled), then captured by
    /// `finishDictation`'s async Task. Every UI/session-outcome mutation in that
    /// Task is gated on the id still being current (see `ifCurrent`), so a slow
    /// transcription/cleanup that finishes AFTER a newer session has started can
    /// never clobber the newer session's pill or state — a defense-in-depth
    /// backstop to the `isProcessing` guard in `startDictation`.
    private var dictationGeneration = 0

    /// The in-flight transcription+cleanup Task spawned by `finishDictation`.
    /// Retained so Escape pressed DURING the processing window (not just while
    /// recording) can cancel it before the text lands (see `escapeCancel`). Set
    /// when the Task starts, cleared in its own `defer` on every exit path.
    private var processingTask: Task<Void, Never>?

    /// Errors on the dictation hot path (transcription/insertion failures). The
    /// user hears the failure cue; this records the cause for `log stream` /
    /// Console triage. Matches the `Logger` convention in the transcription layer.
    private static let logger = Logger(subsystem: "com.yappy.app", category: "dictation")

    /// Bundle id of the app that had focus when the current session started.
    private var sessionBundleID: String?
    /// Most recently activated app other than Yappy — the app you were in when
    /// you pick a mode from the menu bar (used by adaptive per-app modes).
    private var lastActiveBundleID: String?
    /// Mode resolved at the start of the current session.
    private var sessionMode: Mode = .auto

    /// Set when the user "scratch that"-deletes an insertion: the rejected text
    /// plus when it happened. If the *next* dictation lands soon after and is a
    /// near-match, the middle diff is a correction signal that becomes a
    /// suggested dictionary alias. One-shot — consumed by the next insert.
    private var pendingCorrection: (rejected: String, at: Date)?

    /// How fresh a `pendingCorrection` must be to pair with a re-dictation.
    private static let correctionPairingWindow: TimeInterval = 30
    private static let answerSpeakFallbackVoice = AnswersVoice.afHeart.rawValue

    /// The pre-cleanup transcript of the last insertion, when AI cleanup changed
    /// the words — the safety net behind "use what I said". Nil when cleanup
    /// didn't run or didn't change anything. Consumed one-shot: cleared when the
    /// user reverts to it, and when a "scratch that" deletes the last insertion.
    private var lastRawTranscript: String?

    // Dictionary-boosted final via the sliding-window manager.

    // MARK: - Launch

    /// True when the process was launched merely as the XCTest host (via
    /// `xcodebuild test`) rather than as the real app. xcodebuild sets
    /// `XCTestConfigurationFilePath` in the host process's environment. In this
    /// mode the unit tests exercise pure logic and don't need the app's
    /// launch-time warm-ups; skipping them keeps test runs fast and — critically
    /// — avoids loading CoreML models (speech + cleanup) onto the Neural Engine,
    /// whose background compile otherwise races the test bundle's `exit()` and
    /// segfaults in Apple's ANECompiler during teardown.
    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show the Dock icon for the whole time Yappy is running (alongside the
        // menu bar item), not just while the main window is open.
        NSApp.setActivationPolicy(.regular)

        // Select the persisted speech model BEFORE any warm-up runs, so the
        // launch-time load (below) loads the right one. Changes after launch are
        // handled by a sink in bindSettings.
        transcriptionService.activeModel = settings.transcriptionModel

        // Apply the persisted history-retention window up front so the store prunes
        // old entries on its first load. Changes after launch are handled by a sink
        // in bindSettings (mirrors the speech-model pattern above).
        history.retentionDays = settings.historyRetentionDays

        setupMenuBar()
        bindStateToMenuBar()
        bindModelReadyAutostart()
        bindSettings()
        bindAnswerSpeech()

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
            // During an Ask capture the shared engine's levels feed the Ask pill,
            // not the dictation pill.
            if self.askRecording {
                self.askController.pushAudioLevel(Double(level))
                return
            }
            self.appState.updateAudioLevel(level)
            self.onboardingLevelModel?.push(level)
        }

        wireHotkeyCallbacks()
        wireAskCallbacks()

        // Load the speech model in the background; show first-run UI if downloading.
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Under the XCTest host, skip every launch-time model warm-up: the
            // unit tests don't need them, and loading a CoreML model onto the
            // Neural Engine here races the test process's exit() and crashes in
            // ANECompiler during teardown. (See isRunningUnitTests.)
            guard !self.isRunningUnitTests else { return }
            let needsDownload = await self.warmUpShowingSetupIfNeeded()
            if needsDownload {
                self.closeSetupWindowWhenReady()
            }
            // Warm the input HAL: the first AVAudioEngine start of a session pays the
            // microphone hardware's power-up (hundreds of ms to seconds on cold
            // hardware). Run the level-preview engine briefly now -- audio-idle, strictly
            // BETWEEN the speech-model load above and the CTC/cleanup ML loads below,
            // honoring the no-ML-during-audio invariant -- so the user's first press
            // finds the device already warm. startRecording() stops a live preview, so
            // a press during this window degrades gracefully.
            if self.transcriptionService.modelState == .ready,
               !self.appState.isRecording {
                let armStart = CACurrentMediaTime()
                if self.audioRecorder.startLevelPreview() {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    self.audioRecorder.stopLevelPreview()
                    VLog.store("mic prearm engine_warm_ms=\(Int((CACurrentMediaTime() - armStart) * 1000) - 200)")
                }
            }
            // Configure speech-model vocabulary biasing once the model is warm and
            // the audio engine is idle — never on the dictation start/stop path.
            await self.reconfigureVocabularyBoosting()

            // Warm the on-device cleanup model now too, so the first dictation of
            // the session doesn't pay its multi-second cold load. This is safe here
            // for the same reason the CTC load above is: the audio engine is idle at
            // launch, and we sequence this right after that load rather than during
            // any dictation. `prewarm()` self-gates to a no-op when cleanup is off.
            self.cleanupCoordinator.prewarm()

            // Answers backend is warmed LAST — after the speech model and its
            // companions — so the dictation model gets the machine to itself at launch.
            // From here on, setting-toggle sinks warm the backend immediately.
            self.readyToPrewarmAsk = true
            if self.settings.askEnabled {
                self.askController.backend = self.settings.askBackend
                self.askPillController.prewarm()
                self.askController.prewarm()
            }
        }
        // Note: the on-device cleanup model is warmed at launch (above) — audio-idle,
        // right after the speech + CTC models load — so it's resident before the
        // first dictation. It is deliberately NOT warmed during the finishDictation
        // audio-teardown window: warming loads the model on a background thread, and
        // doing that while a dictation's audio engine is being torn down races
        // CoreAudio and crashes. It is otherwise (re)warmed only at other audio-idle
        // moments — when the user enables Apple Intelligence (see bindSettings) and
        // right after a completed cleanup (see finishDictation) — then held resident.

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
        // it instantly instead of paying SwiftUI hosting-view construction. Warm
        // the audio input HAL now too: the first AVAudioEngine input start is
        // otherwise slow (the lag before the waveform appears on the first press).
        // Both are skipped under the XCTest host — the tests don't exercise them,
        // and warming the mic hardware there is pointless and intrusive.
        if !isRunningUnitTests {
            DispatchQueue.main.async { [weak self] in self?.pillController.prewarm() }
            DispatchQueue.main.async { [weak self] in self?.audioRecorder.prewarm() }
        }

        startHotkeyMonitoring()
    }

    @objc private func appDidActivate(_ note: Notification) {
        // Switching apps moves focus somewhere our last-insertion memory knows
        // nothing about — invalidate the opaque-app fallbacks (leading space,
        // voice-edit trust) so they never act on a stale caret.
        textInserter.noteUserInputOccurred()
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
        escapeInterceptor.stop()
        scratchpadHotkey.stop()
        askHotkey.stop()
        askController.shutdown()
        ttsClient.stop()
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

        escapeInterceptor.onEscape = { [weak self] in self?.escapeCancel() }

        scratchpadHotkey.onTrigger = { [weak self] in self?.toggleScratchpad() }

        // Any REAL keystroke after an insertion means the caret may have moved
        // (Enter, arrows, typing) — the opaque-app fallbacks must stop trusting
        // the last insertion. Synthetic events are tag-filtered inside the tap.
        scratchpadHotkey.onUserKeyDown = { [weak self] in
            guard let self else { return }
            self.textInserter.noteUserInputOccurred()
            // A real key while Ask is listening means the Fn press was a keyboard
            // chord (fn+arrow, etc.), not a spoken question — cancel the capture.
            if self.askController.isListening { self.abortAsk() }
        }

        // Mouse clicks move the caret too. A global monitor is listen-only
        // (other apps' clicks; Yappy's own windows don't affect the target
        // caret) and costs nothing beyond this closure.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.textInserter.noteUserInputOccurred()
        }
    }

    /// Esc pressed mid-session. Two cases:
    ///   • While recording/preparing: deactivate the hotkey state machine first so
    ///     the eventual modifier key-up doesn't fire a spurious stop, then cancel.
    ///   • While processing: the audio has already stopped and the transcription
    ///     Task is in flight, so cancel THAT — the Task's cooperative checks then
    ///     drop the result before it's inserted (the "abort before text lands"
    ///     path). The hotkey isn't active during processing, so no deactivate.
    private func escapeCancel() {
        if askController.speakingPhase != .idle {
            stopAnswerSpeech()
            return
        }
        // Ask owns the session — abort its capture / turn (Stop-button equivalent).
        if askController.isBusy {
            askHotkey.deactivate()
            abortAsk()
            return
        }
        if appState.isRecording || appState.isPreparing {
            hotkeyManager.deactivate()
            cancelDictation()
        } else if appState.isProcessing {
            processingTask?.cancel()
        }
    }

    /// Starts the CGEvent tap(s) once Accessibility is trusted, polling silently
    /// until it is. This method NEVER opens System Settings itself — trust is
    /// checked with the non-prompting `AXIsProcessTrusted()`. The app is granted
    /// through its OWN UI instead: onboarding's Accessibility step and Settings ->
    /// Permissions, both user-initiated "Open System Settings" buttons.
    ///
    /// Why silent, not the prompting `AXIsProcessTrustedWithOptions([prompt:true])`:
    /// that call yanks the user into System Settings on EVERY launch of an
    /// untrusted binary. The Debug build (bundle id `com.yappy.app.debug`, ad-hoc
    /// signed, still displayed as "Yappy") is untrusted on *every* rebuild —
    /// ad-hoc signatures key the TCC grant to the per-build code hash, so it can't
    /// persist — so each Build & Run popped Settings and spawned a fresh "Yappy"
    /// row. Checking silently + polling removes that for every build config; the
    /// release install keeps its grant across updates (stable Developer ID), so it
    /// launches already-trusted and starts the taps here with no UI at all.
    private func startHotkeyMonitoring() {
        // Tests never need the hotkey taps and must not touch TCC. `xcodebuild
        // test` launches the debug app as the test host on this same path.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Persisted breadcrumb: whether THIS binary launched already trusted — the
        // definitive read on whether the grant survived an update, from `log show`
        // with no user interaction. Never prompts.
        Self.logger.notice("Launch trust check: AXIsProcessTrusted=\(AXIsProcessTrusted(), privacy: .public)")

        if startTaps() { return }

        // Not trusted yet: poll silently so the taps start the moment the user
        // grants access (via onboarding or Settings) — no relaunch, no nag.
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.startTaps() {
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
            }
        }
    }

    /// Starts the dictation tap (and the always-on scratchpad hotkey). Returns
    /// true once the dictation tap is live.
    @discardableResult
    private func startTaps() -> Bool {
        let dictationStarted = hotkeyManager.start()
        scratchpadHotkey.start() // idempotent; summons the floating notepad (⌥⇧S)
        updateAskHotkeyArming()  // arms the Fn tap only when unlocked && enabled
        return dictationStarted
    }

    // MARK: - Dictation Flow

    private func startDictation() {
        // Ignore if already capturing, already queued waiting for the model, or
        // still transcribing/cleaning the PREVIOUS utterance. `isProcessing` stays
        // true for the whole async Task in `finishDictation` (routinely 1–3s with
        // AI cleanup); starting a second recording during that window would let the
        // first Task's teardown clobber the new session AND run two transcriptions
        // on the shared speech model at once. An ignored press+release is a clean
        // no-op — `finishDictation`'s `guard appState.isRecording` returns early.
        guard !appState.isRecording, !appState.isPreparing, !appState.isProcessing,
              !askController.isBusy else { return }

        // A finished Ask answer may still be lingering (pinned or counting
        // down) at bottom-center — clear it so the two pills never overlap.
        if askController.run != nil { askController.dismiss() }

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
        stopAnswerSpeech()
        guard !appState.isRecording else { return }
        // Resolve context and show the pill FIRST, so visual feedback is instant
        // on key-press; the slower audio-engine start runs right after, in the
        // same tick. If the engine fails to start, tear the pill back down.
        let frontApp = NSWorkspace.shared.frontmostApplication
        sessionBundleID = frontApp?.bundleIdentifier
        sessionMode = resolvedMode(forBundleID: sessionBundleID)
        appState.startRecording()
        pillController.show()

        guard audioRecorder.startRecording() else {
            appState.reset()
            pillController.hide()
            hotkeyManager.deactivate()
            return
        }

        // A new live session has begun: bump the generation so any still-running
        // Task from a prior session can no longer touch this session's UI/state.
        dictationGeneration += 1

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
        guard appState.isRecording else { return }
        maxDurationTimer?.invalidate()
        // NOTE: the Escape interceptor is deliberately NOT stopped here. It stays
        // live through the processing window so Esc can abort the dictation before
        // the text lands (see `escapeCancel`). It's stopped in the Task's `defer`
        // below, on every exit path (including cancellation), gated on the session
        // still being current — leaving it running would swallow Esc system-wide.

        let samples = audioRecorder.stopRecording()
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        // Press-to-resume gap: how long after the previous insertion landed did
        // the user press to start THIS dictation? A tight gap (the finger came
        // straight back down) is a strong continuation signal for the join
        // decision below. nil when there's no prior insertion to resume.
        let resumeGapSeconds: TimeInterval? = recordingStartTime.flatMap { start in
            self.textInserter.lastInsertionAt.map { start.timeIntervalSince($0) }
        }
        recordingStartTime = nil
        let bundleID = sessionBundleID
        let targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName

        appState.stopRecording()
        playFeedback(start: false)

        // Capture the session id NOW; the Task below may finish after a newer
        // session has started (rapid re-dictation, or the max-duration timer
        // firing mid-processing). Every UI/session-outcome mutation is routed
        // through `ifCurrent` so a stale Task can't reset/hide a newer session's
        // pill or overwrite its state. Data operations (insert, history, learned
        // corrections) run unconditionally — the user's words must still land.
        let generation = dictationGeneration

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Tear down this session's cross-cutting processing state on EVERY exit
            // path (success, early return, throw, or cancellation). Both actions are
            // gated on the session still being current: a stale Task that finishes
            // after a newer session began must not stop the newer session's live
            // Escape interceptor (which would swallow Esc system-wide) nor null out
            // the newer session's `processingTask`.
            defer {
                self.ifCurrent(generation) {
                    self.appState.endPolishing()
                    self.escapeInterceptor.stop()
                    self.processingTask = nil
                }
            }

            // Escape pressed the instant the key was released (before transcription
            // even started): abort cleanly without touching the model or the text.
            if Task.isCancelled {
                self.abortProcessing(generation)
                return
            }

            // Discard near-silent clips (e.g. an instant key tap) so the model
            // can't hallucinate filler words from nothing. Notice-level (persisted)
            // breadcrumb: a dictation that vanishes here is otherwise invisible in
            // the logs, which made the device-change-teardown regression hard to
            // diagnose. Counts only — never transcript content.
            guard AudioRecorder.containsSpeech(samples) else {
                Self.logger.notice("Discarded clip without speech (\(samples.count, privacy: .public) samples, \(duration, format: .fixed(precision: 1), privacy: .public)s held; \(AudioRecorder.speechDiagnostics(samples), privacy: .public))")
                // A held-long-enough clip of PURE digital zeros is a device
                // failure the self-heal couldn't fix (hardware mic mute, dead
                // USB input) — never a quiet user; real mics always carry
                // self-noise. Vanishing silently here made a dead mic look
                // like Yappy ignoring the user (login-boot regression,
                // 2026-07-16) — surface it: failure cue + a pill message,
                // briefly, then tear down as usual. Short taps stay silent.
                if duration >= 1.0, AudioRecorder.isDigitalSilence(samples) {
                    self.ifCurrent(generation) {
                        self.playFailureFeedback()
                        self.appState.showFailure("No audio from the mic")
                    }
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                }
                self.ifCurrent(generation) {
                    self.appState.reset()
                    self.pillController.hide()
                }
                return
            }

            // Hoisted so the catch can offer click-to-copy for insertion failures.
            var attemptedInsertText: String?
            do {
                // Warm the cleanup session now — the audio engine has already stopped,
                // so this is audio-idle — so its system-prompt prefill overlaps
                // transcription instead of adding latency to the cleanup that follows.
                self.cleanupCoordinator.prepareSession()
                let raw = try await self.transcriptionService.transcribe(samples)

                // Escape pressed while transcribing: drop the result — nothing has
                // landed yet and the user rejected it.
                if Task.isCancelled {
                    self.abortProcessing(generation)
                    return
                }

                // Nothing usable (too short, or discarded as low confidence).
                // Speech energy was present (passed containsSpeech) but the model
                // produced nothing — soft miss, not a hard error: keep the stop
                // sound only (no failure cue), show a brief caption, then hide.
                guard !raw.isEmpty else {
                    Self.logger.notice("Discarded empty transcript (\(samples.count, privacy: .public) samples, \(duration, format: .fixed(precision: 1), privacy: .public)s held)")
                    self.ifCurrent(generation) {
                        // The dictation is over — release Esc BEFORE the display
                        // hold, or the interceptor swallows Escape system-wide
                        // for the caption's duration with nothing to cancel.
                        self.escapeInterceptor.stop()
                        self.appState.showFailure(Self.emptyTranscriptCaption)
                    }
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    self.ifCurrent(generation) {
                        self.appState.reset()
                        self.pillController.hide()
                    }
                    return
                }

                // A spoken edit ("scratch that", "all caps that") acts on the
                // PREVIOUS insertion as its own utterance — never inserted,
                // never run through the pipeline, never written to history.
                if self.settings.voiceEditingEnabled,
                   let command = VoiceEditCommandParser.parse(raw) {
                    // COMMIT POINT — stop the Escape interceptor BEFORE any
                    // synthetic keystroke. Its consuming tap's callback runs on
                    // THIS main thread; a key event we post while this Task holds
                    // the thread stalls in our own tap until the system drops it —
                    // the paste/edit silently never lands. (Field-diagnosed: every
                    // posted Cmd+V vanished while the interceptor overlapped it.)
                    // Esc-abort still covers transcription + cleanup; from here
                    // we're acting, so aborting is moot. Idempotent; the Task's
                    // defer remains the backstop.
                    self.escapeInterceptor.stop()
                    // The edit itself acts on the user's real prior insertion —
                    // run it regardless of session; only the cue/UI is gated.
                    if self.applyVoiceEdit(command) {
                        self.ifCurrent(generation) {
                            self.playSuccessFeedback()
                            self.appState.reset()
                            self.pillController.hide()
                        }
                        return
                    }
                }

                // A spoken app-control command ("switch to email mode", "open
                // scratchpad", "new note") runs as its own utterance — never inserted.
                if self.settings.voiceControlEnabled,
                   let control = VoiceControlCommandParser.parse(raw, modes: self.modeStore.modes) {
                    // The command is the user's real intent — apply it regardless
                    // of session; only the cue/UI is gated.
                    self.applyVoiceControl(control)
                    self.ifCurrent(generation) {
                        self.playSuccessFeedback()
                        self.appState.reset()
                        self.pillController.hide()
                    }
                    return
                }

                // "Press enter" / "press return" at the end submits after typing:
                // strip the command now (so cleanup never sees it) and remember to
                // send a real Return once the dictated text has landed.
                let submit = SubmitCommandParser.parse(raw)
                let dictation = submit.text
                if dictation.isEmpty {
                    // The whole utterance was just the submit command. The Return
                    // is a real user action (ungated); only the cue/UI is gated.
                    if submit.submit {
                        // Commit point: stop the interceptor before posting Return
                        // (same own-tap stall as the voice-edit branch above).
                        self.escapeInterceptor.stop()
                        self.textInserter.sendReturn()
                    }
                    self.ifCurrent(generation) {
                        if submit.submit { self.playSuccessFeedback() }
                        self.appState.reset()
                        self.pillController.hide()
                    }
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
                ).process(dictation)

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
                        // Record to history BEFORE inserting: if `insert` throws
                        // (accessibility revoked mid-session, event-synthesis
                        // failure) the transcribed text is still preserved rather
                        // than lost. Skip the LOG only (never the insert) when the
                        // user opted out or a secure input field is focused, so a
                        // password dictated into a secure field never lands in the
                        // plaintext history.
                        if self.settings.saveHistoryEnabled, !IsSecureEventInputEnabled() {
                            self.history.add(DictationEntry(
                                text: canned, durationSeconds: duration,
                                appName: targetAppName, bundleID: bundleID))
                        }
                        // Arm click-to-copy recovery for THIS insert too — a
                        // failed canned-shortcut paste is as recoverable as a
                        // failed dictation paste.
                        attemptedInsertText = canned
                        try self.textInserter.insert(text: canned, allowLeadingSpace: false)
                        self.ifCurrent(generation) {
                            self.appState.lastDictationAt = Date()
                            self.playSuccessFeedback()
                        }
                    }
                    if submit.submit { self.textInserter.sendReturn() }
                    self.ifCurrent(generation) {
                        self.appState.setTranscription(canned)
                        self.appState.reset()
                        self.pillController.hide()
                    }
                    return
                }

                let expanded = expander.expand(corrected)

                let tone = mode.isAuto ? self.resolvedTone(forBundleID: bundleID) : mode.tone
                let cleanupEnabled = mode.isAuto ? nil : (mode.cleanupEnabledOverride ?? self.settings.cleanupEnabled)

                // Whether the cleanup call below will actually reshape the words
                // (vs. pass them through). Only then does the pill show the
                // distinct "Polishing" sub-phase — mirrors the keep-warm condition.
                // A secure field (password / secret) must never reach the on-device
                // cleanup model or tone reshaping — paste the pre-cleanup text verbatim.
                // History is already skipped for secure input below; this extends the same
                // protection to model processing. IsSecureEventInputEnabled() is global
                // (true if ANY app holds secure input, e.g. Terminal's Secure Keyboard
                // Entry); erring toward verbatim in a secure context is the safe direction.
                let secureInput = IsSecureEventInputEnabled()
                let willPolish = (cleanupEnabled ?? self.settings.cleanupEnabled) && tone != .verbatim && !secureInput

                // Continuation judge: when the previous insertion ended with a
                // period and this dictation resumed at (presumably) the same
                // caret, ask the on-device model — with BOTH fragments in view —
                // whether the new text continues that sentence. Spawned BEFORE
                // the cleanup await so the two model calls overlap (both run
                // post-audio-teardown, honoring the no-ML-during-audio
                // invariant); adds no wall-clock in the common case. Skipped for
                // secure input and when the deterministic function-word repair
                // will already fire at insert time.
                let continuationTail = secureInput ? nil : self.textInserter.pendingContinuationTail
                var judgeTask: Task<Bool?, Never>?
                if let tail = continuationTail,
                   !ContinuationCasing.endsWithMidSentencePeriod(tail),
                   let firstChar = expanded.first, firstChar.isLetter || firstChar.isNumber {
                    let newText = expanded
                    judgeTask = Task { [weak self] in
                        await self?.continuationJudge.shouldJoin(previousTail: tail, newText: newText) ?? nil
                    }
                }

                let cleanupStartedAt = CACurrentMediaTime()
                let text: String
                if secureInput {
                    text = expanded
                } else {
                    if willPolish { self.ifCurrent(generation) { self.appState.beginPolishing() } }
                    text = await self.cleanupCoordinator.cleanup(
                        expanded, tone: tone, backtrack: self.settings.backtrackEnabled,
                        cleanupEnabled: cleanupEnabled
                    )
                    self.appState.endPolishing()
                }
                let cleanupMs = Int((CACurrentMediaTime() - cleanupStartedAt) * 1000)

                // Escape pressed while polishing: drop the cleaned result before it
                // lands. (Also covers the plain transcribe window when cleanup is off.)
                if Task.isCancelled {
                    self.abortProcessing(generation)
                    return
                }

                // If cleanup just ran, the on-device model is loaded — refresh the
                // keep-warm session so it stays resident for the next dictation.
                // Cheap here (no cold load) and safe: the audio engine stopped at
                // the top of finishDictation, so this can't race its teardown.
                if willPolish {
                    self.cleanupCoordinator.prewarm()
                }
                // A cleanup model can reflow a numbered list back onto one line;
                // re-apply list formatting so the structure survives (idempotent,
                // and a no-op when there's no list).
                let listsEnabled = mode.isAuto ? self.settings.numberedListsEnabled : mode.numberedLists
                let relisted = listsEnabled ? SpokenListFormatter.format(text) : text

                // Refine to the destination field: a single-line or search field
                // (Spotlight, a URL bar, a one-line form input) can't hold line
                // breaks or paragraphs, so flatten dictated structure to one clean
                // line before it lands. Advisory and off the model's path — one
                // cheap AX read of the still-focused field at insert time — and
                // gated behind the existing context-aware toggle. Multi-line and
                // unknown fields keep the text unchanged.
                let classifyStartedAt = CACurrentMediaTime()
                let fieldKind = self.settings.contextAwareToneEnabled
                    ? FocusedFieldClassifier.classifyFocusedField()
                    : .unknown
                let classifyMs = Int((CACurrentMediaTime() - classifyStartedAt) * 1000)
                let finalText = (fieldKind == .singleLine || fieldKind == .search || fieldKind == .secure)
                    ? FocusedFieldClassifier.collapseToSingleLine(relisted)
                    : relisted

                // Privacy-safe classification metric — app identity + enum outcomes ONLY
                // (never the transcript, a URL, or a field label), so the .other/.unknown
                // miss rate is measurable. Analyze: grep dictation-context ~/Library/Logs/Yappy/ask.log
                VLog.store("dictation-context bundle=\(bundleID ?? "?") category=\(AppContextClassifier.category(forBundleID: bundleID)) field=\(fieldKind) contextAware=\(self.settings.contextAwareToneEnabled ? "on" : "off")")

                // The pre-cleanup words, kept only when cleanup actually changed
                // them — the raw transcript we can reveal in history and revert to
                // by voice ("use what I said"). Nil otherwise, so we never claim a
                // safety net that would just re-insert the identical text.
                let rawTranscript = (expanded != finalText) ? expanded : nil

                // Last gate before the words land: Escape pressed anytime up to
                // here rejects the dictation outright — no history.add, no insert.
                // This is the point the abort MUST catch to honor "before text
                // lands"; the earlier checks just avoid doing needless work.
                if Task.isCancelled {
                    self.abortProcessing(generation)
                    return
                }

                // COMMIT POINT — stop the Escape interceptor BEFORE the paste.
                // Its consuming tap's callback runs on THIS main thread; the
                // synthetic Cmd+V we're about to post would route through our own
                // tap and stall there (the thread is busy inside the insert call)
                // until the system drops it — the dictation transcribes, hits
                // history, and silently never appears. Field-diagnosed via the
                // insertion breadcrumbs ("Cmd+V posted" ... "NEVER CONFIRMED").
                // Esc-abort has covered transcription + cleanup up to this line;
                // past it we're committed. Idempotent; the defer is the backstop.
                self.escapeInterceptor.stop()

                // Resolve the continuation decision, strongest signal first:
                // 1. Lowercase start — the ASR/cleanup itself declined to
                //    sentence-case the resume, which only happens mid-sentence.
                // 2. Prosody — the PREVIOUS dictation's raw transcript had no
                //    terminal punctuation (the speaker audibly trailed off; the
                //    period at the caret was appended by the cleanup model).
                //    Guarded against short standalone replies on either side:
                //    the previous text must be ≥3 words ("Yep" doesn't trail
                //    off) and the resume must not open as a reply/pivot
                //    ("Nope, …" answers; it doesn't continue).
                // 3. The on-device judge — semantic tie-breaker, trusted only
                //    on a tight press-to-resume gap (the finger came straight
                //    back down) and bounded by a hard timeout.
                // Anything else → today's deterministic behavior (the
                // function-word repair still applies at insert time).
                var joinContinuation = false
                var joinReason = "none"
                if let tail = continuationTail, let firstChar = finalText.first {
                    if firstChar.isLowercase {
                        joinContinuation = true
                        joinReason = "lowercase"
                    } else if self.textInserter.lastInsertionRawEndedMidThought,
                              tail.split(whereSeparator: { $0.isWhitespace }).count >= 3,
                              !ContinuationCasing.startsAsStandaloneReply(finalText) {
                        joinContinuation = true
                        joinReason = "prosody"
                    } else if let task = judgeTask,
                              let gap = resumeGapSeconds, gap < 1.8 {
                        let judgeWaitStartedAt = CACurrentMediaTime()
                        let verdict = await self.awaitContinuationVerdict(task)
                        joinContinuation = verdict ?? false
                        joinReason = verdict.map { $0 ? "judge-join" : "judge-new" } ?? "judge-abstain"
                        // Privacy-safe: verdict + timing only, never the text.
                        VLog.store("continuation-judge verdict=\(joinReason) wait_ms=\(Int((CACurrentMediaTime() - judgeWaitStartedAt) * 1000))")
                    }
                    VLog.store("continuation-decide reason=\(joinReason) gap_ms=\(resumeGapSeconds.map { Int($0 * 1000) } ?? -1)")
                }

                // `attemptedInsertText` is set just before insert so a failed
                // paste can surface click-to-copy recovery (text is already in history).
                if !finalText.isEmpty {
                    // Record to history BEFORE inserting so a failed insert
                    // (accessibility revoked mid-session, event-synthesis failure)
                    // never loses the transcript. Skip the LOG only (never the
                    // insert) when the user opted out or a secure input field is
                    // focused, so a password dictated into a secure field never
                    // lands in the plaintext history.
                    if self.settings.saveHistoryEnabled, !IsSecureEventInputEnabled() {
                        self.history.add(DictationEntry(
                            text: finalText,
                            durationSeconds: duration,
                            appName: targetAppName,
                            bundleID: bundleID,
                            rawTranscript: rawTranscript
                        ))
                    }
                    // Arm the "use what I said" safety net for the insertion that's
                    // about to land (whether or not history logging was skipped).
                    self.lastRawTranscript = rawTranscript
                    // Prosody memory for the NEXT dictation's join decision:
                    // did THIS dictation's pre-cleanup transcript end without
                    // terminal punctuation (the speaker trailed off)? Computed
                    // on `expanded` so a spoken "period" — deliberate finality —
                    // counts as terminal even before the cleanup model runs.
                    let trimmedExpanded = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawEndedMidThought = trimmedExpanded.last.map { !".!?…".contains($0) } ?? false
                    let insertStartedAt = CACurrentMediaTime()
                    attemptedInsertText = finalText
                    try self.textInserter.insert(text: finalText,
                                                 joinContinuation: joinContinuation,
                                                 rawEndedMidThought: rawEndedMidThought)
                    let insertMs = Int((CACurrentMediaTime() - insertStartedAt) * 1000)
                    // Phase-A latency telemetry: stage timings + input size, ints/enums ONLY
                    // (never the transcript). Analyze: grep insert-timing ~/Library/Logs/Yappy/ask.log
                    VLog.store("insert-timing cleanup_ms=\(cleanupMs) classify_ms=\(classifyMs) insert_ms=\(insertMs) words=\(expanded.split(whereSeparator: { $0.isWhitespace }).count) field=\(fieldKind) secure=\(secureInput ? 1 : 0)")
                    self.ifCurrent(generation) {
                        self.appState.lastDictationAt = Date()
                        self.playSuccessFeedback()
                    }
                    // Learn from a "scratch that" + re-dictation: if the just-
                    // rejected text is fresh, mine the diff and file each pair as
                    // a *suggested* alias (never auto-applied).
                    self.captureCorrectionIfPending(redictated: finalText)
                }
                if submit.submit { self.textInserter.sendReturn() }
                self.ifCurrent(generation) { self.appState.setTranscription(finalText) }
            } catch {
                // Transcription or insertion failed. The transcript (if any) is
                // already in history — surface a reason on the pill, and for
                // recoverable insertion failures offer one-click copy.
                Self.logger.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                let baseCaption = Self.dictationFailureCaption(for: error)
                let recoveryText = Self.isRecoverableInsertionFailure(error)
                    ? attemptedInsertText
                    : nil
                // Click-to-copy only when we actually have the failed text.
                let displayCaption = recoveryText != nil
                    ? Self.insertFailureClickToCopyCaption
                    : baseCaption
                let holdNs: UInt64 = recoveryText != nil
                    ? 6_000_000_000
                    : 2_500_000_000
                self.ifCurrent(generation) {
                    // The dictation is over — release Esc BEFORE the display
                    // hold (2.5–6 s), or the interceptor swallows Escape
                    // system-wide with nothing left to cancel.
                    self.escapeInterceptor.stop()
                    self.playFailureFeedback()
                    self.appState.setError(error)
                    self.appState.showFailure(displayCaption, recoveryText: recoveryText)
                    if recoveryText != nil {
                        self.pillController.setInteractive(true)
                    }
                }
                if recoveryText != nil {
                    await self.waitForFailureRecoveryOrTimeout(
                        generation: generation,
                        timeoutNanoseconds: holdNs
                    )
                } else {
                    try? await Task.sleep(nanoseconds: holdNs)
                }
            }
            self.ifCurrent(generation) {
                self.pillController.setInteractive(false)
                self.appState.reset()
                self.pillController.hide()
            }
        }
    }

    /// Caption shown when speech energy was present but transcription produced
    /// nothing usable. Soft miss — no failure sound.
    nonisolated static let emptyTranscriptCaption = "Didn't catch that"

    /// Caption for recoverable insertion failures (click-to-copy affordance).
    nonisolated static let insertFailureClickToCopyCaption = "Couldn't insert — click to copy"

    /// Maps a dictation-path error to a short pill caption. Pure / unit-testable.
    /// `nonisolated` so unit tests can call it without hopping to MainActor.
    nonisolated static func dictationFailureCaption(for error: Error) -> String {
        if let insertion = error as? TextInserter.InsertionError {
            switch insertion {
            case .accessibilityPermissionDenied:
                return "Enable Accessibility to insert"
            case .eventCreationFailed:
                return "Couldn't insert — saved to History"
            }
        }
        return "Transcription failed — try again"
    }

    /// True when the failure is an insertion problem that still has the text in
    /// History — not accessibility-denied (that needs a Settings fix first).
    nonisolated static func isRecoverableInsertionFailure(_ error: Error) -> Bool {
        guard let insertion = error as? TextInserter.InsertionError else { return false }
        if case .accessibilityPermissionDenied = insertion { return false }
        return true
    }

    /// Holds the recovery-class failure pill until the user clicks to copy, or
    /// `timeoutNanoseconds` elapses. After a successful copy, shows "Copied"
    /// for 0.8s before returning so the caller can tear down.
    private func waitForFailureRecoveryOrTimeout(
        generation: Int,
        timeoutNanoseconds: UInt64
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if generation != dictationGeneration { return }
            if appState.failureRecoveryCopied {
                try? await Task.sleep(nanoseconds: 800_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Tears down the UI after the processing Task was cancelled (Escape pressed
    /// during the processing window). No text was inserted and nothing is written
    /// to history — the user rejected this dictation, so it's a clean discard, not
    /// an error: play the soft record-stop cue (never the failure cue) and, only if
    /// this is still the live session, clear state and hide the pill. The Task's
    /// `defer` separately stops the Escape interceptor and clears `processingTask`.
    private func abortProcessing(_ generation: Int) {
        playFeedback(start: false)
        ifCurrent(generation) {
            appState.reset()
            pillController.hide()
        }
    }

    /// Awaits the continuation judge's verdict, bounded so a slow model call can
    /// never delay the insert: returns nil (deterministic fallback) on timeout.
    /// The judge task was spawned before the cleanup await, so by the time this
    /// runs it has usually already finished — the timeout is a backstop.
    private func awaitContinuationVerdict(_ task: Task<Bool?, Never>,
                                          timeoutNanoseconds: UInt64 = 1_500_000_000) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Runs `work` only if `generation` is still the live dictation session.
    /// Guards every UI/session-outcome mutation inside `finishDictation`'s async
    /// Task, so a Task that completes after a newer session has begun can't reset
    /// or overwrite the newer session's pill/state. Data operations (text
    /// insertion, history, learned corrections) deliberately bypass this — the
    /// user's spoken words must land even if the session they came from is stale.
    private func ifCurrent(_ generation: Int, _ work: () -> Void) {
        guard generation == dictationGeneration else { return }
        work()
    }

    /// Applies a spoken edit to the previous insertion. Returns false (so the
    /// caller inserts the words as literal text) when there's nothing to act on
    /// or the caret can no longer be trusted — never a destructive guess.
    private func applyVoiceEdit(_ command: VoiceEditCommand) -> Bool {
        switch command {
        case .deleteLast:
            // Capture the rejected text BEFORE deleting (the delete clears
            // `lastInsertedText`). If the next dictation is a near-match, their
            // diff becomes a suggested alias. Only arm it when the delete
            // actually happened, so a no-op "scratch that" leaves no stale signal.
            let rejected = textInserter.lastInsertedText
            let deleted = textInserter.deleteLastInserted()
            if deleted, let rejected, !rejected.isEmpty {
                pendingCorrection = (rejected: rejected, at: Date())
            } else {
                pendingCorrection = nil
            }
            // The insertion the raw transcript backed is gone; drop the safety net
            // so "use what I said" can't revert to a now-deleted insertion.
            if deleted { lastRawTranscript = nil }
            return deleted
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
        case .useRawTranscript:
            // Reveal the raw words the AI cleanup rewrote. Only when we have a
            // pre-cleanup transcript AND swapping it in succeeds; then consume it
            // (the inserted text IS now the raw). On failure return false so the
            // words fall through and insert as literal text.
            guard let raw = lastRawTranscript,
                  textInserter.replaceLastInserted(with: raw) else {
                return false
            }
            lastRawTranscript = nil
            return true
        }
    }

    /// If a "scratch that" left a fresh rejected phrase, diff it against the text
    /// just re-dictated and file any tight substitution as a suggested dictionary
    /// alias. Consumed one-shot: `pendingCorrection` is cleared whether or not a
    /// pair was found, so a single scratch never seeds more than one re-dictation.
    private func captureCorrectionIfPending(redictated: String) {
        defer { pendingCorrection = nil }
        guard let pending = pendingCorrection,
              Date().timeIntervalSince(pending.at) <= Self.correctionPairingWindow else {
            return
        }
        for pair in AliasMiner.correctionPairs(rejected: pending.rejected, redictated: redictated) {
            dictionaryStore.addSuggestion(heard: pair.heard, corrected: pair.corrected)
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
            showScratchpad()
        case .newNote:
            notesStore.create()
            showScratchpad()
        }
    }

    // MARK: - Home getting-started checklist hooks
    //
    // These flip the persisted `Settings` flags that back the Home checklist so
    // it reflects "ever did this", independent of current state. Each is set at
    // the single point an action funnels through, and each writes at most once.

    /// Shows the Scratchpad and records that it has been opened at least once.
    /// All in-app open paths funnel through here so the checklist stays accurate.
    private func showScratchpad() {
        scratchpadController.show()
        if !settings.hasOpenedScratchpad { settings.hasOpenedScratchpad = true }
    }

    /// Marks the "try a mode" checklist item once a non-Auto Mode becomes active,
    /// regardless of how it was selected (menu bar, voice command, or the Modes
    /// tab) — they all publish through `settings.activeModeID`.
    private func markModeTriedIfNeeded(_ activeModeID: String?) {
        guard !settings.hasTriedMode,
              let activeModeID,
              activeModeID != Mode.autoID.uuidString else { return }
        settings.hasTriedMode = true
    }

    /// Onboarding-seeded dictionary terms (per use case), which are added with
    /// `isBuiltIn == false` just like a hand-entered term. The checklist's "add a
    /// dictionary term" item should count only genuine user additions, so these
    /// are excluded. Derived from the seed source so it can't drift.
    private static let onboardingSeededTerms: Set<String> = Set(
        UseCase.allCases
            .flatMap { dictionaryTerms(for: $0) }
            .map { $0.lowercased() }
    )

    /// Marks the "add a dictionary term" checklist item once the user has a term
    /// of their own — i.e. a non-built-in term that wasn't seeded by onboarding.
    private func markDictionaryTermAddedIfNeeded(_ terms: [DictionaryTerm]) {
        guard !settings.hasAddedDictionaryTerm else { return }
        let hasUserTerm = terms.contains { term in
            !term.isBuiltIn && !Self.onboardingSeededTerms.contains(term.text.lowercased())
        }
        if hasUserTerm { settings.hasAddedDictionaryTerm = true }
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

    private func cancelDictation() {
        maxDurationTimer?.invalidate()
        escapeInterceptor.stop()
        recordingStartTime = nil
        pendingDictationStart = false
        audioRecorder.stopRecording()

        // End this session definitively: bump the generation so a transcription
        // Task still in flight (Escape pressed after key-up handed off) can't
        // reset/hide the pill or resurface state after this clean teardown.
        dictationGeneration += 1

        appState.reset()
        pillController.hide()
    }

    // MARK: - Answer Speech

    private func bindAnswerSpeech() {
        ttsClient.onPhaseChange = { [weak self] phase in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only reflect the helper's load phase while a real speak or
                // preview is running. A background prewarm (fired on Fn-down while
                // the user is still asking) must NOT look like in-flight speech —
                // otherwise stopAnswerSpeech would read `.synthesizing` and tear
                // down the very helper the prewarm just spent ~1.7s warming.
                guard self.speakPipelineTask != nil || self.previewPipelineTask != nil else { return }
                if phase == "loading" || phase == "downloading" {
                    self.askController.setSpeakingPhase(.synthesizing)
                }
            }
        }
        updateAnswerSpeakAvailability()
        askController.autoSpeak = settings.answersAutoSpeak
        Task { @MainActor [weak self] in
            _ = await TTSSpeakClient.probeReadiness()
            self?.updateAnswerSpeakAvailability()
        }
    }

    private func updateAnswerSpeakAvailability() {
        askController.speakAvailable = settings.answersSpeakEnabled && (TTSSpeakClient.cachedReady ?? false)
        // If the feature is on but readiness is still unknown (the probe hasn't
        // resolved, or Settings ran it on another path), probe once and recompute
        // so the Speak button reliably appears without waiting for a relaunch.
        if settings.answersSpeakEnabled, TTSSpeakClient.cachedReady == nil {
            Task { @MainActor [weak self] in
                _ = await TTSSpeakClient.probeReadiness()
                self?.recomputeSpeakAvailable()
            }
        }
    }

    private func recomputeSpeakAvailable() {
        askController.speakAvailable = settings.answersSpeakEnabled && (TTSSpeakClient.cachedReady ?? false)
    }

    /// Decides how much leading silence to prepend to the first TTS chunk.
    /// Bluetooth and any output route we can't positively identify as built-in
    /// ALWAYS get the full pad — their wake-up/route-switch behavior can't be
    /// verified, so this stays maximally conservative. Only built-in output
    /// hardware with recent playback activity (within a conservative 10s
    /// idle-power-down bound) gets the short pad.
    nonisolated static func firstChunkPadMs(isBuiltInOutput: Bool, secondsSinceLastOutput: Double?) -> Int {
        if isBuiltInOutput, let seconds = secondsSinceLastOutput, seconds < 10 {
            return 80
        }
        return 280
    }

    nonisolated static func defaultOutputIsBuiltIn() -> Bool {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return false }

        var transportType = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transportType
        )
        guard status == noErr, transportSize == UInt32(MemoryLayout<UInt32>.size) else { return false }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    private func speakAnswerText(_ raw: String) {
        let speechRequestedAt = CACurrentMediaTime()
        stopAnswerSpeech()
        speakGeneration += 1
        let generation = speakGeneration

        askController.setSpeakingPhase(.synthesizing)
        let text = AskAnswerBlock.speakableText(from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            askController.setSpeakingPhase(.idle)
            return
        }

        // Small first chunk → first audio in ~1s; larger chunks after keep the
        // stream gapless while they render during playback.
        let chunks = AskController.speechChunks(text, firstLimit: 90)
        guard !chunks.isEmpty else {
            askController.setSpeakingPhase(.idle)
            return
        }

        // Decide the pad before warming: warmOutputDevice() stamps lastPlaybackAt.
        let firstPadMs = Self.firstChunkPadMs(
            isBuiltInOutput: Self.defaultOutputIsBuiltIn(),
            secondsSinceLastOutput: soundPlayer.lastPlaybackAt.map { -$0.timeIntervalSinceNow }
        )
        soundPlayer.warmOutputDevice()

        speakPipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var chunkIndex = 0
            do {
                let firstSynthesisStartedAt = CACurrentMediaTime()
                var pending = try await self.synthesizeAndPrepareAnswerChunk(chunks[0], padStartMs: firstPadMs)
                let firstSynthesisMs = Int((CACurrentMediaTime() - firstSynthesisStartedAt) * 1_000)
                var completedNaturally = true

                for index in chunks.indices {
                    guard self.speakGeneration == generation, !Task.isCancelled else {
                        completedNaturally = false
                        break
                    }

                    // A nil `pending` is a SKIPPED chunk (empty/failed input),
                    // not a pipeline failure: keep going with the next one.
                    if index + 1 < chunks.count {
                        // async let keeps synthesis+decode on a child task so WAV decode
                        // overlaps current playback instead of at the gapless seam.
                        async let nextPrepared = self.synthesizeAndPrepareAnswerChunk(chunks[index + 1])
                        if let sound = pending {
                            self.askController.setSpeakingPhase(.speaking)
                            if index == chunks.startIndex {
                                let totalMs = Int((CACurrentMediaTime() - speechRequestedAt) * 1_000)
                                VLog.tts("first-audio path=manual synth_ms=\(firstSynthesisMs) pad_ms=\(firstPadMs) total_ms=\(totalMs)")
                            }
                            let finished = await self.playPreparedAndWait(sound, generation: generation)
                            guard finished, self.speakGeneration == generation, !Task.isCancelled else {
                                completedNaturally = false
                                break
                            }
                        }
                        chunkIndex = index + 1
                        pending = try await nextPrepared
                    } else if let sound = pending {
                        self.askController.setSpeakingPhase(.speaking)
                        if index == chunks.startIndex {
                            let totalMs = Int((CACurrentMediaTime() - speechRequestedAt) * 1_000)
                            VLog.tts("first-audio path=manual synth_ms=\(firstSynthesisMs) pad_ms=\(firstPadMs) total_ms=\(totalMs)")
                        }
                        let finished = await self.playPreparedAndWait(sound, generation: generation)
                        guard finished, self.speakGeneration == generation, !Task.isCancelled else {
                            completedNaturally = false
                            break
                        }
                    }
                }

                if completedNaturally, self.speakGeneration == generation, !Task.isCancelled {
                    self.askController.setSpeakingPhase(.idle)
                    self.ttsClient.noteIdle()
                    self.speakPipelineTask = nil
                }
            } catch {
                if self.speakGeneration == generation {
                    self.askController.setSpeakingPhase(.idle)
                    self.askController.showSpeakFailureCaption()
                    VLog.tts("pipeline failed (chunk \(chunkIndex))")
                    self.ttsClient.noteIdle()
                    self.speakPipelineTask = nil
                }
            }
        }
    }

    /// Synthesizes and decodes one speech chunk. `nil` means SKIP this chunk
    /// and keep the pipeline going: the chunk normalized to nothing speakable
    /// (e.g. pure markdown residue — the helper errors on empty input), the
    /// helper rejected this specific input, or the WAV failed to decode. One
    /// lost chunk must never silence the rest of the answer (field bug: a
    /// single failed chunk used to kill everything after it). Throws only for
    /// pipeline-fatal failures — the helper process gone or torn down by a
    /// timeout — where continuing chunk-by-chunk cannot succeed.
    private func synthesizeAndPrepareAnswerChunk(_ chunk: String, padStartMs: Int = 0) async throws -> NSSound? {
        let voice = AnswersVoice(rawValue: settings.answersVoice)?.rawValue ?? Self.answerSpeakFallbackVoice
        let normalized = TTSTextNormalizer.normalize(chunk)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            VLog.tts("chunk skipped — empty after normalization")
            return nil
        }
        do {
            let url = try await ttsClient.synthesize(
                text: normalized,
                voice: voice,
                speed: settings.answersVoiceSpeed.multiplier,
                padStartMs: padStartMs
            )
            return soundPlayer.prepareFile(url: url)
        } catch TTSSpeakClient.ClientError.synthesis {
            VLog.tts("chunk skipped — synthesis failed for this input")
            return nil
        }
    }

    private func playPreparedAndWait(_ sound: NSSound, generation: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            soundPlayer.playPrepared(sound, volume: settings.audioFeedbackVolume) { [weak self] finished in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: finished && self.speakGeneration == generation)
            }
        }
    }

    // MARK: - Voice preview (Settings)

    /// Speaks a short sample in `voice` so the user can hear it before choosing.
    /// Reuses the shared TTS helper + player; any answer speech or prior preview
    /// is stopped first (one voice at a time).
    private func playVoicePreview(_ voice: String) {
        stopAnswerSpeech()
        // Only ever hand the helper a known Kokoro voice id. mlx-audio's voice
        // loader falls back to a network fetch for an unknown id (pipeline.py
        // drops local_files_only), which would break the on-device guarantee;
        // the answer-speech path guards the same way, so keep the two in lockstep.
        guard let resolved = AnswersVoice(rawValue: voice) else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let sample = "Hi, I'm \(resolved.spokenName). This is how I read your answers."
        askController.previewingVoice = voice

        previewPipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.previewGeneration == generation {
                    self.askController.previewingVoice = nil
                    self.ttsClient.noteIdle()
                    self.previewPipelineTask = nil
                }
            }
            do {
                // The preview demos the speed the answers will actually use.
                let url = try await self.ttsClient.synthesize(
                    text: sample,
                    voice: resolved.rawValue,
                    speed: self.settings.answersVoiceSpeed.multiplier,
                    padStartMs: 280
                )
                guard self.previewGeneration == generation, !Task.isCancelled else { return }
                _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    self.soundPlayer.playFile(url: url, volume: self.settings.audioFeedbackVolume) { finished in
                        continuation.resume(returning: finished)
                    }
                }
            } catch {
                if self.previewGeneration == generation { VLog.tts("voice preview failed") }
            }
        }
    }

    private func stopVoicePreview() {
        previewGeneration += 1
        previewPipelineTask?.cancel()
        previewPipelineTask = nil
        if askController.previewingVoice != nil {
            soundPlayer.stopFile()
            askController.previewingVoice = nil
            ttsClient.noteIdle()
        }
    }

    private func handleStreamingSpeechText(_ newText: String, isStart: Bool) {
        if isStart {
            let speechRequestedAt = CACurrentMediaTime()
            stopAnswerSpeech()
            speakGeneration += 1
            let generation = speakGeneration
            askController.setSpeakingPhase(.synthesizing)
            streamingSpeechQueue = []
            streamingSpeechFinished = false
            streamingFirstChunkEver = true
            streamingSpeechQueue.append(newText)
            speakPipelineTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Every exit — natural drain, playback interruption, synth
                // failure — must restore idle when this task still owns the
                // phase; otherwise a mid-stream failure strands the pill on the
                // synthesizing spinner. (A stop/barge-in bumps the generation
                // and restores idle itself.)
                defer {
                    if self.speakGeneration == generation, !Task.isCancelled {
                        self.askController.setSpeakingPhase(.idle)
                        self.ttsClient.noteIdle()
                        self.speakPipelineTask = nil
                    }
                }
                while self.speakGeneration == generation, !Task.isCancelled {
                    if !self.streamingSpeechQueue.isEmpty {
                        let combined = self.streamingSpeechQueue.joined()
                        self.streamingSpeechQueue.removeAll()
                        let firstLimit = self.streamingFirstChunkEver ? 90 : 280
                        let chunks = AskController.speechChunks(combined, firstLimit: firstLimit)
                        guard !chunks.isEmpty else { continue }

                        let batchStartsSpeech = self.streamingFirstChunkEver
                        let firstPadMs = batchStartsSpeech
                            ? Self.firstChunkPadMs(
                                isBuiltInOutput: Self.defaultOutputIsBuiltIn(),
                                secondsSinceLastOutput: self.soundPlayer.lastPlaybackAt.map { -$0.timeIntervalSinceNow }
                              )
                            : 0
                        self.streamingFirstChunkEver = false
                        let firstSynthesisStartedAt = CACurrentMediaTime()
                        do {
                            var pending = try await self.synthesizeAndPrepareAnswerChunk(chunks[0], padStartMs: firstPadMs)
                            let firstSynthesisMs = Int((CACurrentMediaTime() - firstSynthesisStartedAt) * 1_000)

                            for index in chunks.indices {
                                guard self.speakGeneration == generation, !Task.isCancelled else { return }

                                // A nil `pending` is a SKIPPED chunk (empty or
                                // failed input), not a pipeline failure: keep
                                // going with the next one.
                                if index + 1 < chunks.count {
                                    async let nextPrepared = self.synthesizeAndPrepareAnswerChunk(chunks[index + 1])
                                    if let sound = pending {
                                        self.askController.setSpeakingPhase(.speaking)
                                        if batchStartsSpeech, index == chunks.startIndex {
                                            let totalMs = Int((CACurrentMediaTime() - speechRequestedAt) * 1_000)
                                            VLog.tts("first-audio path=stream synth_ms=\(firstSynthesisMs) pad_ms=\(firstPadMs) total_ms=\(totalMs)")
                                        }
                                        let finished = await self.playPreparedAndWait(sound, generation: generation)
                                        guard finished, self.speakGeneration == generation, !Task.isCancelled else { return }
                                    }
                                    pending = try await nextPrepared
                                } else if let sound = pending {
                                    self.askController.setSpeakingPhase(.speaking)
                                    if batchStartsSpeech, index == chunks.startIndex {
                                        let totalMs = Int((CACurrentMediaTime() - speechRequestedAt) * 1_000)
                                        VLog.tts("first-audio path=stream synth_ms=\(firstSynthesisMs) pad_ms=\(firstPadMs) total_ms=\(totalMs)")
                                    }
                                    let finished = await self.playPreparedAndWait(sound, generation: generation)
                                    guard finished, self.speakGeneration == generation, !Task.isCancelled else { return }
                                }
                            }
                        } catch {
                            if self.speakGeneration == generation { VLog.tts("streaming pipeline failed") }
                            return
                        }
                        self.askController.setSpeakingPhase(.synthesizing)
                    } else if !self.streamingSpeechFinished {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    } else {
                        break
                    }
                }
            }
        } else {
            streamingSpeechQueue.append(newText)
        }
    }

    private func handleStreamingSpeechFinish() {
        streamingSpeechFinished = true
    }

    private func stopAnswerSpeech() {
        // Was there actually speech in flight (synthesizing or playing), or is
        // this a no-op stop over a warm-but-idle helper (e.g. one a prewarm just
        // warmed)? Only real in-flight speech justifies tearing the helper down.
        let hadActiveSpeech = speakPipelineTask != nil || previewPipelineTask != nil
        speakGeneration += 1
        speakPipelineTask?.cancel()
        speakPipelineTask = nil
        streamingSpeechQueue = []
        streamingSpeechFinished = false
        // A voice preview shares the one player + helper; stop it too.
        previewGeneration += 1
        previewPipelineTask?.cancel()
        previewPipelineTask = nil
        askController.previewingVoice = nil

        soundPlayer.stopFile()
        if hadActiveSpeech {
            // Abort an in-flight synthesis by killing the helper (a busy synth
            // can't be cancelled otherwise); once playback has started the synth
            // is done, so just let the helper idle out and stay warm.
            if askController.speakingPhase == .synthesizing {
                ttsClient.stop()
            } else {
                ttsClient.noteIdle()
            }
        }
        askController.setSpeakingPhase(.idle)
    }

    // MARK: - Ask Flow (hold-Fn voice questions)

    private func wireAskCallbacks() {
        askController.backend = settings.askBackend
        askController.grokModel = settings.askGrokModel
        askController.saveHistory = settings.askSaveHistoryEnabled
        askController.insertText = { [weak self] text in
            guard let self else { return }
            do {
                try self.textInserter.insert(text: text)
            } catch {
                Self.logger.error("Ask insert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        askController.copyText = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        askController.speakAnswer = { [weak self] raw in
            self?.speakAnswerText(raw)
        }
        askController.stopSpeaking = { [weak self] in
            self?.stopAnswerSpeech()
        }
        askController.warmAudioOutput = { [weak self] in
            self?.soundPlayer.warmOutputDevice()
        }
        askController.speakStreamingText = { [weak self] text, isStart in
            self?.handleStreamingSpeechText(text, isStart: isStart)
        }
        askController.finishStreamingSpeech = { [weak self] in
            self?.handleStreamingSpeechFinish()
        }
        askController.startVoicePreview = { [weak self] voice in
            self?.playVoicePreview(voice)
        }
        askController.stopVoicePreview = { [weak self] in
            self?.stopVoicePreview()
        }
        askController.backendUsable = { backend in
            switch backend {
            case .codex: CodexAskClient.isInstalled && CodexAskClient.isSignedIn
            case .grok: GrokAskClient.isAvailable && GrokAskClient.isSignedIn
            }
        }
        askController.updateInstallationState(installed: CodexAskClient.isInstalled, for: .codex)
        askController.updateInstallationState(installed: GrokAskClient.isAvailable, for: .grok)
        askHotkey.onStart = { [weak self] in self?.beginAsk() }
        askHotkey.onStop = { [weak self] in self?.finishAsk() }
        askHotkey.onCancel = { [weak self] in self?.cancelAsk() }
    }

    /// Arms the Fn tap only when Ask is enabled and Accessibility is trusted;
    /// disarms it otherwise. Called from startTaps and the askEnabled sink.
    private func updateAskHotkeyArming() {
        guard settings.askEnabled, AXIsProcessTrusted() else {
            askHotkey.stop()
            return
        }
        askHotkey.start()
    }

    /// Fn pressed — begin capturing a question. Mutually exclusive with dictation
    /// (one shared audio engine): a press while dictation is active is ignored.
    /// A press during a streaming answer barges in; a press during an active
    /// capture (listening / transcribing / preparing) is still ignored.
    private func beginAsk() {
        let fnDownAt = CACurrentMediaTime()
        stopAnswerSpeech()
        guard settings.askEnabled else { return }
        guard !appState.isRecording, !appState.isPreparing, !appState.isProcessing else { return }
        let askStatus = askController.status
        guard askStatus != .listening, askStatus != .transcribing, askStatus != .preparing
        else { return }
        askFnDownAt = fnDownAt

        // Warm for auto-speak and manual Speak; the helper's 120s idle timer
        // bounds residency after this overlaps setup with transcription/answering.
        if askController.speakAvailable {
            ttsClient.prewarm()
            soundPlayer.warmOutputDevice()
        }

        switch transcriptionService.modelState {
        case .ready:
            beginAskRecording()
        case .loading, .notLoaded:
            // The speech model is still warming up. Do NOT start the audio engine
            // now: loading the model while the engine later tears down races
            // CoreAudio and crashes. Show a "Getting ready…" pill and begin
            // recording automatically the moment the model is ready.
            if case .notLoaded = transcriptionService.modelState {
                Task { [weak self] in await self?.transcriptionService.warmUp() }
            }
            pendingAskStart = true
            askController.beginPreparing()
            escapeInterceptor.start()
        case .downloading, .failed:
            askHotkey.deactivate()
            showSetupWindowIfNotReady()
        }
    }

    /// Begins the actual Ask capture session. Precondition: the speech model is
    /// `.ready` (the audio engine must never run concurrently with a model load).
    private func beginAskRecording() {
        askController.beginListening()  // shows the Ask pill + warms Codex
        askRecording = true
        guard audioRecorder.startRecording() else {
            askRecording = false
            askController.cancelCapture()
            return
        }
        askGeneration += 1
        askRecordingStartTime = Date()
        if let down = askFnDownAt {
            VLog.store("Fn→listening \(Int((CACurrentMediaTime() - down) * 1000))ms")
            askFnDownAt = nil
        }
        playFeedback(start: true)
        armMaxDurationTimer { [weak self] in self?.finishAsk() }
        escapeInterceptor.start()  // stays live through the whole turn (see bindStateToMenuBar)
    }

    /// Fn released — transcribe the captured audio and hand the question to the
    /// backend. Escape stays armed through the turn so it can interrupt streaming.
    private func finishAsk() {
        if pendingAskStart {
            pendingAskStart = false
            askController.cancelCapture()
            return
        }
        guard askRecording else { return }
        askRecording = false
        maxDurationTimer?.invalidate()
        let samples = audioRecorder.stopRecording()
        askRecordingStartTime = nil
        playFeedback(start: false)
        askController.markTranscribing()

        let generation = askGeneration
        askProcessingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.ifCurrentAsk(generation) { self.askProcessingTask = nil } }

            if Task.isCancelled { self.askController.cancelCapture(); return }
            guard AudioRecorder.containsSpeech(samples) else {
                self.askController.cancelCapture()
                return
            }
            do {
                let raw = try await self.transcriptionService.transcribe(samples)
                if Task.isCancelled { self.askController.cancelCapture(); return }
                let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty else { self.askController.cancelCapture(); return }
                self.askController.submit(question)
            } catch {
                Self.logger.error("Ask transcription failed: \(error.localizedDescription, privacy: .public)")
                self.askController.cancelCapture()
            }
        }
    }

    /// Fn tap deactivated while held (secure input, app switch) — discard cleanly.
    private func cancelAsk() {
        guard pendingAskStart || askRecording else { return }
        abortAsk()
    }

    /// Cancels whatever Ask is doing — recording, transcribing, or a live turn.
    private func abortAsk() {
        if pendingAskStart {
            pendingAskStart = false
            askController.cancelCapture()
            return
        }
        pendingAskStart = false
        if askRecording {
            askRecording = false
            audioRecorder.stopRecording()
            maxDurationTimer?.invalidate()
        }
        askProcessingTask?.cancel()
        askController.abort()  // interrupts the turn (if any) + cancels the run
        // The Escape interceptor is torn down by the askController.$run sink once
        // the run reaches a terminal state.
    }

    /// Guards Ask UI/session mutations against a stale generation (a slow
    /// transcription finishing after a newer Ask began).
    private func ifCurrentAsk(_ generation: Int, _ work: () -> Void) {
        guard generation == askGeneration else { return }
        work()
    }

    /// Menu bar → Show Last Answer: re-summons the newest completed Ask into
    /// the pill, pinned. No-op while an Ask or dictation is live, or when
    /// history is empty (dictation owns bottom-center while active).
    @objc private func showLastAskAnswer() {
        guard !appState.isRecording, !appState.isPreparing, !appState.isProcessing else { return }
        askController.showLastAnswer()
    }

    /// Arms the safety timer that force-stops an over-long session.
    private func armMaxDurationTimer(_ stop: @escaping () -> Void) {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.maxRecordingDuration, repeats: false
        ) { [weak self] _ in
            self?.hotkeyManager.deactivate()
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

    /// Distinct cue when a dictation fails (transcription or insertion threw), so
    /// a failure doesn't sound like the success confirmation. Same volume scaling
    /// as success; callers gate it on the session still being current.
    private func playFailureFeedback() {
        guard settings.audioFeedbackEnabled else { return }
        soundPlayer.play(.failure, volume: settings.audioFeedbackVolume * 0.7)
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
        // Never stack the setup window over onboarding: the guided flow has its
        // own model-status step, and the download continues in the background
        // while the user walks through it.
        guard onboardingWindow == nil else { return }
        if setupWindow == nil {
            // Pin the window size: an auto-sizing NSHostingController animates the
            // window to fit its content, and on macOS 26 that animated resize
            // crashes in the safe-area-corner-inset pass. ModelSetupView's height
            // shifts as the model state changes, so honor a fixed frame instead.
            let hosting = NSHostingController(
                rootView: ModelSetupView(transcriptionService: transcriptionService)
            )
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Yappy"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 380, height: 320))
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

    // MARK: - Vocabulary Boosting

    /// (Re)configures speech-model vocabulary biasing from the current toggle and
    /// dictionary. When boosting is off, configures with `[]`, which tears the
    /// biasing state down. Runs only at audio-idle moments (warm-up, a toggle
    /// change, or a debounced dictionary edit) — never on the dictation path,
    /// because the CTC model load must not race the audio engine (see
    /// `ParakeetTranscriptionService.configureVocabularyBoosting`).
    @MainActor
    private func reconfigureVocabularyBoosting() async {
        let terms = settings.vocabularyBoostingEnabled ? dictionaryStore.terms : []
        await transcriptionService.configureVocabularyBoosting(terms: terms)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuBarIcon()

        let menu = NSMenu()
        statusMenu = menu
        menu.addItem(NSMenuItem(title: "Open Yappy", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Scratchpad (⌥⇧S)", action: #selector(toggleScratchpad), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Last Answer", action: #selector(showLastAskAnswer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Configure Answers…", action: #selector(openMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Commands…", action: #selector(openCommands), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        menu.addItem(modeItem)
        modeMenuItem = modeItem
        rebuildModeMenu()

        menu.addItem(NSMenuItem.separator())
        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(checkForUpdatesClicked),
                                     keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)
        let whatsNewItem = NSMenuItem(title: "What's New in Yappy", action: #selector(showWhatsNew), keyEquivalent: "")
        whatsNewItem.target = self
        menu.addItem(whatsNewItem)
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

        // Ask reflects into the same menu-bar glyph (listening → recording anim,
        // thinking/working → processing). This sink also tears down the Escape
        // interceptor once an Ask run is over — it must stay live through the
        // whole turn (not just capture) so Esc can interrupt a streaming answer.
        askController.$run
            .receive(on: DispatchQueue.main)
            .sink { [weak self] run in
                guard let self else { return }
                self.updateMenuBarIcon()
                let over = (run == nil) || (run?.status.isTerminal == true)
                if over, !self.askRecording, !self.appState.isRecording, !self.appState.isProcessing {
                    self.escapeInterceptor.stop()
                }
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
                guard let self else { return }
                if self.pendingDictationStart {
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
                if self.pendingAskStart {
                    switch state {
                    case .ready:
                        self.pendingAskStart = false
                        self.beginAskRecording()
                    case .failed:
                        self.pendingAskStart = false
                        self.askController.cancelCapture()
                        self.showSetupWindowIfNotReady()
                    case .notLoaded, .loading, .downloading:
                        break // keep showing the preparing pill until ready/failed
                    }
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
        if appState.isRecording || askController.isListening {
            startMenuBarAnimation()
            return
        }
        stopMenuBarAnimation()

        let image: NSImage
        if appState.isProcessing || askController.isExecuting {
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
    private static let readyIcon: NSImage = yIcon(.ready)
    private static let processingIcon: NSImage = yIcon(.processing)

    /// Precomputed frames "breathing" the Y's stroke weight while recording —
    /// the lettermark has no waveform bars to animate, so the whole glyph pulses
    /// instead, echoing the pill's breathing glow. Cheap to swap, like the old
    /// bar frames.
    private static let recordingFrames: [NSImage] = [
        2.3, 2.6, 2.9, 2.6, 2.3,
    ].map { yIcon(.recording, strokeWidth: $0) }

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

    /// Draws the Yappy "Y" lettermark for a given state.
    /// Ready/processing are template images (auto light/dark); recording is solid
    /// orange. `strokeWidth` drives the recording "breathe" animation frames.
    private static func yIcon(_ glyph: MenuBarGlyph, strokeWidth: CGFloat = 2.6) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = yPath()
            path.lineWidth = strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            switch glyph {
            case .ready:
                NSColor.black.setStroke()
            case .processing:
                // Dimmed, to read as "working" during the brief processing
                // window (the pill shows the detailed state).
                NSColor.black.withAlphaComponent(0.4).setStroke()
            case .recording:
                brandOrange.setStroke()
            }
            path.stroke()
            return true
        }
        image.isTemplate = (glyph != .recording)
        return image
    }

    /// The Y lettermark in an 18×18 box: two arms meeting at the fork, stem
    /// dropping to the baseline. NSImage's unflipped coordinates put y=0 at the
    /// BOTTOM, so the arms anchor high (y 15.4) and the stem ends low (y 2.6).
    /// Stroke-based (round caps/joins) so the recording frames can vary weight.
    private static func yPath() -> NSBezierPath {
        let path = NSBezierPath()
        let fork = NSPoint(x: 9.0, y: 9.0)
        path.move(to: NSPoint(x: 4.4, y: 15.4))
        path.line(to: fork)
        path.move(to: NSPoint(x: 13.6, y: 15.4))
        path.line(to: fork)
        path.move(to: fork)
        path.line(to: NSPoint(x: 9.0, y: 2.6))
        return path
    }

    // MARK: - Settings Bindings

    private func bindSettings() {
        settings.$hotkeyOption
            .removeDuplicates()
            .sink { [weak self] option in
                self?.hotkeyManager.updateMode(option)
            }
            .store(in: &cancellables)

        // Ask: arm/disarm the Fn tap and warm/tear-down the backend when the
        // enable toggle flips. The prewarm itself is gated on readyToPrewarmAsk
        // so it never competes with the launch speech-model load; once that
        // load finishes, toggling here warms the backend immediately.
        settings.$askEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.updateAskHotkeyArming()
                if enabled {
                    // This sink can fire (at bind time) before the backend wiring
                    // runs — sync the selection first or the default (.codex)
                    // gets warmed regardless of the setting.
                    self.askController.backend = self.settings.askBackend
                    if self.readyToPrewarmAsk {
                        self.askPillController.prewarm()
                        self.askController.prewarm()
                    }
                } else {
                    self.askController.shutdown()
                }
            }
            .store(in: &cancellables)

        settings.$askBackend
            .removeDuplicates()
            .sink { [weak self] backend in
                guard let self else { return }
                self.askController.backend = backend
                if self.readyToPrewarmAsk {
                    self.askController.prewarm()
                }
                // One resident helper: the deselected backend's warm process
                // (app-server / grok agent) has no next question coming.
                self.askController.shutdownDeselectedBackend()
            }
            .store(in: &cancellables)

        settings.$askSaveHistoryEnabled
            .removeDuplicates()
            .sink { [weak self] on in self?.askController.saveHistory = on }
            .store(in: &cancellables)

        settings.$askGrokModel
            .removeDuplicates()
            .sink { [weak self] model in self?.askController.grokModel = model }
            .store(in: &cancellables)

        settings.$answersSpeakEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.updateAnswerSpeakAvailability()
                if !enabled {
                    self.stopAnswerSpeech()
                    self.ttsClient.stop()
                }
            }
            .store(in: &cancellables)

        settings.$answersAutoSpeak
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.askController.autoSpeak = enabled
            }
            .store(in: &cancellables)

        // Switch the active speech model when the user changes it. Updating
        // activeModel unloads the previous model and resets modelState to
        // .notLoaded; warmUp() then (down)loads the now-active model. dropFirst:
        // the launch code already applied the initial value above.
        settings.$transcriptionModel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] model in
                guard let self else { return }
                self.transcriptionService.activeModel = model
                Task { @MainActor [weak self] in await self?.transcriptionService.warmUp() }
            }
            .store(in: &cancellables)

        // Keep the menu-bar Mode submenu in sync with the list and selection.
        modeStore.$modes
            .sink { [weak self] _ in self?.rebuildModeMenu() }
            .store(in: &cancellables)

        // Rebuild the precompiled dictionary matcher only when terms change
        // (fires immediately with the current terms, then on every edit). Also
        // marks the Home checklist's "add a dictionary term" item once the user
        // has a term of their own.
        dictionaryStore.$terms
            .sink { [weak self] terms in
                self?.dictionaryReplacer = DictionaryReplacer(terms: terms)
                self?.markDictionaryTermAddedIfNeeded(terms)
                // Capitalized dictionary terms ("Cigna", "Xcode") are proper
                // nouns the continuation-casing adjustment must never lowercase.
                // Tokenized the same way ContinuationCasing.decapitalized extracts
                // its first word (letters + apostrophes), so the lookups align.
                self?.textInserter.protectedCapitalizedWords = Set(
                    terms.compactMap { term in
                        let firstWord = term.text.prefix(while: {
                            $0.isLetter || $0 == "'" || $0 == "\u{2019}"
                        })
                        guard let first = firstWord.first, first.isUppercase else { return nil }
                        return String(firstWord)
                    }
                )
            }
            .store(in: &cancellables)

        // Rebuild the speech-model biasing vocabulary when the dictionary changes.
        // Debounced ~1s so rapid edits (typing several terms, editing aliases)
        // don't thrash the CTC model reconfiguration. dropFirst: the launch-time
        // warm-up already applied the initial configuration.
        dictionaryStore.$terms
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reconfigureVocabularyBoosting() }
            }
            .store(in: &cancellables)

        // Enable/disable speech-model vocabulary biasing when the toggle flips.
        // Turning it off reconfigures with an empty list, tearing the state down.
        // dropFirst: the launch-time warm-up already applied the initial value.
        settings.$vocabularyBoostingEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reconfigureVocabularyBoosting() }
            }
            .store(in: &cancellables)
        settings.$activeModeID
            .removeDuplicates()
            .sink { [weak self] id in
                self?.rebuildModeMenu()
                self?.markModeTriedIfNeeded(id)
            }
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

        // Warm up the on-device cleanup model the moment the user enables cleanup,
        // so it's "ready to work" without a cold start. prewarm() self-gates to a
        // no-op when cleanup is off or no provider is available.
        settings.$cleanupEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.cleanupCoordinator.prewarm() }
            .store(in: &cancellables)

        // Keep the history store's retention window in sync when the user changes
        // it, so newly-expired entries prune on the next add/load. dropFirst: the
        // launch code above already applied the initial value.
        settings.$historyRetentionDays
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] days in self?.history.retentionDays = days }
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
                appState: appState,
                requestMicrophone: { await AudioRecorder.requestPermission() },
                startLevelPreview: { [weak self] in self?.audioRecorder.startLevelPreview() ?? false },
                stopLevelPreview: { [weak self] in self?.audioRecorder.stopLevelPreview() },
                applyUseCase: { [weak self] picks in self?.applyUseCasePresets(picks) },
                onFinish: { [weak self] in
                    self?.completeOnboarding()
                },
                onBrowseCommands: { [weak self] in
                    guard let self else { return }
                    self.completeOnboarding()
                    // The whole point of the button: land the new user on the
                    // cheat sheet, not just close the window.
                    self.mainWindowController.present(selecting: .commands)
                }
            )
            // Pin the window size: an auto-sizing NSHostingController animates the
            // window to fit its content, and on macOS 26 that animated resize
            // crashes in the safe-area-corner-inset pass (first-run only, which is
            // why it escaped testing). OnboardingView is a fixed 460x500.
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Yappy"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 460, height: 500))
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Turns the onboarding use-case picks into starter Modes + dictionary terms.
    /// These are conveniences the user can change later, so it's idempotent: a Mode
    /// is created only when one with that name doesn't already exist, and
    /// `DictionaryStore.add` dedupes seeded terms.
    private func applyUseCasePresets(_ picks: Set<UseCase>) {
        settings.useCases = Set(picks.map { $0.rawValue })

        for useCase in picks {
            let preset = Self.presetMode(for: useCase)
            if !modeStore.modes.contains(where: { $0.name == preset.name }) {
                modeStore.add(preset)
            }
            for term in Self.dictionaryTerms(for: useCase) {
                dictionaryStore.add(term)
            }
        }
    }

    /// The starter Mode for a use case. Tone + auto-trigger category match how the
    /// app classifies that kind of destination; formatting bools use the `Mode`
    /// defaults so behavior matches a hand-created mode.
    private static func presetMode(for useCase: UseCase) -> Mode {
        switch useCase {
        case .code:
            return Mode(name: "Code", symbolName: "chevron.left.forwardslash.chevron.right",
                        tone: .verbatim, autoTriggerCategory: .code)
        case .email:
            return Mode(name: "Email", symbolName: "envelope",
                        tone: .formal, autoTriggerCategory: .email)
        case .chat:
            return Mode(name: "Chat", symbolName: "bubble.left.and.bubble.right",
                        tone: .casual, autoTriggerCategory: .personalChat)
        case .writing:
            return Mode(name: "Writing", symbolName: "pencil",
                        tone: .formal, autoTriggerCategory: nil)
        case .notes:
            return Mode(name: "Notes", symbolName: "note.text",
                        tone: .casual, autoTriggerCategory: nil)
        }
    }

    /// A small set of clearly-relevant dictionary terms to seed per use case.
    /// Only "Code" has obvious mishearing-prone vocabulary; the prose-oriented
    /// cases seed nothing rather than guessing.
    private static func dictionaryTerms(for useCase: UseCase) -> [String] {
        switch useCase {
        case .code: return ["API", "JSON", "OAuth", "async"]
        case .writing, .email, .chat, .notes: return []
        }
    }

    // MARK: - Window & Menu Actions

    private func showMainWindow() {
        mainWindowController.present()
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    /// Menu bar → Commands…: opens the main window with the Commands cheat
    /// sheet selected, regardless of whatever tab was showing before.
    /// Shared tail of both onboarding exits ("Finish" and "Browse the commands").
    private func completeOnboarding() {
        audioRecorder.stopLevelPreview()
        onboardingLevelModel = nil
        settings.onboardingComplete = true
        onboardingWindow?.close()
        onboardingWindow = nil
        startTaps()
    }

    @objc private func openCommands() {
        mainWindowController.present(selecting: .commands)
    }

    /// Re-show the "What's New" card on demand (menu bar + Settings → Software Update).
    /// Falls back to the latest entry if the running version has no notes of its own.
    @objc private func showWhatsNew() {
        whatsNewPresenter.entry = WhatsNew.current ?? WhatsNew.latest
        showMainWindow()
    }

    @objc private func toggleScratchpad() {
        // Never summon the notepad mid-Ask — they'd fight over the audio engine
        // and the floating panels would overlap.
        guard !askController.isBusy else { return }
        // A toggle from hidden → visible counts as opening it for the checklist.
        if !scratchpadController.isVisible, !settings.hasOpenedScratchpad {
            settings.hasOpenedScratchpad = true
        }
        scratchpadController.toggle()
    }

    /// The Home checklist's "Open the scratchpad" row: always SHOWS (a
    /// checklist action should do the thing, not toggle it away) and marks the
    /// checklist item done.
    private func openScratchpadFromHome() {
        guard !askController.isBusy else { return }
        settings.hasOpenedScratchpad = true
        scratchpadController.show()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
