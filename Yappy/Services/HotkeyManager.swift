//
//  HotkeyManager.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation
import ApplicationServices
import Combine

/// Errors that can occur during hotkey management.
enum HotkeyError: LocalizedError {
    case accessibilityPermissionDenied
    case eventTapCreationFailed
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permissions are required to detect global hotkeys. Please enable accessibility access in System Settings > Privacy & Security > Accessibility."
        case .eventTapCreationFailed:
            return "Failed to create keyboard event monitor. Please check system permissions."
        case .invalidConfiguration:
            return "Invalid hotkey configuration."
        }
    }
}

/// Manages global hotkey detection for activating voice recording.
/// Uses CGEvent tap to monitor keyboard events system-wide, supporting both hold and double-tap activation modes.
final class HotkeyManager {
    // MARK: - Public Properties

    /// Callback invoked when the hotkey is activated (recording should start).
    var onActivate: (() -> Void)?

    /// Callback invoked when the hotkey is deactivated (recording should stop).
    var onDeactivate: (() -> Void)?

    // MARK: - Private Properties

    /// The event tap for monitoring keyboard events.
    private var eventTap: CFMachPort?

    /// The run loop source associated with the event tap.
    private var runLoopSource: CFRunLoopSource?

    /// Timestamp of the last right Command key down event (for double-tap detection).
    private var lastRightCommandDown: Date?

    /// Flag indicating if the right modifier key is currently held down.
    private var isRightModifierHeld: Bool = false

    /// Reference to the settings object to determine current hotkey configuration.
    private let settings: Settings

    /// Cancellable storage for Combine subscriptions.
    private var cancellables = Set<AnyCancellable>()

    /// The currently monitored key code based on settings.
    private var monitoredKeyCode: UInt16 {
        switch settings.hotkeyOption {
        case .rightCommandHold, .rightCommandDoubleTap:
            return KeyCode.rightCommand
        case .rightOptionHold:
            return KeyCode.rightOption
        }
    }

    /// Flag to track if we're currently in an active recording session (for double-tap mode).
    private var isRecordingActive: Bool = false

    // MARK: - Initialization

