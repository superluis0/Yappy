//
//  AskHotkey.swift
//  Yappy
//
//  Dedicated listen-only CGEvent tap for the configurable "Ask" key
//  (AskHotkeyOption — Fn/Globe by default, or a right-side modifier). Kept
//  separate from HotkeyManager (which owns dictation on the device-flag
//  modifiers) so the dictation path is untouched.
//  Precedent: ScratchpadHotkey / EscapeInterceptor.
//
//  The tap is listen-only, so it NEVER consumes the Fn key — if the user has
//  the Globe key bound to something (emoji picker, Dictation), that still fires;
//  Settings surfaces a nudge to set "Press 🌐 to Do Nothing". AppDelegate only
//  calls start() when Ask is unlocked AND enabled.
//
//  `@unchecked Sendable`: all mutable state is touched only from the main run
//  loop (the tap source is installed on CFRunLoopGetMain) and the callbacks are
//  set on the main actor before start().
//

import CoreGraphics
import QuartzCore

/// Which key summons Answers. Fn/Globe is the classic default, but it is NOT
/// universally reachable: many external keyboards (Logitech and other
/// third-party boards) handle Fn entirely in firmware, so the press never
/// reaches macOS as `.maskSecondaryFn` — making hold-Fn literally impossible
/// there. Every alternative below is a real, OS-visible modifier on any
/// keyboard. All are flagsChanged events, so one tap serves them all.
enum AskHotkeyOption: String, CaseIterable, Codable, Identifiable {
    case fnGlobe = "Fn / Globe (Hold)"
    case rightControl = "Right Control (Hold)"
    case rightShift = "Right Shift (Hold)"
    case rightOption = "Right Option (Hold)"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// Short name for inline copy ("Hold ⌃ to ask").
    var shortName: String {
        switch self {
        case .fnGlobe: return "Fn"
        case .rightControl: return "Right ⌃"
        case .rightShift: return "Right ⇧"
        case .rightOption: return "Right ⌥"
        }
    }

    var keycode: Int64 {
        switch self {
        case .fnGlobe: return 63
        case .rightControl: return 62
        case .rightShift: return 60
        case .rightOption: return 61
        }
    }

    /// Interprets a flagsChanged event for THIS option's key.
    /// Returns nil when the event is some other key; otherwise whether the key
    /// is now down. Fn is tracked via the secondary-fn mask; the right-side
    /// modifiers via their IOKit device-dependent flag bits (same scheme as
    /// HotkeyManager's DeviceFlag).
    func downState(keycode: Int64, flags: CGEventFlags) -> Bool? {
        guard keycode == self.keycode else { return nil }
        switch self {
        case .fnGlobe: return flags.contains(.maskSecondaryFn)
        case .rightControl: return flags.rawValue & 0x0000_2000 != 0
        case .rightShift: return flags.rawValue & 0x0000_0004 != 0
        case .rightOption: return flags.rawValue & 0x0000_0040 != 0
        }
    }

    /// One key can serve one feature. Returns a user-facing reason when this
    /// Ask key collides with the dictation key or Voice Edit's fixed Right ⌥ —
    /// the caller leaves the Ask tap disarmed and Settings shows the reason.
    func conflict(dictation: HotkeyOption, voiceEditEnabled: Bool) -> String? {
        switch self {
        case .fnGlobe, .rightShift:
            return nil
        case .rightControl:
            return dictation == .rightControlHold
                ? "Right Control is your dictation key — pick a different one."
                : nil
        case .rightOption:
            if dictation == .rightOptionHold {
                return "Right Option is your dictation key — pick a different one."
            }
            return voiceEditEnabled
                ? "Right Option belongs to Voice Edit — pick a different one."
                : nil
        }
    }
}

final class AskHotkey: @unchecked Sendable {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Reassigning the whole struct is the reset mechanism.
    private var machine = AskHotkeyStateMachine()
    /// The key this tap listens for. Main-thread only, like the callbacks.
    private var option: AskHotkeyOption = .fnGlobe

    deinit { stop() }

    /// Installs the tap. Returns true if created (or already running), false if
    /// Accessibility trust has not been granted yet.
    @discardableResult
    func start() -> Bool {
        let trusted = AXIsProcessTrusted()
        VLog.hotkey("AskHotkey.start() — AXIsProcessTrusted=\(trusted)")

        guard eventTap == nil else {
            VLog.hotkey("AskHotkey.start() — tap already active, no-op")
            return true
        }
        guard trusted else {
            VLog.hotkey("AskHotkey.start() — not trusted, tap NOT created")
            return false
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: askHotkeyEventCallback,
            userInfo: refcon
        ) else {
            VLog.hotkey("AskHotkey.start() — tapCreate returned nil (SIP / secure input?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        VLog.hotkey("AskHotkey CGEvent tap created — listening for keycode \(option.keycode) (\(option.shortName))")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        // Reset the machine so a re-arm starts clean.
        machine = AskHotkeyStateMachine()
    }

    var isRunning: Bool { eventTap != nil }

    /// Switches which key the tap listens for. Resets the hold state so a
    /// half-pressed old key can't leak a stop/cancel onto the new one.
    func updateOption(_ newOption: AskHotkeyOption) {
        guard newOption != option else { return }
        option = newOption
        machine = AskHotkeyStateMachine()
        VLog.hotkey("AskHotkey option → \(newOption.rawValue)")
    }

    /// Force-resets the hold state — used when a session is aborted out-of-band
    /// (Escape) so the eventual Fn key-up can't fire a spurious stop.
    func deactivate() {
        _ = machine.deactivate()
    }

    // Called from the C callback with the bridged self.
    fileprivate func handle(type: CGEventType, event: CGEvent) {
        // The system disables taps that stall or when secure input becomes
        // active. Re-enable and reset the state machine so a missed key-up
        // can't leave the hold "stuck down".
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
            VLog.hotkey("AskHotkey tap disabled by \(reason) — re-enabling + resetting")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            machine = AskHotkeyStateMachine()
            return
        }

        guard type == .flagsChanged else { return }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // Only the configured Ask key; every other flags change is ignored.
        guard let isDown = option.downState(keycode: keycode, flags: event.flags) else { return }

        let action = machine.handle(isDown ? .down : .up, at: CACurrentMediaTime())
        guard action != .none else { return }

        DispatchQueue.main.async { [weak self] in
            switch action {
            case .start:  self?.onStart?()
            case .stop:   self?.onStop?()
            case .cancel: self?.onCancel?()
            case .none:   break
            }
        }
    }
}

// MARK: - C callback (must be a free function)

private func askHotkeyEventCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<AskHotkey>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
