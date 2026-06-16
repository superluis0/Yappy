//
//  SettingsTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class SettingsTests: XCTestCase {

    var defaults: UserDefaults!
    var settings: Settings!

    private let suiteName = "com.yappy.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        settings = Settings(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultValues() {
        XCTAssertEqual(settings.hotkeyOption, .rightCommandHold)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(settings.cleanupEnabled, "LM Studio cleanup should be off by default")
        XCTAssertTrue(settings.audioFeedbackEnabled)
        XCTAssertEqual(settings.audioFeedbackVolume, 0.5)
        XCTAssertNil(settings.lmStudioModelID)
        XCTAssertEqual(settings.lmStudioBaseURL, Constants.defaultLMStudioBaseURL)
        XCTAssertTrue(settings.commandModeEnabled)
        XCTAssertEqual(settings.commandHotkeyOption, .rightOptionHold)
        XCTAssertTrue(settings.contextAwareToneEnabled)
        XCTAssertTrue(settings.backtrackEnabled)
        XCTAssertTrue(settings.adaptiveModeEnabled)
        XCTAssertTrue(settings.appModeOverrides.isEmpty)
        XCTAssertTrue(settings.toneOverrides.isEmpty)
        XCTAssertTrue(settings.customDictionaryEnabled, "On by default so built-in dev terms apply out of the box")
        XCTAssertFalse(settings.onboardingComplete)
    }

    func testToneResolution() {
        // No override → category default.
        XCTAssertEqual(settings.tone(for: .code), .verbatim)
        XCTAssertEqual(settings.tone(for: .personalChat), .casual)
        // Override wins.
        settings.toneOverrides[.code] = .casual
        XCTAssertEqual(settings.tone(for: .code), .casual)
    }

    func testAdaptiveModeSettingsPersist() {
        let id = UUID().uuidString
        settings.adaptiveModeEnabled = false
        settings.appModeOverrides = ["com.apple.mail": id]

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.adaptiveModeEnabled)
        XCTAssertEqual(reloaded.appModeOverrides["com.apple.mail"], id)
    }

    func testToneOverridesPersist() {
        settings.toneOverrides = [.email: .excited, .code: .formal]
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.toneOverrides[.email], .excited)
        XCTAssertEqual(reloaded.toneOverrides[.code], .formal)
    }

    func testHotkeyCollisionDetection() {
        settings.hotkeyOption = .rightCommandHold
        settings.commandHotkeyOption = .rightOptionHold
        XCTAssertFalse(settings.hotkeysCollide)
        settings.commandHotkeyOption = .rightCommandHold
        XCTAssertTrue(settings.hotkeysCollide)
    }

    // MARK: - Persistence

    func testPersistence() {
        settings.hotkeyOption = .rightOptionHold
        settings.launchAtLogin = true
        settings.cleanupEnabled = true
        settings.audioFeedbackEnabled = false
        settings.audioFeedbackVolume = 0.8
        settings.lmStudioModelID = "qwen2.5-7b-instruct"
        settings.lmStudioBaseURL = "http://localhost:9999/v1"

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.hotkeyOption, .rightOptionHold)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertTrue(reloaded.cleanupEnabled)
        XCTAssertFalse(reloaded.audioFeedbackEnabled)
        XCTAssertEqual(reloaded.audioFeedbackVolume, 0.8)
        XCTAssertEqual(reloaded.lmStudioModelID, "qwen2.5-7b-instruct")
        XCTAssertEqual(reloaded.lmStudioBaseURL, "http://localhost:9999/v1")
    }

    func testPersistenceWithHotkeyOption() {
        for option in HotkeyOption.allCases {
            settings.hotkeyOption = option
            let reloaded = Settings(defaults: defaults)
            XCTAssertEqual(reloaded.hotkeyOption, option)
        }
    }

    func testTranscriptCleanupDefaultsAreOn() {
        XCTAssertTrue(settings.numberFormattingEnabled)
        XCTAssertTrue(settings.numberedListsEnabled)
        XCTAssertTrue(settings.fillerRemovalEnabled)
        XCTAssertTrue(settings.spokenCommandsEnabled)
        XCTAssertTrue(settings.spokenPunctuationEnabled)
        XCTAssertTrue(settings.voiceEditingEnabled)
        XCTAssertTrue(settings.voiceControlEnabled)
    }

    func testTranscriptCleanupTogglesPersist() {
        settings.fillerRemovalEnabled = false
        settings.spokenCommandsEnabled = false
        settings.voiceEditingEnabled = false

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.fillerRemovalEnabled)
        XCTAssertFalse(reloaded.spokenCommandsEnabled)
        XCTAssertFalse(reloaded.voiceEditingEnabled)
    }

    func testTranscriptCleanupTogglesReset() {
        settings.fillerRemovalEnabled = false
        settings.spokenCommandsEnabled = false
        settings.voiceEditingEnabled = false

        settings.reset()

        XCTAssertTrue(settings.fillerRemovalEnabled)
        XCTAssertTrue(settings.spokenCommandsEnabled)
        XCTAssertTrue(settings.voiceEditingEnabled)
    }

    // MARK: - Reset

    func testReset() {
        settings.hotkeyOption = .rightCommandDoubleTap
        settings.launchAtLogin = true
        settings.cleanupEnabled = true
        settings.audioFeedbackVolume = 1.0
        settings.lmStudioModelID = "some-model"

        settings.reset()

        XCTAssertEqual(settings.hotkeyOption, .rightCommandHold)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(settings.cleanupEnabled)
        XCTAssertTrue(settings.audioFeedbackEnabled)
        XCTAssertEqual(settings.audioFeedbackVolume, 0.5)
        XCTAssertNil(settings.lmStudioModelID)
        XCTAssertEqual(settings.lmStudioBaseURL, Constants.defaultLMStudioBaseURL)
    }

    // MARK: - Migration

    func testStaleCloudKeysAreRemoved() {
        defaults.set("sk-old-key", forKey: "com.yappy.openAIAPIKey")
        defaults.set("or-old-key", forKey: "com.yappy.openRouterAPIKey")
        defaults.set(true, forKey: "com.yappy.streamingTextEnabled")
        // The legacy cloud cleanup flag defaulted to on; it must not carry over.
        defaults.set(true, forKey: "com.yappy.cleanupEnabled")
        defaults.removeObject(forKey: "com.yappy.legacyCleanupMigrated")

        let migrated = Settings(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: "com.yappy.openAIAPIKey"))
        XCTAssertNil(defaults.string(forKey: "com.yappy.openRouterAPIKey"))
        XCTAssertNil(defaults.object(forKey: "com.yappy.streamingTextEnabled"))
        XCTAssertFalse(migrated.cleanupEnabled, "Legacy cleanup flag must reset to off")
    }

    func testMigrationRunsOnlyOnce() {
        _ = Settings(defaults: defaults)
        settings.cleanupEnabled = true

        let reloaded = Settings(defaults: defaults)
        XCTAssertTrue(reloaded.cleanupEnabled, "User's LM Studio cleanup choice must survive relaunch")
    }

    // MARK: - HotkeyOption

    func testHotkeyOptionEnum() {
        XCTAssertEqual(HotkeyOption.rightCommandHold.displayName, "Right Command (Hold)")
        XCTAssertEqual(HotkeyOption.rightCommandDoubleTap.displayName, "Right Command (Double Tap)")
        XCTAssertEqual(HotkeyOption.rightOptionHold.displayName, "Right Option (Hold)")
    }

    func testHotkeyOptionCaseIterable() {
        XCTAssertEqual(HotkeyOption.allCases.count, 3)
    }

    func testHotkeyOptionCodable() throws {
        for option in HotkeyOption.allCases {
            let data = try JSONEncoder().encode(option)
            let decoded = try JSONDecoder().decode(HotkeyOption.self, from: data)
            XCTAssertEqual(decoded, option)
        }
    }
}
