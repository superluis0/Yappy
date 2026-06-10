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
    let transcriptionService = ParakeetTranscriptionService()

    private let audioRecorder = AudioRecorder()
    private let textInserter = TextInserter()
    private let soundPlayer = SoundPlayer()
    private lazy var lmStudio = LMStudioService(settings: settings)
    private lazy var hotkeyManager = HotkeyManager(mode: settings.hotkeyOption)
    private lazy var commandHotkeyManager = HotkeyManager(mode: settings.commandHotkeyOption)
    private lazy var escapeInterceptor = EscapeInterceptor()
    private lazy var pillController = RecordingPillController(appState: appState)
    private lazy var mainWindowController = MainWindowController(
        settings: settings,
        history: history,
        shortcutStore: shortcutStore,
        dictionaryStore: dictionaryStore,
        transcriptionService: transcriptionService,
        lmStudio: lmStudio
    )

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var menuBarAnimationTimer: Timer?
    private var menuBarFrameIndex = 0
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private var maxDurationTimer: Timer?
    private var accessibilityPollTimer: Timer?
    private var setupWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    /// Text selected in the frontmost app when Command Mode started.
    private var pendingCommandSelection: String?
    /// Bundle id of the app that had focus when the current session started.
    private var sessionBundleID: String?

    // Dictionary-boosted final via the sliding-window manager.
    private var dictionarySessionActive = false
    private var dictionaryReady = false
    private var pendingStreamBuffers: [AVAudioPCMBuffer] = []

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show the Dock icon for the whole time Yappy is running (alongside the
        // menu bar item), not just while the main window is open.
        NSApp.setActivationPolicy(.regular)

        setupMenuBar()
        bindStateToMenuBar()
        bindSettings()

        audioRecorder.onAudioLevelUpdate = { [weak self] level in
            self?.appState.updateAudioLevel(level)
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

        // Onboarding shows only for new users (first launch). Returning users
        // manage permissions from Settings; just resolve mic access up front so
        // the first hotkey press works.
        if settings.onboardingComplete {
            Task { _ = await AudioRecorder.requestPermission() }
        } else {
            showOnboarding()
        }
        startHotkeyMonitoring()
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
    }

    /// Esc pressed mid-session: deactivate both hotkey state machines first so
    /// the eventual modifier key-up doesn't fire a spurious stop, then cancel.
    private func escapeCancel() {
        guard appState.isRecording else { return }
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
        return dictationStarted
    }

    // MARK: - Dictation Flow

    private func startDictation() {
        guard !appState.isRecording else { return }
        guard transcriptionService.modelState == .ready else {
            // Model still downloading/loading — surface the setup window instead.
            hotkeyManager.deactivate()
            showSetupWindowIfNotReady()
            return
        }
        guard audioRecorder.startRecording() else {
            hotkeyManager.deactivate()
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        sessionBundleID = frontApp?.bundleIdentifier

        recordingStartTime = Date()
        appState.startRecording(mode: .dictation)
        pillController.show()
        playFeedback(start: true)
        armMaxDurationTimer { [weak self] in self?.finishDictation() }
        escapeInterceptor.start()

        beginDictionarySessionIfNeeded()
    }

    // MARK: - Dictionary-boosted Session

    /// Feeds audio to the sliding-window manager (with CTC boosting) so the
    /// final transcript honors the custom dictionary. No effect on the caption.
    private func beginDictionarySessionIfNeeded() {
        let terms = settings.customDictionaryEnabled ? dictionaryStore.terms : []
        guard !terms.isEmpty else { return }

        dictionarySessionActive = true
        dictionaryReady = false
        pendingStreamBuffers.removeAll()

        audioRecorder.onBuffer = { [weak self] buffer in
            DispatchQueue.main.async { self?.routeStreamBuffer(buffer) }
        }

        Task { @MainActor [weak self] in
            guard let self, self.appState.isRecording, self.appState.mode == .dictation else { return }
            let ok = await self.transcriptionService.startStreamingSession(
                dictionaryTerms: terms
            ) { _ in }
            guard ok, self.appState.isRecording else {
                self.dictionarySessionActive = false
                return
            }
            for buffer in self.pendingStreamBuffers {
                self.transcriptionService.streamBuffer(buffer)
            }
            self.pendingStreamBuffers.removeAll()
            self.dictionaryReady = true
        }
    }

    private func routeStreamBuffer(_ buffer: AVAudioPCMBuffer) {
        guard dictionarySessionActive else { return }
        if dictionaryReady {
            transcriptionService.streamBuffer(buffer)
        } else {
            pendingStreamBuffers.append(buffer)
        }
    }

    private func finishDictation() {
        guard appState.isRecording, appState.mode == .dictation else { return }
        maxDurationTimer?.invalidate()
        escapeInterceptor.stop()

        let samples = audioRecorder.stopRecording()
        audioRecorder.onBuffer = nil
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil
        let bundleID = sessionBundleID
        let targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        let wasDictionary = dictionarySessionActive
        dictionarySessionActive = false
        dictionaryReady = false
        pendingStreamBuffers.removeAll()

        appState.stopRecording()
        playFeedback(start: false)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The dictionary path carries CTC boosting; fall back to batch if
                // it produced nothing.
                var raw = ""
                if wasDictionary {
                    raw = await self.transcriptionService.finishStreamingSession()
                }
                if raw.isEmpty {
                    raw = try await self.transcriptionService.transcribe(samples)
                }

                let expanded = ShortcutExpander(shortcuts: self.shortcutStore.shortcuts).expand(raw)
                let tone = self.resolvedTone(forBundleID: bundleID)
                let text = await self.lmStudio.cleanup(expanded, tone: tone)

                if !text.isEmpty {
                    try self.textInserter.insert(text: text)
                    self.playSuccessFeedback()
                    self.history.add(DictationEntry(
                        text: text,
                        durationSeconds: duration,
                        appName: targetAppName,
                        bundleID: bundleID
                    ))
                }
                self.appState.setTranscription(text)
            } catch {
                self.appState.setError(error)
            }
            self.appState.reset()
            self.pillController.hide()
        }
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
        pendingCommandSelection = nil
        audioRecorder.stopRecording()
        audioRecorder.onBuffer = nil

        if dictionarySessionActive {
            dictionarySessionActive = false
            dictionaryReady = false
            pendingStreamBuffers.removeAll()
            Task { await transcriptionService.cancelStreamingSession() }
        }

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

        guard audioRecorder.startRecording() else {
            commandHotkeyManager.deactivate()
            return
        }

        pendingCommandSelection = selection
        recordingStartTime = Date()
        appState.startRecording(mode: .command)
        pillController.show()
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
            do {
                let instruction = try await self.transcriptionService.transcribe(samples)
                if let result = await self.lmStudio.runCommand(instruction: instruction, selection: selection),
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
            case .unavailable: return "Command Mode needs LM Studio running. Your text was left unchanged."
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
        menu.addItem(NSMenuItem(title: "Open Yappy", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About Yappy", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Yappy", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
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
            image = Self.bubbleIcon(.processing)
        } else {
            switch transcriptionService.modelState {
            case .ready:
                image = Self.bubbleIcon(.ready)
            case .downloading, .loading, .notLoaded:
                image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloading model")
                    ?? Self.bubbleIcon(.ready)
                image.isTemplate = true
            case .failed:
                image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: "Model error")
                    ?? Self.bubbleIcon(.ready)
                image.isTemplate = true
            }
        }
        statusItem?.button?.image = image
    }

    // MARK: - Menu Bar Recording Animation

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

        // Pre-download the dictionary model when the feature is switched on.
        settings.$customDictionaryEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard enabled else { return }
                Task { await self?.transcriptionService.prewarmDictionary() }
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
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                transcriptionService: transcriptionService,
                requestMicrophone: { await AudioRecorder.requestPermission() },
                onFinish: { [weak self] in
                    self?.settings.onboardingComplete = true
                    self?.onboardingWindow?.close()
                    self?.onboardingWindow = nil
                    self?.startTaps()
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

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
