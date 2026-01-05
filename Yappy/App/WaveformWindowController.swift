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
    }
    
    // MARK: - Public Methods
    
    /// Shows the waveform window at the bottom center of the screen.
    func show() {
        guard window == nil else {
            window?.orderFrontRegardless()
            return
        }
        
        // Create the SwiftUI view
        let waveformView = WaveformView(appState: appState)
        let hostingView = NSHostingView(rootView: waveformView)
        
        // Create the window
        let panel = NSPanel(
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
        
        // Configure window properties
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = true
        panel.contentView = hostingView
        
        // Position at bottom center of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth = Constants.waveformWindowWidth
            _ = Constants.waveformWindowHeight
            
            let x = screenFrame.midX - (windowWidth / 2)
            let y = screenFrame.minY + 20 // 20 points above the dock
            
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window = panel
        panel.orderFrontRegardless()
        
        print("📊 Waveform window shown")
    }
    
    /// Hides and removes the waveform window.
    func hide() {
        window?.orderOut(nil)
        window = nil
        print("📊 Waveform window hidden")
    }
}
