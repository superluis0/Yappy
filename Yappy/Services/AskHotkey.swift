//
//  AskHotkey.swift
//  Yappy
//
//  Dedicated listen-only CGEvent tap for the Fn/Globe "Ask" key (keycode 63,
//  tracked via .maskSecondaryFn). Kept separate from HotkeyManager (which owns
//  dictation on the device-flag modifiers) so the dictation path is untouched.
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

final class AskHotkey: @unchecked Sendable {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Reassigning the whole struct is the reset mechanism.
    private var machine = AskHotkeyStateMachine()

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
        VLog.hotkey("AskHotkey CGEvent tap created — listening for keycode 63 (Fn)")
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
        // Fn (Globe) key ONLY — keycode 63, tracked via the secondary-fn flag.
        guard keycode == 63 else { return }
        let isDown = event.flags.contains(.maskSecondaryFn)

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
