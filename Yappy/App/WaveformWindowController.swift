//
//  WaveformWindowController.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Cocoa
import SwiftUI

/// Manages the floating waveform window that appears during recording.
/// Positions the window at the bottom center of the screen, above the dock.
final class WaveformWindowController {
    // MARK: - Properties
    
    private var window: NSWindow?
    private let appState: AppState
    
    // MARK: - Initialization
    
    init(appState: AppState) {
        self.appState = appState
        // Initialize window immediately to be persistent
        setupWindow()
    }
    
    // MARK: - Public Methods
    
    /// Ensures the waveform window is visible and correctly positioned.
    func show() {
        if window == nil {
            setupWindow()
        }
        window?.orderFrontRegardless()
    }
    
    /// Hides the waveform window (optional, usually stays visible now).
    func hide() {
        // In the new persistent model, we might not want to hide it completely,
        // but we'll leave it for now in case we need a full hide.
        window?.orderOut(nil)
    }
    
    // MARK: - Private Methods
    
    private func setupWindow() {
        guard window == nil else { return }
        
        // Create the SwiftUI view
        let waveformView = WaveformView(appState: appState)
        let hostingView = NSHostingView(rootView: waveformView)
        
        // Create the window (NSPanel for non-activating behavior)
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 250, // Slightly wider for safety
                height: 100 // Taller to accommodate shadows and transitions
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Configure window properties
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = false // Handled by SwiftUI
        panel.contentView = hostingView
        panel.ignoresMouseEvents = true // Don't block clicks to apps behind it
        
        // Position at bottom center of screen
        updatePosition(for: panel)
        
        window = panel
        panel.orderFrontRegardless()
        
        print("📊 Persistent Waveform window initialized")
    }
    
    private func updatePosition(for panel: NSWindow) {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 250
            let windowHeight: CGFloat = 100
            
            let x = screenFrame.midX - (windowWidth / 2)
            let y = screenFrame.minY + 10 // Just above the dock
            
            panel.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
        }
    }
}
