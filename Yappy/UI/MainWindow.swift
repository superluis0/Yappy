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
        case modes = "Modes"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "house"
            case .shortcuts: return "text.badge.plus"
            case .dictionary: return "character.book.closed"
            case .modes: return "slider.horizontal.3"
            case .settings: return "gearshape"
            }
        }
    }

    @ObservedObject var settings: Settings
    @ObservedObject var history: HistoryStore
    @ObservedObject var shortcutStore: ShortcutStore
    @ObservedObject var dictionaryStore: DictionaryStore
    @ObservedObject var modeStore: ModeStore
    @ObservedObject var transcriptionService: ParakeetTranscriptionService
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var whatsNewPresenter: WhatsNewPresenter

    @State private var selection: SidebarItem = .home
    /// Per-session dismissal of the update banner ("Later"). The menu-bar item and
    /// icon badge remain as the always-on reminder; the banner returns next launch.
    @State private var updateBannerDismissed = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 214, ideal: 226, max: 248)
        } detail: {
            ZStack {
                GlassBackdrop()
                detailContent
            }
        }
        .navigationTitle("")
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarBrandHeader()
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 16)

            Text("Workspace")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Brand.ink4)
                .padding(.horizontal, 18).padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(SidebarItem.allCases) { item in
                    SidebarNavRow(item: item, isSelected: selection == item) { selection = item }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

            ModelStatusFooter(settings: settings, transcriptionService: transcriptionService)
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.063)
                RadialGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                               center: .top, startRadius: 0, endRadius: 240)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .home:
            HomeView(history: history, settings: settings, shortcutStore: shortcutStore)
        case .shortcuts:
            ShortcutsView(store: shortcutStore)
        case .dictionary:
            DictionaryView(store: dictionaryStore, settings: settings, transcriptionService: transcriptionService)
        case .modes:
            ModesView(store: modeStore, settings: settings)
        case .settings:
            SettingsView(settings: settings, transcriptionService: transcriptionService, updateChecker: updateChecker,
                         onShowReleaseNotes: { whatsNewPresenter.entry = WhatsNew.current ?? WhatsNew.latest })
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
        modeStore: ModeStore,
        transcriptionService: ParakeetTranscriptionService,
        updateChecker: UpdateChecker,
        whatsNewPresenter: WhatsNewPresenter
    ) {
        let view = MainWindowView(
            settings: settings,
            history: history,
            shortcutStore: shortcutStore,
            dictionaryStore: dictionaryStore,
            modeStore: modeStore,
            transcriptionService: transcriptionService,
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

// MARK: - Bespoke design system (shared)

/// Brand ink ramp + status colors used across the redesigned window.
enum Brand {
    static let ink   = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let ink2  = Color(red: 0.84, green: 0.84, blue: 0.88)
    static let ink3  = Color(red: 0.66, green: 0.66, blue: 0.72)
    static let ink4  = Color(red: 0.50, green: 0.50, blue: 0.57)
    static let ready  = Color(red: 0.22, green: 0.83, blue: 0.60)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)
}

extension View {
    /// Applies the Liquid Glass material (macOS 26+) clipped to a rounded rect, with a
    /// graceful `.regularMaterial` + hairline fallback on macOS 14–25 (the app still
    /// supports them). Encapsulated so the glass API lives in exactly one place.
    func glassPanel(cornerRadius: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

private struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // `Glass` / `glassEffect` are macOS 26 SDK symbols, so they must be gated at
        // COMPILE time, not just runtime (`#available` alone fails to build on an older
        // SDK). `canImport(FoundationModels)` is the project's existing proxy for
        // "building against the macOS 26 SDK" (both ship together) — older SDKs (e.g.
        // CI on macos-latest) compile the material fallback instead.
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            content.glassEffect(glassConfig, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
        #else
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        #endif
    }

    #if canImport(FoundationModels)
    /// Builds the `Glass` config imperatively, outside any `@ViewBuilder` context.
    @available(macOS 26.0, *)
    private var glassConfig: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
    #endif
}

/// Soft branded backdrop the glass surfaces refract — warm orange + cool blooms over
/// near-black, so dark-glass-on-dark reads with depth instead of flat.
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.043, blue: 0.055)
            bloom(Color(red: 1.0,  green: 0.42, blue: 0.21), .topLeading,     0.16)
            bloom(Color(red: 0.36, green: 0.55, blue: 1.0),  .bottomTrailing, 0.14)
            bloom(Color(red: 0.22, green: 0.82, blue: 0.66), .bottomLeading,  0.09)
            bloom(Color(red: 0.74, green: 0.35, blue: 1.0),  .topTrailing,    0.10)
        }
        .ignoresSafeArea()
    }
    private func bloom(_ color: Color, _ center: UnitPoint, _ opacity: Double) -> some View {
        RadialGradient(colors: [color.opacity(opacity), .clear], center: center, startRadius: 0, endRadius: 580)
    }
}

/// A rounded Liquid Glass card wrapping arbitrary content with standard padding —
/// the shared building block for every tab's content groups.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var tint: Color? = nil
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: cornerRadius, tint: tint)
    }
}

/// An accent icon-chip + title header used above cards/sections across the window.
struct SectionLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: 23, height: 23)
                .overlay(Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sidebar components

private struct SidebarBrandHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.56, blue: 0.36), Color.accentColor],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "waveform").font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
                .shadow(color: Color.accentColor.opacity(0.45), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text("Yappy").font(.system(size: 17, weight: .bold)).foregroundStyle(Brand.ink)
                Text("v\(Self.version)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.ink4)
            }
            Spacer(minLength: 0)
        }
    }
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2"
    }
}

private struct SidebarNavRow: View {
    let item: MainWindowView.SidebarItem
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.06)))
                    .frame(width: 29, height: 29)
                    .overlay(Image(systemName: item.icon).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : Brand.ink3))
                    .shadow(color: isSelected ? Color.accentColor.opacity(0.45) : .clear, radius: 6, y: 2)
                Text(item.rawValue).font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(isSelected ? Brand.ink : Brand.ink3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14)))
            } else if hovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05))
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ModelStatusFooter: View {
    @ObservedObject var settings: Settings
    @ObservedObject var transcriptionService: ParakeetTranscriptionService

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.7), radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.transcriptionModel.displayName)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Brand.ink2)
                Text(statusText).font(.system(size: 11)).foregroundStyle(Brand.ink4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .glassPanel(cornerRadius: 14)
    }
    private var statusColor: Color {
        switch transcriptionService.modelState {
        case .ready: return Brand.ready
        case .failed: return Brand.danger
        default: return Color.accentColor
        }
    }
    private var statusText: String {
        switch transcriptionService.modelState {
        case .ready: return "Ready · Neural Engine"
        case .loading: return "Loading model…"
        case .downloading: return "Downloading…"
        case .notLoaded: return "Idle"
        case .failed: return "Needs attention"
        }
    }
}
