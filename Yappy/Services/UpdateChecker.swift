//
//  UpdateChecker.swift
//  Yappy
//

import Foundation
import Combine
import Sparkle

/// Drives in-app updates via **Sparkle** (the macOS auto-updater). Sparkle fetches
/// the signed *appcast* (`SUFeedURL`) over HTTPS and verifies each update with an
/// **EdDSA signature** (`SUPublicEDKey`) before installing it in place and
/// relaunching — a one-click, fully local "Update Now".
///
/// Why this wrapper exists: Yappy is a menu-bar app with no always-open window, so
/// Sparkle's stock behaviour — popping its own modal alert out of nowhere on a
/// background check — feels disconnected. Instead we opt into Sparkle's **gentle
/// reminders** (see `SparkleBridge`): on a scheduled/background check Sparkle stays
/// quiet and just hands us the found release, which we surface ourselves through
/// the menu-bar item, the icon badge, and the in-app banner (all bound to
/// `available`). The actual install still runs through Sparkle's standard signed
/// dialog, reached via `checkForUpdates()` from any of those surfaces.
///
/// Privacy: the only network call here is Sparkle fetching the appcast to compare
/// versions — no data about the user is sent. Turning off automatic checks
/// (Settings → Software Update) keeps Yappy fully offline.
@MainActor
final class UpdateChecker: ObservableObject {
    /// A newer release Sparkle has found and offered.
    struct Release: Equatable { let version: String }

    /// Non-nil once Sparkle finds a newer release. Drives the menu-bar "Update to
    /// Yappy X.Y" item, the icon badge dot, and the main-window banner.
    @Published private(set) var available: Release?

    /// True while a user-initiated check is in flight (drives the Settings
    /// "Checking…" label).
    @Published private(set) var isChecking = false

    private var controller: SPUStandardUpdaterController?
    private var bridge: SparkleBridge?

    /// The running app's marketing version (e.g. "2.1"), shown in Settings.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The build number (`CFBundleVersion`). Shown next to the version so the
    /// installed build is unambiguous (e.g. "2.1 (58)").
    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    /// Version + build for display, e.g. "2.1 (58)".
    var currentVersionDisplay: String {
        currentBuild.isEmpty ? currentVersion : "\(currentVersion) (\(currentBuild))"
    }

    /// Whether Sparkle performs scheduled background checks. Reflected into the
    /// updater and persisted by the caller (Settings.autoUpdateChecksEnabled).
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { startUpdater(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Create and start Sparkle's updater. Idempotent; call early in app launch.
    /// - Parameter autoChecks: initial value for scheduled background checks
    ///   (mirrors the persisted setting).
    func startUpdater(autoChecks: Bool = true) {
        guard controller == nil else { return }
        let bridge = SparkleBridge(owner: self)
        self.bridge = bridge   // retain — the controller holds delegates weakly
        // `userDriverDelegate: bridge` enables gentle reminders: Sparkle won't
        // auto-present its modal on a background check; we surface the update via
        // `available` instead (menu item + badge + banner). The user still installs
        // through Sparkle's standard dialog, reached via `checkForUpdates()`.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: bridge, userDriverDelegate: bridge)
        controller?.updater.automaticallyChecksForUpdates = autoChecks
    }

    /// User-initiated check — always shows Sparkle's standard "Install Update" UI.
    /// The menu items, the banner's "Update Now", and Settings' "Check Now" all
    /// call this.
    func checkForUpdates() {
        startUpdater()
        isChecking = true
        controller?.updater.checkForUpdates()
    }

    /// Silent background check. If it finds an update it lights up `available`
    /// (and, via gentle reminders, does *not* pop Sparkle's modal). Called once at
    /// launch so a pending update surfaces promptly instead of waiting for the
    /// next scheduled interval.
    func checkInBackground() {
        startUpdater()
        controller?.updater.checkForUpdatesInBackground()
    }

    // MARK: - Sparkle callbacks (forwarded from the NSObject bridge, main thread)

    fileprivate func didFind(_ item: SUAppcastItem) {
        available = Release(version: item.displayVersionString)
    }
    fileprivate func didNotFindUpdate() { available = nil }
    fileprivate func cycleFinished() { isChecking = false }
}

/// Bridges Sparkle's `@objc` delegate callbacks to the `@MainActor`
/// `ObservableObject` `UpdateChecker`. Sparkle invokes these on the main thread,
/// so `MainActor.assumeIsolated` is safe.
private final class SparkleBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private weak var owner: UpdateChecker?
    init(owner: UpdateChecker) { self.owner = owner }

    // MARK: SPUUpdaterDelegate
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { owner?.didFind(item) }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { owner?.didNotFindUpdate() }
    }
    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        if let error {
            VLog.app("update cycle error: \(error.localizedDescription)")
        }
        MainActor.assumeIsolated { owner?.cycleFinished() }
    }

    // MARK: SPUStandardUserDriverDelegate — gentle reminders
    // We show updates with our own surfaces (menu item, icon badge, in-app
    // banner), so tell Sparkle not to auto-present its modal on scheduled/
    // background checks. `available` is set in `didFindValidUpdate` above; the
    // user installs via `checkForUpdates()` (user-initiated, which always shows
    // Sparkle's standard install dialog — this method isn't consulted there, so
    // updates can never be blocked).
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }
}
