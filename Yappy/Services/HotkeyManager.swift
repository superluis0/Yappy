//
//  HotkeyManager.swift
//  Yappy
//

import Cocoa
import CoreGraphics

// MARK: - State Machine

/// Pure, testable state machine that turns modifier-key edges into recording actions.
struct HotkeyStateMachine {
    enum Edge {
        case down
        case up
    }

    enum Action: Equatable {
        case start
        case stop
        case cancel
        case none
    }

    let mode: HotkeyOption

    private(set) var isActive = false
    private var lastDownTime: TimeInterval = -.infinity
    private var lastUpTime: TimeInterval = -.infinity
    private var lastTapEndTime: TimeInterval = -.infinity
    private var keyIsDown = false

    init(mode: HotkeyOption) {
        self.mode = mode
    }

    mutating func handle(_ edge: Edge, at time: TimeInterval) -> Action {
        switch edge {
        case .down:
            // Key repeats and bounce: ignore a down while already down, or one
            // arriving immediately after the previous up.
            guard !keyIsDown else { return .none }
            guard time - lastUpTime >= Constants.hotkeyDebounceInterval else { return .none }
            keyIsDown = true
            lastDownTime = time
            return handleDown()

        case .up:
            guard keyIsDown else { return .none }
            keyIsDown = false
            lastUpTime = time
            return handleUp(at: time)
        }
    }

    /// Force-stops an active session (e.g. max-duration safety stop).
    mutating func deactivate() {
        isActive = false
    }

    /// Clears ALL transient state. Used when the event tap is re-enabled after the
    /// system disabled it: key edges may have been missed while it was off, which
    /// would otherwise leave `keyIsDown` stuck `true` and silently ignore every
    /// future press (the "hotkey stopped working after a while" bug).
    mutating func reset() {
        isActive = false
        keyIsDown = false
        lastDownTime = -.infinity
        lastUpTime = -.infinity
        lastTapEndTime = -.infinity
    }

    private mutating func handleDown() -> Action {
        switch mode {
        case .rightCommandHold, .rightOptionHold:
            guard !isActive else { return .none }
            isActive = true
            return .start
        case .rightCommandDoubleTap:
            return .none
        }
    }

    private mutating func handleUp(at time: TimeInterval) -> Action {
        switch mode {
        case .rightCommandHold, .rightOptionHold:
            guard isActive else { return .none }
            isActive = false
            // A press shorter than the minimum is an accidental tap.
            return (time - lastDownTime) < Constants.minRecordingDuration ? .cancel : .stop

        case .rightCommandDoubleTap:
            let holdDuration = time - lastDownTime
            guard holdDuration <= Constants.tapMaxDuration else { return .none }

            if isActive {
                isActive = false
                lastTapEndTime = -.infinity
                return .stop
            }

            if time - lastTapEndTime <= Constants.doubleTapWindow {
                isActive = true
                lastTapEndTime = -.infinity
                return .start
            }

            lastTapEndTime = time
            return .none
        }
    }
}

// MARK: - Hotkey Manager

/// Global hotkey detection via a single listen-only CGEvent tap on `.flagsChanged`.
/// Distinguishes left/right modifiers using device-dependent flag bits, ignores
/// key repeats, and re-enables the tap if the system disables it.
final class HotkeyManager {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var stateMachine: HotkeyStateMachine
    private var mode: HotkeyOption

    /// Device-dependent modifier flag bits (IOKit NX_DEVICE* masks).
    private enum DeviceFlag {
        static let rightCommand: UInt64 = 0x0000_0010
        static let rightOption: UInt64 = 0x0000_0040
    }

    init(mode: HotkeyOption) {
        self.mode = mode
        self.stateMachine = HotkeyStateMachine(mode: mode)
    }

    deinit {
        stop()
    }

    // MARK: - Configuration

    func updateMode(_ newMode: HotkeyOption) {
        guard newMode != mode else { return }
        mode = newMode
        stateMachine = HotkeyStateMachine(mode: newMode)
    }

    /// Force-stops an active session in the state machine (caller handles the recorder).
    func deactivate() {
        stateMachine.deactivate()
    }

    // MARK: - Event Tap

    /// Creates the event tap. Requires accessibility permission; returns false without it.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables taps that stall or when secure input changes. Re-enable
        // AND reset the state machine: an edge (e.g. the key-up) may have been missed
        // while the tap was off, which would otherwise leave `keyIsDown` stuck and
        // ignore every future press.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            stateMachine.reset()
            return
        }

        guard type == .flagsChanged else { return }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let deviceFlag: UInt64
        switch mode {
        case .rightCommandHold, .rightCommandDoubleTap:
            guard keycode == 54 else { return }
            deviceFlag = DeviceFlag.rightCommand
        case .rightOptionHold:
            guard keycode == 61 else { return }
            deviceFlag = DeviceFlag.rightOption
        }

        let isDown = event.flags.rawValue & deviceFlag != 0
        let action = stateMachine.handle(isDown ? .down : .up, at: CACurrentMediaTime())

        guard action != .none else { return }
        DispatchQueue.main.async { [weak self] in
            switch action {
            case .start: self?.onStart?()
            case .stop: self?.onStop?()
            case .cancel: self?.onCancel?()
            case .none: break
            }
        }
    }
}
