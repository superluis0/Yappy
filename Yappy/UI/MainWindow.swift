//
//  MainWindow.swift
//  Yappy
//

import AppKit
import SwiftUI

// MARK: - Main Window Content

/// Sidebar navigation between Home (stats + history) and Settings.
struct MainWindowView: View {
    enum SidebarItem: String, CaseIterable, Identifiable {
        case home = "Home"
        case shortcuts = "Shortcuts"
        case dictionary = "Dictionary"
        case transforms = "Transforms"
        case modes = "Modes"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "house"
            case .shortcuts: return "text.badge.plus"
            case .dictionary: return "character.book.closed"
            case .transforms: return "wand.and.sparkles"
            case .modes: return "slider.horizontal.3"
            case .settings: return "gearshape"
            }
        }
    }

    @ObservedObject var settings: Settings
    @ObservedObject var history: HistoryStore
    @ObservedObject var shortcutStore: ShortcutStore
    @ObservedObject var dictionaryStore: DictionaryStore
    @ObservedObject var transformStore: TransformStore
    @ObservedObject var modeStore: ModeStore
    @ObservedObject var transcriptionService: ParakeetTranscriptionService
    let lmStudio: LMStudioService

    @State private var selection: SidebarItem = .home

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection {
            case .home:
                HomeView(history: history, settings: settings, shortcutStore: shortcutStore)
            case .shortcuts:
                ShortcutsView(store: shortcutStore)
            case .dictionary:
                DictionaryView(
                    store: dictionaryStore,
                    settings: settings,
                    transcriptionService: transcriptionService
                )
            case .transforms:
                TransformsView(store: transformStore, settings: settings)
            case .modes:
                ModesView(store: modeStore, settings: settings)
            case .settings:
                SettingsView(
                    settings: settings,
                    transcriptionService: transcriptionService,
                    lmStudio: lmStudio
                )
            }
        }
        .navigationTitle("Yappy")
    }
}

// MARK: - Window Controller

/// Hosts the main window. While the window is open the app shows a Dock icon
/// (`.regular` activation policy); when it closes the app returns to
/// menu-bar-only (`.accessory`).
final class MainWindowController: NSWindowController, NSWindowDelegate {
    convenience init(
        settings: Settings,
        history: HistoryStore,
        shortcutStore: ShortcutStore,
        dictionaryStore: DictionaryStore,
        transformStore: TransformStore,
        modeStore: ModeStore,
        transcriptionService: ParakeetTranscriptionService,
        lmStudio: LMStudioService
    ) {
        let view = MainWindowView(
            settings: settings,
            history: history,
            shortcutStore: shortcutStore,
            dictionaryStore: dictionaryStore,
            transformStore: transformStore,
            modeStore: modeStore,
            transcriptionService: transcriptionService,
            lmStudio: lmStudio
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 780, height: 480)
        // Don't let the hosting controller shrink the window to its content's
        // minimum; honor the size we set here.
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 880, height: 640))
        window.center()
        window.setFrameAutosaveName("YappyMainWindow")
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
