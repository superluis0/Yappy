//
//  YappyApp.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import SwiftUI

/// Main application entry point for Yappy.
/// This is a menu bar app that runs without a dock icon (LSUIElement = true).
@main
struct YappyApp: App {
    // MARK: - App Delegate

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Log to tmp immediately
        let logMessage = "\(Date()): 🚀 YappyApp.init() called\n"
        let logURL = URL(fileURLWithPath: "/tmp/yappy_debug.txt")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(logMessage.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? logMessage.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 0, height: 0)
    }
}
