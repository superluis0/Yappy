//
//  YappyApp.swift
//  Yappy
//

import SwiftUI

/// Main application entry point. Yappy is a menu bar app (LSUIElement);
/// windows — the main window, recording pill, and first-run setup — are all
/// managed by AppDelegate, so no SwiftUI window scenes are declared here.
@main
struct YappyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // An empty SwiftUI Settings scene satisfies the Scene requirement
        // without creating any visible window.
        SwiftUI.Settings {
            EmptyView()
        }
    }
}
