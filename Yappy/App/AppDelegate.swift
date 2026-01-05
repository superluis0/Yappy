//
//  AppDelegate.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import AppKit
import SwiftUI
import Combine

/// Core coordinator that wires all Yappy components together.
/// Manages the menu bar item, waveform display, audio recording, and transcription pipeline.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - UI Components

    var statusItem: NSStatusItem?
    var popover: NSPopover
    var waveformWindow: WaveformWindow?

    // MARK: - State & Settings

    let appState = AppState()
    let settings = Settings()

    // MARK: - Services

    var hotkeyManager: HotkeyManager?
    let audioRecorder = AudioRecorder()
    let levelProcessor = AudioLevelProcessor()
    let textInserter = TextInserter()

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private let minimumRecordingDuration: TimeInterval = 0.5

    // MARK: - Initialization

    override init() {
        // Initialize popover
        self.popover = NSPopover()
        super.init()

        // Configure popover
        self.popover.contentSize = NSSize(width: 250, height: 300)
        self.popover.behavior = .transient
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (menu bar app only)
        NSApp.setActivationPolicy(.accessory)

        // Create status bar item
        setupStatusItem()

        // Initialize waveform window
        setupWaveformWindow()

        // Load settings
        settings.load()

        // Initialize hotkey manager
        setupHotkeyManager()

        // Observe app state changes to update UI
        observeAppState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stop()
        waveformWindow?.stopObservingScreenChanges()
    }

    // MARK: - Setup Methods

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yappy")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupWaveformWindow() {
        waveformWindow = WaveformWindow(appState: appState)
        waveformWindow?.startObservingScreenChanges()
    }

    private func setupHotkeyManager() {
        hotkeyManager = HotkeyManager(settings: settings)
        hotkeyManager?.onActivate = { [weak self] in
            self?.handleActivate()
        }
        hotkeyManager?.onDeactivate = { [weak self] in
            self?.handleDeactivate()
        }

        do {
            try hotkeyManager?.start()
        } catch {
            handleError(error)
        }
    }

    private func observeAppState() {
        // Update status icon when state changes
        appState.$isRecording
            .combineLatest(appState.$isProcessing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        // Update popover content
        let menuBarView = MenuBarView(
            appState: appState,
            settings: settings,
            openSettings: { [weak self] in
                self?.openSettings()
            },
            quitApp: { [weak self] in
                self?.quitApplication()
            }
        )

        popover.contentViewController = NSHostingController(rootView: menuBarView)
    }

    // MARK: - Hotkey Handlers

    func handleActivate() {
        // Prevent multiple simultaneous recordings
        guard !appState.isRecording && !appState.isProcessing else {
            return
        }

        // Check API configuration
        guard settings.isConfigured else {
            handleError(YappyError.notConfigured)
            return
        }

        // Start recording
        appState.startRecording()
        recordingStartTime = Date()
        levelProcessor.reset()

        // Show waveform
        waveformWindow?.show()

        // Start audio recording with level callback
        do {
            try audioRecorder.startRecording { [weak self] rawLevel in
                guard let self = self else { return }

                // Process level through smoothing
                let processedLevel = self.levelProcessor.processLevel(rawLevel)

                // Update app state on main thread
                DispatchQueue.main.async {
                    self.appState.updateAudioLevel(processedLevel)
                }
            }
        } catch {
            appState.reset()
            waveformWindow?.hide()
            handleError(error)
        }
    }

    func handleDeactivate() {
        // Only stop if we're actually recording
        guard appState.isRecording else {
            return
        }

        // Check minimum recording duration
        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            if duration < minimumRecordingDuration {
                // Recording too short - discard it
                appState.reset()
                waveformWindow?.hide()
                audioRecorder.stopRecording()
                return
            }
        }

        // Stop recording and get file URL
        guard let recordingURL = audioRecorder.stopRecording() else {
            appState.reset()
            waveformWindow?.hide()
            handleError(YappyError.recordingFailed)
            return
        }

        // Update state
        appState.stopRecording()

        // Process recording asynchronously
        Task {
            await processRecording(url: recordingURL)
        }
    }

    // MARK: - Recording Processing

    private func processRecording(url: URL) async {
        do {
            // Load audio data
            let audioData = try Data(contentsOf: url)

            // Transcribe with Whisper
            let whisperService = WhisperService(apiKey: settings.openAIAPIKey)
            var transcription = try await whisperService.transcribe(audioData: audioData)

            // Cleanup with Grok if enabled
            if settings.cleanupEnabled {
                let grokService = GrokService(apiKey: settings.xAIAPIKey)
                transcription = try await grokService.cleanup(text: transcription)
            }

            // Insert text on main thread
            await MainActor.run {
                do {
                    try textInserter.insert(text: transcription)
                    appState.setTranscription(transcription)
                } catch {
                    handleError(error)
                }
            }

        } catch {
            await MainActor.run {
                handleError(error)
            }
        }

        // Clean up temp file
        try? FileManager.default.removeItem(at: url)

        // Hide waveform and reset state
        await MainActor.run {
            waveformWindow?.hide()

            // Only reset if not already in an error state
            if appState.error == nil {
                appState.reset()
            }
        }
    }

    // MARK: - UI Updates

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        if appState.isRecording {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
        } else if appState.isProcessing {
            button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Processing")
            button.contentTintColor = .systemOrange
        } else {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yappy")
            button.contentTintColor = nil
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Settings & Actions

    private func openSettings() {
        popover.performClose(nil)

        // Open settings window using SwiftUI's Settings scene
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func quitApplication() {
        NSApp.terminate(nil)
    }

    // MARK: - Error Handling

    private func handleError(_ error: Error) {
        // Log error
        print("Yappy Error: \(error.localizedDescription)")

        // Update app state
        appState.setError(error)

        // Show user-friendly alert
        let alert = NSAlert()
        alert.messageText = "Yappy Error"
        alert.informativeText = getUserFriendlyErrorMessage(for: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        // Show the alert
        alert.runModal()
    }

    private func getUserFriendlyErrorMessage(for error: Error) -> String {
        // Check for specific error types and provide helpful messages
        if let audioError = error as? AudioRecorderError {
            switch audioError {
            case .microphonePermissionDenied:
                return "Microphone access is required. Please grant permission in System Settings > Privacy & Security > Microphone."
            default:
                return audioError.localizedDescription
            }
        } else if let hotkeyError = error as? HotkeyError {
            switch hotkeyError {
            case .accessibilityPermissionDenied:
                return "Accessibility access is required for hotkey detection. Please grant permission in System Settings > Privacy & Security > Accessibility."
            default:
                return hotkeyError.localizedDescription
            }
        } else if let whisperError = error as? WhisperError {
            switch whisperError {
            case .networkError:
                return "Network error occurred. Please check your internet connection and try again."
            case .invalidAPIKey:
                return "Invalid OpenAI API key. Please check your settings."
            default:
                return whisperError.localizedDescription
            }
        } else if let grokError = error as? GrokError {
            switch grokError {
            case .networkError:
                return "Network error occurred. Please check your internet connection and try again."
            case .invalidAPIKey:
                return "Invalid xAI API key. Please check your settings."
            default:
                return grokError.localizedDescription
            }
        } else if let yappyError = error as? YappyError {
            return yappyError.localizedDescription
        }

        return error.localizedDescription
    }
}

// MARK: - Custom Errors

enum YappyError: LocalizedError {
    case notConfigured
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "API keys not configured. Please add your OpenAI and xAI API keys in Settings before using voice recording."
        case .recordingFailed:
            return "Failed to save the recording. Please try again."
        }
    }
}
