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
        XCTAssertTrue(settings.cleanupEnabled, "AI cleanup is on by default")
        XCTAssertTrue(settings.audioFeedbackEnabled)
        XCTAssertEqual(settings.audioFeedbackVolume, 0.5)
        XCTAssertTrue(settings.contextAwareToneEnabled)
        XCTAssertTrue(settings.backtrackEnabled)
        XCTAssertTrue(settings.adaptiveModeEnabled)
        XCTAssertTrue(settings.appModeOverrides.isEmpty)
        XCTAssertTrue(settings.toneOverrides.isEmpty)
        XCTAssertTrue(settings.customDictionaryEnabled, "On by default so built-in dev terms apply out of the box")
        XCTAssertFalse(settings.vocabularyBoostingEnabled, "Speech-model boosting is opt-in (extra download + inference pass)")
        XCTAssertFalse(settings.onboardingComplete)
        XCTAssertTrue(settings.autoUpdateChecksEnabled, "Automatic update checks should be on by default")
        XCTAssertEqual(settings.transcriptionModel, .parakeet, "Parakeet (English) is the default STT model")
        XCTAssertTrue(settings.saveHistoryEnabled, "Dictation history is saved by default")
        XCTAssertEqual(settings.historyRetentionDays, 0, "History is kept forever by default (0 days)")
    }

    func testAutoUpdateChecksEnabledPersists() {
        settings.autoUpdateChecksEnabled = false
        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.autoUpdateChecksEnabled)
    }

    func testTranscriptionModelPersists() {
        settings.transcriptionModel = .nemotron
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.transcriptionModel, .nemotron, "A chosen STT model survives relaunch on the same suite")
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

    // MARK: - Persistence

    func testPersistence() {
        settings.hotkeyOption = .rightOptionHold
        settings.launchAtLogin = true
        settings.cleanupEnabled = true
        settings.audioFeedbackEnabled = false
        settings.audioFeedbackVolume = 0.8

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.hotkeyOption, .rightOptionHold)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertTrue(reloaded.cleanupEnabled)
        XCTAssertFalse(reloaded.audioFeedbackEnabled)
        XCTAssertEqual(reloaded.audioFeedbackVolume, 0.8)
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

    func testVocabularyBoostingEnabledPersists() {
        settings.vocabularyBoostingEnabled = true
        let reloaded = Settings(defaults: defaults)
        XCTAssertTrue(reloaded.vocabularyBoostingEnabled, "A chosen boosting setting survives relaunch on the same suite")
    }

    func testVocabularyBoostingEnabledResets() {
        settings.vocabularyBoostingEnabled = true
        settings.reset()
        XCTAssertFalse(settings.vocabularyBoostingEnabled, "Reset returns speech-model boosting to off")
    }

    // MARK: - History & privacy

    func testHistoryPrivacySettingsPersist() {
        settings.saveHistoryEnabled = false
        settings.historyRetentionDays = 30

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.saveHistoryEnabled, "Opting out of history survives relaunch")
        XCTAssertEqual(reloaded.historyRetentionDays, 30, "Retention window survives relaunch")
    }

    func testHistoryPrivacySettingsReset() {
        settings.saveHistoryEnabled = false
        settings.historyRetentionDays = 90

        settings.reset()

        XCTAssertTrue(settings.saveHistoryEnabled, "Reset re-enables saving history")
        XCTAssertEqual(settings.historyRetentionDays, 0, "Reset returns retention to keep-forever")
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
        settings.cleanupEnabled = false
        settings.audioFeedbackVolume = 1.0
        settings.transcriptionModel = .nemotron

        settings.reset()

        XCTAssertEqual(settings.hotkeyOption, .rightCommandHold)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.cleanupEnabled, "AI cleanup is on by default")
        XCTAssertTrue(settings.audioFeedbackEnabled)
        XCTAssertEqual(settings.audioFeedbackVolume, 0.5)
        XCTAssertEqual(settings.transcriptionModel, .parakeet, "Reset returns the STT model to Parakeet")
    }

    // MARK: - Migration

    func testStaleCloudKeysAreRemoved() {
        defaults.set("sk-old-key", forKey: "com.yappy.openAIAPIKey")
        defaults.set("or-old-key", forKey: "com.yappy.openRouterAPIKey")
        defaults.set(true, forKey: "com.yappy.streamingTextEnabled")
        defaults.removeObject(forKey: "com.yappy.legacyCleanupMigrated")

        let migrated = Settings(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: "com.yappy.openAIAPIKey"))
        XCTAssertNil(defaults.string(forKey: "com.yappy.openRouterAPIKey"))
        XCTAssertNil(defaults.object(forKey: "com.yappy.streamingTextEnabled"))
        // The legacy block wipes the old cleanup flag, then the one-time default-on
        // migration force-enables on-device cleanup for new and existing users.
        XCTAssertTrue(migrated.cleanupEnabled, "AI cleanup is on by default after migration")
    }

    func testCleanupDefaultOnIsOneTime() {
        // A fresh suite: the first Settings force-enables cleanup once.
        let suite = "com.yappy.tests.cleanupMigration"
        let migrationDefaults = UserDefaults(suiteName: suite)!
        migrationDefaults.removePersistentDomain(forName: suite)
        defer { migrationDefaults.removePersistentDomain(forName: suite) }

        let first = Settings(defaults: migrationDefaults)
        XCTAssertTrue(first.cleanupEnabled, "AI cleanup is on by default on first launch")

        // The user turns it off; a relaunch on the SAME suite must respect that.
        first.cleanupEnabled = false
        let second = Settings(defaults: migrationDefaults)
        XCTAssertFalse(second.cleanupEnabled, "Default-on migration is one-time; a later toggle sticks")
    }

    func testCleanupToggleSurvivesRelaunch() {
        // The default-on migration already ran in setUp(); a user-set false must
        // persist and the migration must not re-enable it on the same suite.
        settings.cleanupEnabled = false

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.cleanupEnabled, "User's cleanup choice must survive relaunch")
    }

    // MARK: - HotkeyOption

    func testHotkeyOptionEnum() {
        XCTAssertEqual(HotkeyOption.rightCommandHold.displayName, "Right Command (Hold)")
        XCTAssertEqual(HotkeyOption.rightCommandDoubleTap.displayName, "Right Command (Double Tap)")
        XCTAssertEqual(HotkeyOption.rightOptionHold.displayName, "Right Option (Hold)")
        XCTAssertEqual(HotkeyOption.rightControlHold.displayName, "Right Control (Hold)")
    }

    func testHotkeyOptionCaseIterable() {
        XCTAssertEqual(HotkeyOption.allCases.count, 4)
    }

    func testHotkeyOptionCodable() throws {
        for option in HotkeyOption.allCases {
            let data = try JSONEncoder().encode(option)
            let decoded = try JSONDecoder().decode(HotkeyOption.self, from: data)
            XCTAssertEqual(decoded, option)
        }
    }

    // MARK: - TranscriptionModel

    func testTranscriptionModelDisplayName() {
        XCTAssertEqual(TranscriptionModel.parakeet.displayName, "Parakeet (English)")
        XCTAssertEqual(TranscriptionModel.nemotron.displayName, "Nemotron (Multilingual)")
    }

    func testTranscriptionModelCaseIterable() {
        XCTAssertEqual(TranscriptionModel.allCases.count, 2)
    }

    func testTranscriptionModelCodable() throws {
        for model in TranscriptionModel.allCases {
            let data = try JSONEncoder().encode(model)
            let decoded = try JSONDecoder().decode(TranscriptionModel.self, from: data)
            XCTAssertEqual(decoded, model)
        }
    }
}
