//
//  ScratchpadController.swift
//  Yappy
//

import AppKit
import CoreGraphics
import SwiftUI

/// Owns the floating Scratchpad panel — an interactive, always-on-top notepad
/// that can become key so the user can type and dictate into it. Unlike the
/// recording pill, it accepts focus and persists while other apps are active.
@MainActor
final class ScratchpadController {
    private var panel: NSPanel?
    private let store: NotesStore

    init(store: NotesStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Summon if hidden, dismiss if showing.
    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        store.flush() // write any pending note edit before the panel goes away
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scratchpad"
        panel.isFloatingPanel = true
        panel.level = .floating
        // Stay put when another app takes focus (sticky-note behavior) and ride
        // along across Spaces / over full-screen apps.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("YappyScratchpad")
        if panel.frame.origin == .zero { panel.center() }

        let hosting = NSHostingView(rootView: ScratchpadView(store: store))
        panel.contentView = hosting
        return panel
    }
}

/// Global, consuming key-down tap for the Scratchpad summon hotkey (⌥⇧S). The
/// existing HotkeyManager only handles modifier keys (flagsChanged); a plain key
/// chord needs a key-down tap. Runs in `.defaultTap` so the matched combo is
/// swallowed and never types a character into the focused app. Requires the same
/// Accessibility permission as the other taps.
final class ScratchpadHotkey {
    var onTrigger: (() -> Void)?

    /// Fired (async, main) for every REAL user keyDown — synthetic events posted
    /// by Yappy itself (tagged with `TextInserter.syntheticEventTag`) are
    /// excluded. Piggybacks on this always-on tap so `TextInserter` can learn
    /// the caret context moved, without adding another event tap. The callback
    /// receives no key information — only that a keystroke happened.
    var onUserKeyDown: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let hotkey = Unmanaged<ScratchpadHotkey>.fromOpaque(refcon).takeUnretainedValue()
                return hotkey.handle(type: type, event: event)
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if the system disabled the tap (stall / secure input).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Yappy's own synthetic keystrokes (the paste, Return, voice-edit
        // selection keys) pass through untouched and never count as user input.
        if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }
        DispatchQueue.main.async { [weak self] in self?.onUserKeyDown?() }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let optionDown = flags.contains(.maskAlternate)
        let shiftDown = flags.contains(.maskShift)
        let commandDown = flags.contains(.maskCommand)
        let controlDown = flags.contains(.maskControl)

        // Exactly ⌥⇧S — no Command or Control mixed in.
        guard keycode == Constants.scratchpadKeyCode,
              optionDown, shiftDown, !commandDown, !controlDown else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
        return nil // consume, so ⌥⇧S doesn't type a character
    }
}
