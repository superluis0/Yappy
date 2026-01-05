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
