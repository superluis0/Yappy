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

    init(appState: AppState) {
        self.appState = appState
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // canJoinAllSpaces keeps the pill on every Space (and fullScreenAuxiliary
        // shows it over full-screen apps). `.stationary` is deliberately NOT
        // included — it's for desktop-pinned windows and conflicts with
        // canJoinAllSpaces, leaving the pill invisible on non-primary Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: RecordingPillView(appState: appState))
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