    /// Initializes the hotkey manager with the provided settings.
    ///
    /// - Parameter settings: The application settings object containing hotkey configuration.
    init(settings: Settings) {
        self.settings = settings
        observeSettingsChanges()
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Starts monitoring for hotkey events.
    /// Requires accessibility permissions to function.
    ///
    /// - Throws: `HotkeyError.accessibilityPermissionDenied` if permissions are not granted.
    /// - Throws: `HotkeyError.eventTapCreationFailed` if the event tap cannot be created.
    func start() throws {
        // Stop any existing event tap
        stop()

        // Check accessibility permissions
        guard Self.checkAccessibilityPermissions() else {
            // Prompt user to grant permissions
            Self.requestAccessibilityPermissions()
            throw HotkeyError.accessibilityPermissionDenied
        }

        // Create event tap to monitor flagsChanged events
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.eventTapCreationFailed
        }

        eventTap = tap

        // Create run loop source and add to current run loop
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        self.runLoopSource = runLoopSource

        // Enable the event tap
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Stops monitoring for hotkey events and releases resources.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)

            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }

            eventTap = nil
            runLoopSource = nil
        }

        // Reset state
        lastRightCommandDown = nil
        isRightModifierHeld = false
        isRecordingActive = false
    }

    /// Checks if accessibility permissions are granted.
    ///
    /// - Returns: `true` if the app has accessibility permissions, `false` otherwise.
    static func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Requests accessibility permissions from the user.
    /// This will show the system prompt to open System Settings.
    static func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Private Methods

    /// Observes changes to settings and restarts the hotkey manager when needed.
    private func observeSettingsChanges() {
        settings.$hotkeyOption
            .dropFirst() // Skip initial value
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Restart monitoring with new settings
                if self.eventTap != nil {
                    try? self.start()
                }
            }
            .store(in: &cancellables)
    }

    /// Handles incoming keyboard events from the event tap.
    ///
    /// - Parameters:
    ///   - proxy: The event tap proxy.
    ///   - type: The type of event.
    ///   - event: The keyboard event.
    /// - Returns: The event to pass through (unmodified).
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        // Handle event tap disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Only process flagsChanged events for modifier keys
        if type == .flagsChanged {
            handleFlagsChanged(event: event)
        } else if type == .keyDown {
            // Monitor for actual keyDown events to differentiate right from left modifiers
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            handleKeyDown(keyCode: UInt16(keyCode), event: event)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Handles flags changed events (modifier key state changes).
    ///
    /// - Parameter event: The keyboard event.
    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags

        // Determine if the monitored modifier is currently pressed
        let isModifierPressed: Bool
        switch settings.hotkeyOption {
        case .rightCommandHold, .rightCommandDoubleTap:
            isModifierPressed = flags.contains(.maskCommand)
        case .rightOptionHold:
            isModifierPressed = flags.contains(.maskAlternate)
        }

        // Detect key down vs key up by comparing with current state
        if isModifierPressed && !isRightModifierHeld {
            handleModifierDown()
        } else if !isModifierPressed && isRightModifierHeld {
            handleModifierUp()
        }

        isRightModifierHeld = isModifierPressed
    }

    /// Handles keyDown events to differentiate right from left modifier keys.
    ///
    /// - Parameters:
    ///   - keyCode: The virtual key code.
    ///   - event: The keyboard event.
    private func handleKeyDown(keyCode: UInt16, event: CGEvent) {
        // Only process if it matches our monitored key
        guard keyCode == monitoredKeyCode else { return }

        // This is specifically the right modifier key
        if !isRightModifierHeld {
            handleModifierDown()
            isRightModifierHeld = true
        }
    }

    /// Handles modifier key down events based on the current hotkey mode.
    private func handleModifierDown() {
        let now = Date()

        switch settings.hotkeyOption {
        case .rightCommandDoubleTap:
            handleDoubleTapDown(at: now)

        case .rightCommandHold, .rightOptionHold:
            handleHoldDown()
        }
    }

    /// Handles modifier key up events based on the current hotkey mode.
    private func handleModifierUp() {
        switch settings.hotkeyOption {
        case .rightCommandDoubleTap:
            handleDoubleTapUp()

        case .rightCommandHold, .rightOptionHold:
            handleHoldUp()
        }
    }

    /// Handles double-tap key down logic.
    ///
    /// - Parameter now: The current timestamp.
    private func handleDoubleTapDown(at now: Date) {
        if let lastDown = lastRightCommandDown {
            let timeSinceLastTap = now.timeIntervalSince(lastDown)

            if timeSinceLastTap <= Constants.doubleTapThreshold {
                // Valid double tap - toggle recording state
                if isRecordingActive {
                    // Second tap while recording - stop recording
                    isRecordingActive = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onDeactivate?()
                    }
                } else {
                    // Second tap while not recording - start recording
                    isRecordingActive = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onActivate?()
                    }
                }

                // Reset the double-tap detection
                lastRightCommandDown = nil
            } else {
                // Too slow - reset and start new potential double-tap sequence
                lastRightCommandDown = now
            }
        } else {
            // First tap in a potential double-tap sequence
            lastRightCommandDown = now
        }
    }

    /// Handles double-tap key up logic.
    private func handleDoubleTapUp() {
        // In double-tap mode, we don't stop recording on key up
        // Recording continues until the next double-tap
    }

    /// Handles hold mode key down.
    private func handleHoldDown() {
        guard !isRecordingActive else { return }

        isRecordingActive = true
        DispatchQueue.main.async { [weak self] in
            self?.onActivate?()
        }
    }

    /// Handles hold mode key up.
    private func handleHoldUp() {
        guard isRecordingActive else { return }

        isRecordingActive = false
        DispatchQueue.main.async { [weak self] in
            self?.onDeactivate?()
        }
    }
}
