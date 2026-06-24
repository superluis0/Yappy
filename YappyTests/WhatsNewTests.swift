//
//  WhatsNewTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class WhatsNewTests: XCTestCase {

    // MARK: - Pure decision: pending(current:prior:onboardingComplete:)

    func testFreshInstallShowsNothing() {
        // No prior version recorded → treat as a fresh install, never greet.
        XCTAssertNil(WhatsNew.pending(current: "2.1", prior: nil, onboardingComplete: true))
        XCTAssertNil(WhatsNew.pending(current: "2.1", prior: "", onboardingComplete: true))
    }

    func testUnchangedVersionShowsNothing() {
        XCTAssertNil(WhatsNew.pending(current: "2.1", prior: "2.1", onboardingComplete: true))
    }

    func testDuringOnboardingShowsNothing() {
        // Even with a version change, don't interrupt a user who hasn't onboarded.
        XCTAssertNil(WhatsNew.pending(current: "2.1", prior: "2.0", onboardingComplete: false))
    }

    func testUpdateToVersionWithNotesShowsEntry() {
        let entry = WhatsNew.pending(current: "2.1", prior: "2.0", onboardingComplete: true)
        XCTAssertEqual(entry?.version, "2.1")
        XCTAssertFalse(entry?.highlights.isEmpty ?? true, "The 2.1 card should have highlights")
    }

    func testUpdateToVersionWithoutNotesShowsNothing() {
        // A version with no registered release notes shouldn't pop an empty card.
        XCTAssertNil(WhatsNew.pending(current: "99.0", prior: "2.0", onboardingComplete: true))
    }

    // MARK: - pendingAfterLaunch persistence

    func testPendingAfterLaunchAdvancesStoredVersion() {
        let suiteName = "com.yappy.whatsnew.tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Fresh install: nothing to show, but the current version is recorded so
        // the *next* update can be detected.
        let first = WhatsNew.pendingAfterLaunch(onboardingComplete: true, defaults: defaults)
        XCTAssertNil(first)
        XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenKey), WhatsNew.currentVersion)

        // Relaunch on the same version: still nothing.
        let second = WhatsNew.pendingAfterLaunch(onboardingComplete: true, defaults: defaults)
        XCTAssertNil(second)
    }

    func testPendingAfterLaunchShowsEntryAfterUpdate() {
        let suiteName = "com.yappy.whatsnew.tests2"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Pretend the user last saw a much older version, then launched after an
        // update. The result is the entry for whatever version this bundle reports
        // (if one is registered), and the stored version advances to current.
        defaults.set("0.0.1", forKey: WhatsNew.lastSeenKey)
        let result = WhatsNew.pendingAfterLaunch(onboardingComplete: true, defaults: defaults)
        XCTAssertEqual(result?.version, WhatsNew.entries[WhatsNew.currentVersion]?.version)
        XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenKey), WhatsNew.currentVersion)
    }

    // MARK: - Content sanity

    func testRegisteredEntriesAreWellFormed() {
        XCTAssertNotNil(WhatsNew.entries["2.1"])
        XCTAssertNotNil(WhatsNew.entries["2.2"])
        for (key, entry) in WhatsNew.entries {
            XCTAssertEqual(key, entry.version, "Entry key must match its version")
            XCTAssertFalse(entry.headline.isEmpty)
            XCTAssertFalse(entry.highlights.isEmpty)
            for highlight in entry.highlights {
                XCTAssertFalse(highlight.icon.isEmpty)
                XCTAssertFalse(highlight.title.isEmpty)
                XCTAssertFalse(highlight.detail.isEmpty)
            }
        }
    }
}
