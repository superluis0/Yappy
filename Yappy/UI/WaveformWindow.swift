//
//  WaveformWindow.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import SwiftUI
import AppKit

/// Floating overlay window that displays the waveform visualization.
/// Appears above all other windows and is click-through for non-intrusive operation.
final class WaveformWindow: NSPanel {
    // MARK: - Properties

    private let appState: AppState
    private var hostingView: NSHostingView<WaveformView>?

    // MARK: - Constants

    private let fadeInDuration: TimeInterval = 0.2
    private let fadeOutDuration: TimeInterval = 0.15
    private let bottomMargin: CGFloat = 30

    // MARK: - Initialization

    /// Creates a new waveform window.
    ///
    /// - Parameter appState: The application state to observe for waveform data.
    init(appState: AppState) {
        self.appState = appState

        // Initialize the panel with a dummy frame (will be updated in setup)
        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Constants.waveformWindowWidth,
                height: Constants.waveformWindowHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupContent()
        updatePosition()
    }

    // MARK: - Public Methods

    /// Shows the waveform window with a fade-in animation.
    func show() {
        // Ensure window is on screen
        updatePosition()

        // Start fully transparent
        alphaValue = 0.0

        // Make window visible
        orderFrontRegardless()

        // Fade in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1.0
        }
    }

    /// Hides the waveform window with a fade-out animation.
    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// Updates the window position to be centered at the bottom of the main screen.
    /// Call this when screen configuration changes.
    func updatePosition() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowWidth = Constants.waveformWindowWidth
        let windowHeight = Constants.waveformWindowHeight

        // Calculate bottom-center position
        let xPosition = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let yPosition = screenFrame.origin.y + bottomMargin

        let newFrame = NSRect(
            x: xPosition,
            y: yPosition,
            width: windowWidth,
            height: windowHeight
        )

        setFrame(newFrame, display: true)
    }

    // MARK: - Private Methods

    /// Configures the window properties for floating, click-through behavior.
    private func setupWindow() {
        // Window appearance
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Floating behavior
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Click-through and non-activating
        isMovable = false
        ignoresMouseEvents = true

        // Start hidden
        alphaValue = 0.0
    }

    /// Sets up the SwiftUI content view.
    private func setupContent() {
        let waveformView = WaveformView(appState: appState)
        let hostingView = NSHostingView(rootView: waveformView)

        // Configure hosting view
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        contentView = hostingView
        self.hostingView = hostingView
    }
}

// MARK: - Screen Change Notifications

extension WaveformWindow {
    /// Observes screen configuration changes to update position.
    func startObservingScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Stops observing screen configuration changes.
    func stopObservingScreenChanges() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        updatePosition()
    }
}
