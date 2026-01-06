//
//  AppDelegate.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Cocoa
import SwiftUI

/// Application delegate that manages the menu bar interface and app lifecycle.
/// Handles hotkey monitoring, menu bar item setup, and coordination between services.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    /// Menu bar status item
    private var statusItem: NSStatusItem?

    /// Application settings
    let settings = Settings()

    /// Application state
    let appState = AppState()
    
    /// Waveform window controller for visual feedback
    private lazy var waveformController = WaveformWindowController(appState: appState)
    
    /// Settings window controller
    private var settingsWindowController: NSWindowController?
    
    /// Event monitor for global key events
    private var globalEventMonitor: Any?
    
    /// Event monitor for local key events
    private var localEventMonitor: Any?
    
    /// Tracks the state of modifier keys for double-tap detection
    private var lastCommandKeyUpTime: Date?
    private var commandKeyDownTime: Date?
    
    /// Tracks when recording started to ensure minimum duration
    private var recordingStartTime: Date?
    
    /// Audio recorder for capturing microphone input
    private let audioRecorder = AudioRecorder()
    
    /// Transcription service for API calls
    private lazy var transcriptionService = TranscriptionService(settings: settings)

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check for accessibility permissions (needed to simulate paste)
        checkAccessibilityPermissions()
        
        // Setup menu bar item
        setupMenuBar()
        
        // Setup hotkey monitoring
        setupHotkeyMonitoring()
        
        // Connect audio recorder to app state for waveform visualization
        audioRecorder.onAudioLevelUpdate = { [weak self] level in
            self?.appState.updateAudioLevel(level)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup when app quits
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    // MARK: - Accessibility Permissions
    
    /// Checks and requests accessibility permissions needed for simulating keystrokes
    private func checkAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        
        // Print the actual process name to help with debugging
        let processName = ProcessInfo.processInfo.processName
        let bundleID = Bundle.main.bundleIdentifier ?? "Unknown"
        
        print("🔍 Process Name: \(processName)")
        print("🔍 Bundle ID: \(bundleID)")
        
        if !accessEnabled {
            print("⚠️ Accessibility permissions not granted. Please enable in System Settings > Privacy & Security > Accessibility")
        } else {
            print("✅ Accessibility permissions granted")
        }
    }
    
    // MARK: - Hotkey Monitoring
    
    private func setupHotkeyMonitoring() {
        // Monitor for flags changed events (modifier keys)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        
        switch settings.hotkeyOption {
        case .rightCommandHold:
            handleRightCommandHold(flags: flags, event: event)
        case .rightCommandDoubleTap:
            handleRightCommandDoubleTap(flags: flags, event: event)
        case .rightOptionHold:
            handleRightOptionHold(flags: flags, event: event)
        }
    }
    
    private func handleRightCommandHold(flags: NSEvent.ModifierFlags, event: NSEvent) {
        // Check if right command key is pressed
        let isRightCommand = flags.contains(.command) && event.keyCode == 54 // 54 is right command
        
        if isRightCommand && !appState.isRecording {
            // Start recording
            if audioRecorder.startRecording() {
                appState.startRecording()
                recordingStartTime = Date()
                waveformController.show()
                print("🎤 Started recording (Right Command Hold)")
            }
        } else if !flags.contains(.command) && appState.isRecording {
            // Check minimum recording duration (0.1 seconds)
            if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) < 0.1 {
                print("⚠️ Recording too short, ignoring...")
                _ = audioRecorder.stopRecording()
                audioRecorder.cleanup()
                appState.stopRecording()
                waveformController.hide()
                recordingStartTime = nil
                return
            }
            
            // Stop recording
            appState.stopRecording()
            waveformController.hide()
            recordingStartTime = nil
            print("🛑 Stopped recording (Right Command Hold)")
            processRecording()
        }
    }
    
    private func handleRightCommandDoubleTap(flags: NSEvent.ModifierFlags, event: NSEvent) {
        let isRightCommand = flags.contains(.command) && event.keyCode == 54
        let now = Date()
        
        if isRightCommand {
            // Command key pressed
            commandKeyDownTime = now
        } else if commandKeyDownTime != nil {
            // Command key released
            if let lastUpTime = lastCommandKeyUpTime,
               now.timeIntervalSince(lastUpTime) < 0.5 {
                // Double tap detected
                if appState.isRecording {
                    // Check minimum recording duration (0.1 seconds)
                    if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) < 0.1 {
                        print("⚠️ Recording too short, ignoring...")
                        _ = audioRecorder.stopRecording()
                        audioRecorder.cleanup()
                        appState.stopRecording()
                        waveformController.hide()
                        recordingStartTime = nil
                        return
                    }
                    
                    appState.stopRecording()
                    waveformController.hide()
                    recordingStartTime = nil
                    print("🛑 Stopped recording (Right Command Double Tap)")
                    processRecording()
                } else {
                    if audioRecorder.startRecording() {
                        appState.startRecording()
                        recordingStartTime = now
                        waveformController.show()
                        print("🎤 Started recording (Right Command Double Tap)")
                    }
                }
            }
            lastCommandKeyUpTime = now
            commandKeyDownTime = nil
        }
    }
    
    private func handleRightOptionHold(flags: NSEvent.ModifierFlags, event: NSEvent) {
        // Check if right option key is pressed
        let isRightOption = flags.contains(.option) && event.keyCode == 61 // 61 is right option
        
        if isRightOption && !appState.isRecording {
            // Start recording
            if audioRecorder.startRecording() {
                appState.startRecording()
                recordingStartTime = Date()
                waveformController.show()
                print("🎤 Started recording (Right Option Hold)")
            }
        } else if !flags.contains(.option) && appState.isRecording {
            // Check minimum recording duration (0.1 seconds)
            if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) < 0.1 {
                print("⚠️ Recording too short, ignoring...")
                _ = audioRecorder.stopRecording()
                audioRecorder.cleanup()
                appState.stopRecording()
                waveformController.hide()
                recordingStartTime = nil
                return
            }
            
            // Stop recording
            appState.stopRecording()
            waveformController.hide()
            recordingStartTime = nil
            print("🛑 Stopped recording (Right Option Hold)")
            processRecording()
        }
    }
    
    // MARK: - Recording Processing
    
    /// Simulates a Cmd+V keystroke to paste clipboard contents at cursor location
    private func simulatePaste() {
        // Check accessibility permissions
        let trusted = AXIsProcessTrusted()
        
        if !trusted {
            print("❌ Cannot simulate paste - Accessibility permissions not granted")
            print("❌ Please enable in System Settings > Privacy & Security > Accessibility")
            print("❌ Make sure to enable BOTH Xcode AND your app if running from Xcode")
            print("❌ Then QUIT and restart the app completely")
            return
        }
        
        // Create and post Cmd+V key events immediately (no delay)
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key down event for 'V' with Command modifier
        if let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDownEvent.flags = .maskCommand
            keyDownEvent.post(tap: .cghidEventTap)
        }
        
        // Minimal delay between key down and up (reduced from 0.01 to 0.005)
        Thread.sleep(forTimeInterval: 0.005)
        
        // Key up event for 'V' with Command modifier
        if let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUpEvent.flags = .maskCommand
            keyUpEvent.post(tap: .cghidEventTap)
        }
        
        print("✅ Simulated paste keystroke (Cmd+V)")
    }
    
    private func processRecording() {
        // Get the recorded audio file
        guard let audioURL = audioRecorder.stopRecording() else {
            print("❌ No audio file to process")
            appState.setError(NSError(domain: "com.yappy", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to save audio recording"
            ]))
            return
        }
        
        print("📁 Audio file saved: \(audioURL.path)")
        
        // Process transcription asynchronously with highest priority
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            
            do {
                // Transcribe the audio
                print("🔄 Transcribing audio...")
                let transcription = try await self.transcriptionService.transcribe(audioURL: audioURL)
                
                // OPTIMIZATION: Paste immediately, don't wait for cleanup
                await MainActor.run {
                    // Copy to clipboard immediately
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(transcription, forType: .string)
                    
                    print("✅ Transcription copied to clipboard: \(transcription)")
                    
                    // Simulate Cmd+V to paste at cursor location (NOW with no delay!)
                    self.simulatePaste()
                    
                    // Update app state
                    self.appState.setTranscription(transcription)
                }
                
                // Clean up with Grok AFTER pasting (if enabled)
                // This runs in the background and doesn't block the paste
                if self.settings.cleanupEnabled {
                    print("🔄 Cleaning up transcription with Grok (post-paste)...")
                    do {
                        let cleanedTranscription = try await self.transcriptionService.cleanupTranscription(transcription)
                        
                        // Update the clipboard with cleaned version
                        await MainActor.run {
                            self.appState.setTranscription(cleanedTranscription)
                            print("✅ Cleanup successful (available for next paste): \(cleanedTranscription)")
                        }
                    } catch {
                        print("⚠️ Cleanup failed (original transcription was already pasted): \(error)")
                        // Not a critical error - the original transcription was already pasted
                    }
                }
                
                // Clean up the audio file
                self.audioRecorder.cleanup()
                
            } catch {
                print("❌ Transcription error: \(error.localizedDescription)")
                await MainActor.run {
                    self.appState.setError(error)
                }
                
                // Clean up even on error
                self.audioRecorder.cleanup()
            }
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            // Create custom orange waveform icon programmatically
            let iconImage = createWaveformIcon(size: NSSize(width: 18, height: 18))
            button.image = iconImage
        }

        // Create menu
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "About Yappy", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    // MARK: - Menu Actions

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showSettings() {
        // If we already have a settings window, just bring it to front
        if let windowController = settingsWindowController {
            windowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create the settings window
        let settingsView = SettingsView(settings: settings)
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 400))
        window.center()
        
        // Create window controller
        let windowController = NSWindowController(window: window)
        settingsWindowController = windowController
        
        // Show the window
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Clean up when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindowController = nil
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
    
    // MARK: - Icon Drawing
    
    /// Creates a custom orange waveform icon for the menu bar
    private func createWaveformIcon(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            // Orange gradient colors
            let orange = NSColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1.0)  // #FF6B35
            
            // Draw 5 bars with varying heights
            let barWidth: CGFloat = 2.5
            let spacing: CGFloat = 1.0
            let totalWidth = 5 * barWidth + 4 * spacing
            let startX = (rect.width - totalWidth) / 2
            
            // Bar heights as percentages of total height
            let heights: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]
            let maxHeight = rect.height * 0.8
            let centerY = rect.height / 2
            
            orange.setFill()
            
            for (index, heightPercent) in heights.enumerated() {
                let barHeight = maxHeight * heightPercent
                let x = startX + CGFloat(index) * (barWidth + spacing)
                let y = centerY - barHeight / 2
                
                let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                path.fill()
            }
            
            return true
        }
        
        image.isTemplate = false  // Keep the orange color
        return image
    }
}
