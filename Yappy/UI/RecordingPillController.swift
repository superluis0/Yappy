//
//  RecordingPillController.swift
//  Yappy
//

import AppKit
import SwiftUI

/// Owns the floating pill panel. The panel exists only while recording or
/// processing — it never steals focus, never accepts mouse events, and is
/// fully hidden (ordered out) when idle.
final class RecordingPillController {
    private var panel: NSPanel?
    private let appState: AppState
    private let settings: Settings

    init(appState: AppState, settings: Settings) {
        self.appState = appState
        self.settings = settings
    }

    // MARK: - Visibility

    /// Builds the panel ahead of time (without showing it) so the first recording
    /// doesn't pay SwiftUI hosting-view construction at key-press. Call once, at
    /// launch, off the hot path. Idempotent.
    func prewarm() {
        if panel == nil { panel = makePanel() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A new session must never inherit recovery-mode interactivity: if the
        // user re-dictates DURING a click-to-copy window, the old task's
        // generation-gated teardown is skipped and a stale interactive panel
        // would swallow clicks at the bottom of the screen for the whole
        // session. Click-through is the default; recovery re-enables it.
        setInteractive(false)
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        // Always restore click-through so a later non-recovery show isn't sticky.
        setInteractive(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Only order out if nothing restarted in the meantime.
            if let self, !self.appState.isRecording, !self.appState.isProcessing {
                panel.orderOut(nil)
            }
        })
    }

    /// Flips whether the panel receives mouse events. Used only for
    /// click-to-copy recovery on insertion failures; default is click-through.
    func setInteractive(_ enabled: Bool) {
        panel?.ignoresMouseEvents = !enabled
    }

    // MARK: - Panel Setup

    /// The panel is larger than the visible capsule by `pillShadowMargin` on each
    /// side, giving the drop shadow transparent space to fade into.
    private static var panelSize: NSSize {
        NSSize(
            width: Constants.pillWidth + Constants.pillShadowMargin * 2,
            height: Constants.pillHeight + Constants.pillShadowMargin * 2
        )
    }

    private func makePanel() -> NSPanel {
        let size = Self.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.adoptYappyDarkAppearance()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // The pill's recovery click must never make this panel the key window:
        // a key panel steals the retry's synthetic Cmd+V from the target app
        // (same failure Voice Edit's card hit — "Paste NEVER CONFIRMED").
        panel.becomesKeyOnlyIfNeeded = true
        // canJoinAllSpaces keeps the pill on every Space (and fullScreenAuxiliary
        // shows it over full-screen apps). `.stationary` is deliberately NOT
        // included — it's for desktop-pinned windows and conflicts with
        // canJoinAllSpaces, leaving the pill invisible on non-primary Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: RecordingPillView(appState: appState, settings: settings))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        return panel
    }

    /// Bottom-center of the screen containing the mouse (where the user is working).
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let size = Self.panelSize
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        // Offset by the shadow margin so the visible capsule — not the larger
        // transparent panel — sits `pillBottomMargin` above the dock.
        let y = visible.minY + Constants.pillBottomMargin - Constants.pillShadowMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
