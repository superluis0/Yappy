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
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var whatsNewPresenter: WhatsNewPresenter

    @State private var selection: SidebarItem = .home
    /// Per-session dismissal of the update banner ("Later"). The menu-bar item and
    /// icon badge remain as the always-on reminder; the banner returns next launch.
    @State private var updateBannerDismissed = false

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
                    lmStudio: lmStudio,
                    updateChecker: updateChecker
                )
            }
        }
        .navigationTitle("Yappy")
        // A friendly notice that floats above the window when a new version is
        // ready — the in-app counterpart to Sparkle's (now suppressed) modal.
        // "Update Now" hands off to Sparkle's signed, one-click install flow.
        .overlay(alignment: .top) {
            if let release = updateChecker.available, !updateBannerDismissed {
                UpdateBanner(
                    version: release.version,
                    onUpdate: { updateChecker.checkForUpdates() },
                    onLater: { updateBannerDismissed = true }
                )
                .padding(.horizontal, 16)
                .padding(.top, 38)
                .zIndex(10)
            }
        }
        // Shown once after the app updates to a version with release notes
        // (presented by AppDelegate via the shared presenter).
        .sheet(item: $whatsNewPresenter.entry) { entry in
            WhatsNewSheet(entry: entry) { whatsNewPresenter.entry = nil }
        }
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
        lmStudio: LMStudioService,
        updateChecker: UpdateChecker,
        whatsNewPresenter: WhatsNewPresenter
    ) {
        let view = MainWindowView(
            settings: settings,
            history: history,
            shortcutStore: shortcutStore,
            dictionaryStore: dictionaryStore,
            transformStore: transformStore,
            modeStore: modeStore,
            transcriptionService: transcriptionService,
            lmStudio: lmStudio,
            updateChecker: updateChecker,
            whatsNewPresenter: whatsNewPresenter
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

// MARK: - Update Banner

/// The floating "Update available" notice shown at the top of the main window when
/// Sparkle finds a newer release. Accent-tinted and gently animated in (respecting
/// Reduce Motion). "Update Now" hands off to Sparkle's signed, one-click installer.
private struct UpdateBanner: View {
    let version: String
    var onUpdate: () -> Void
    var onLater: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available")
                    .font(.subheadline.weight(.semibold))
                Text("Yappy \(version) is ready — installs in a tap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Later", action: onLater)
                .buttonStyle(.bordered)
            Button(action: onUpdate) {
                Label("Update Now", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .offset(y: (shown || reduceMotion) ? 0 : -90)
        .opacity((shown || reduceMotion) ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { shown = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { shown = true }
        }
    }
}

// MARK: - What's New Sheet

/// A one-time "What's New in Yappy X.Y" card shown after the app updates to a
/// version with release notes (see `WhatsNew`). Plain, local, no network.
private struct WhatsNewSheet: View {
    let entry: WhatsNew.Entry
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 28)
                Text("What's New in Yappy \(entry.version)")
                    .font(.title2.weight(.bold))
                Text(entry.headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(entry.highlights) { highlight in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: highlight.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 26, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(highlight.title).font(.headline)
                                Text(highlight.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }

            Divider()
            Button("Continue", action: onDismiss)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(16)
        }
        .frame(width: 460, height: 520)
    }
}
