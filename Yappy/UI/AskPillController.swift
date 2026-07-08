//
//  AskPillController.swift
//  Yappy
//
//  Owns the floating Ask pill panel. Separate from RecordingPillController so
//  the dictation pill is untouched; the two never coexist (Ask and dictation
//  are mutually exclusive). The panel is bottom-centered, nonactivating (keeps
//  focus in the app you were in), and grows upward as the answer streams in.
//  It becomes click-through EXCEPT while interactive controls (Stop / ✕ /
//  selectable answer) are visible.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AskPillController {
    private var panel: NSPanel?
    private let controller: AskController
    private var cancellables: Set<AnyCancellable> = []
    private var activeScreen: NSScreen?
    private var lastContentSize: CGSize = .zero
    /// Must exceed the card's shadow reach (radius 22 + y-offset 9 ≈ 31pt),
    /// or the shadow clips at the invisible panel edge as a visible halo.
    private let shadowMargin: CGFloat = 40
    /// Extra height above the dictation pill's baseline: the Ask card is much
    /// taller than the 44pt pill, so at the same margin it visually crowds the
    /// Dock.
    private let bottomLift: CGFloat = 28

    init(controller: AskController) {
        self.controller = controller
        // React to run changes: show/hide, reposition, and toggle mouse events.
        controller.$run
            // DispatchQueue.main (not RunLoop.main): keeps the pill responsive during scroll/menu event-tracking, while still deferring past the @Published willSet.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] run in self?.reflect(run) }
            .store(in: &cancellables)
    }

    /// Build the panel ahead of first use, off the hot path.
    func prewarm() {
        if panel == nil { panel = makePanel() }
    }

    // MARK: - State reflection

    private func reflect(_ run: AskRun?) {
        let status = run?.status ?? .idle
        let visible = run != nil && status != .idle
        if visible {
            showIfNeeded()
            updateMouseEvents(status)
        } else {
            hide()
        }
    }

    private func updateMouseEvents(_ status: AskRunStatus) {
        // Click-through while preparing/listening/transcribing (no controls yet);
        // clickable once the Stop button / dismiss / selectable answer are on screen.
        let interactive = !(status == .idle || status == .preparing || status == .listening || status == .transcribing)
        panel?.ignoresMouseEvents = !interactive
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 60),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: AskPillView(
            controller: controller,
            onSizeChange: { [weak self] size in self?.onContentSize(size) }
        ))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func showIfNeeded() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        activeScreen = screenForMouse()
        resizePanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit invokes animation completions on the main thread; hop back
            // onto the actor explicitly to satisfy strict concurrency.
            Task { @MainActor [weak self] in
                if self?.controller.run == nil { panel.orderOut(nil) }
            }
        })
    }

    // MARK: - Sizing (grows upward from a fixed bottom edge)

    private func onContentSize(_ size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        let changed = abs(size.width - lastContentSize.width) > 0.5
            || abs(size.height - lastContentSize.height) > 0.5
        lastContentSize = size
        if changed { resizePanel() }
    }

    private func resizePanel() {
        guard let panel else { return }
        let screen = activeScreen ?? screenForMouse() ?? NSScreen.main
        guard let screen else { return }
        let size = lastContentSize == .zero ? CGSize(width: 380, height: 60) : lastContentSize
        let visible = screen.visibleFrame
        // Never wider than the screen minus breathing room, whatever the card asks.
        let w = min(size.width + shadowMargin * 2, visible.width - 24)
        let h = size.height + shadowMargin * 2
        let x = visible.midX - w / 2
        // Fixed bottom edge; increasing height extends the top upward.
        let y = visible.minY + Constants.pillBottomMargin + bottomLift - shadowMargin
        let frame = NSRect(x: x, y: y, width: w, height: h)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: false)
        }
    }

    private func screenForMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
