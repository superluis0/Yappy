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
        XCTAssertEqual(settings.hotkeyActivation, .holdToTalk)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.cleanupEnabled, "AI cleanup is on by default")
        XCTAssertEqual(settings.cleanupIntensity, .standard, "Standard cleanup intensity by default")
        XCTAssertTrue(settings.cleanupDiffCaptionEnabled, "Polish caption on by default")
        XCTAssertTrue(settings.dictionaryAutoLearnEnabled, "Dictionary auto-learn on by default")
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

    func testAnswersVoiceSpeedDefaultsToNormalAndPersists() {
        XCTAssertEqual(settings.answersVoiceSpeed, .normal)
        settings.answersVoiceSpeed = .brisk
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.answersVoiceSpeed, .brisk, "A chosen voice speed survives relaunch on the same suite")
    }

    func testListeningGlowStyleDefaultsToRainbowAndPersists() {
        XCTAssertEqual(settings.listeningGlowStyle, .rainbow)
        settings.listeningGlowStyle = .orange
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.listeningGlowStyle, .orange, "A chosen glow style survives relaunch on the same suite")
    }

    func testAskHotkeyOptionDefaultsToFnAndPersists() {
        XCTAssertEqual(settings.askHotkeyOption, .fnGlobe)
        settings.askHotkeyOption = .rightControl
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.askHotkeyOption, .rightControl, "A chosen Ask key survives relaunch on the same suite")
    }

    func testCleanupIntensityAndAutoLearnPersist() {
        settings.cleanupIntensity = .conservative
        settings.cleanupDiffCaptionEnabled = false
        settings.dictionaryAutoLearnEnabled = false
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.cleanupIntensity, .conservative)
        XCTAssertFalse(reloaded.cleanupDiffCaptionEnabled)
        XCTAssertFalse(reloaded.dictionaryAutoLearnEnabled)
    }

    func testVoiceEditAnywhereDefaultsOffAndPersists() {
        XCTAssertFalse(settings.voiceEditAnywhereEnabled,
                       "Voice Edit Anywhere is experimental — OFF by default")
        settings.voiceEditAnywhereEnabled = true
        let reloaded = Settings(defaults: defaults)
        XCTAssertTrue(reloaded.voiceEditAnywhereEnabled, "A chosen value survives relaunch on the same suite")
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
        settings.toneOverrides = [.email: .casual, .code: .formal]
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.toneOverrides[.email], .casual)
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
        // `.rightCommandDoubleTap` is intentionally excluded: it no longer
        // round-trips verbatim by design — see
        // `testLegacyDoubleTapPresetMigratesToHoldKeyPlusDoubleTapLockActivation`.
        for option in HotkeyOption.allCases where option != .rightCommandDoubleTap {
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

    // MARK: - HotkeyActivation

    func testHotkeyActivationDefaultsToHoldToTalkAndPersists() {
        XCTAssertEqual(settings.hotkeyActivation, .holdToTalk)
        settings.hotkeyActivation = .doubleTapLock
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.hotkeyActivation, .doubleTapLock,
                        "A chosen activation survives relaunch on the same suite")
    }

    func testHotkeyActivationCaseIterable() {
        XCTAssertEqual(HotkeyActivation.allCases.count, 2)
    }

    func testHotkeyActivationCodable() throws {
        for activation in HotkeyActivation.allCases {
            let data = try JSONEncoder().encode(activation)
            let decoded = try JSONDecoder().decode(HotkeyActivation.self, from: data)
            XCTAssertEqual(decoded, activation)
        }
    }

    func testHotkeyActivationResets() {
        settings.hotkeyActivation = .doubleTapLock
        settings.reset()
        XCTAssertEqual(settings.hotkeyActivation, .holdToTalk)
    }

    // MARK: - Legacy double-tap preset migration

    func testLegacyDoubleTapPresetMigratesToHoldKeyPlusDoubleTapLockActivation() {
        // Simulate a pre-migration install: only the OLD raw `hotkeyOption`
        // value is on disk, as a build predating `hotkeyActivation` would have
        // left it.
        defaults.set(HotkeyOption.rightCommandDoubleTap.rawValue, forKey: "com.yappy.hotkeyOption")

        let migrated = Settings(defaults: defaults)

        XCTAssertEqual(migrated.hotkeyOption, .rightCommandHold,
                        "Legacy double-tap preset keeps the Right ⌘ key")
        XCTAssertEqual(migrated.hotkeyActivation, .doubleTapLock,
                        "...and moves double-tap timing to the new activation setting")

        // PERSISTED, not just corrected in memory — a later launch must not
        // need to re-migrate, and must never silently regress to hold-to-talk.
        XCTAssertEqual(defaults.string(forKey: "com.yappy.hotkeyOption"), HotkeyOption.rightCommandHold.rawValue)
        XCTAssertEqual(defaults.string(forKey: "com.yappy.hotkeyActivation"), HotkeyActivation.doubleTapLock.rawValue)

        let relaunchedAgain = Settings(defaults: defaults)
        XCTAssertEqual(relaunchedAgain.hotkeyOption, .rightCommandHold)
        XCTAssertEqual(relaunchedAgain.hotkeyActivation, .doubleTapLock)
    }

    func testNonLegacyHotkeyOptionsAreUnaffectedByMigration() {
        for option in HotkeyOption.allCases where option != .rightCommandDoubleTap {
            settings.hotkeyActivation = .doubleTapLock // an explicit user choice
            settings.hotkeyOption = option
            let reloaded = Settings(defaults: defaults)
            XCTAssertEqual(reloaded.hotkeyOption, option)
            XCTAssertEqual(reloaded.hotkeyActivation, .doubleTapLock,
                            "migration must only ever touch the legacy double-tap preset")
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

// MARK: - CommandCatalog

/// `CommandCatalog.sections` is mined verbatim from the spoken-phrase parsers
/// (see the catalog's own doc comment), so these tests check catalog hygiene
/// rather than any one phrase's exact wording.
final class CommandCatalogTests: XCTestCase {

    func testEverySectionIsNonEmpty() {
        for section in CommandCatalog.sections {
            XCTAssertFalse(section.entries.isEmpty, "\"\(section.title)\" has no entries")
        }
    }

    func testEveryPhraseIsNonEmptyAndLowercaseComparable() {
        for section in CommandCatalog.sections {
            for entry in section.entries {
                XCTAssertFalse(entry.phrase.isEmpty, "Empty phrase in \"\(section.title)\"")
                // Only SPOKEN phrases must match the parsers' lowercase input;
                // physical actions ("Press Esc") are display labels.
                guard entry.isSpoken else { continue }
                XCTAssertEqual(entry.phrase, entry.phrase.lowercased(),
                                "\"\(entry.phrase)\" in \"\(section.title)\" isn't already lowercase")
            }
        }
    }

    func testNoDuplicatePhrasesAcrossSections() {
        let allPhrases = CommandCatalog.sections.flatMap { $0.entries.map(\.phrase) }
        XCTAssertEqual(allPhrases.count, Set(allPhrases).count, "A phrase repeats across sections")
    }

    func testAnswersSectionExists() {
        XCTAssertTrue(CommandCatalog.sections.contains { $0.title == CommandCatalog.answersSectionTitle })
    }

    /// Spot-checks phrases that mirror the real parsers, so a rewrite that
    /// silently drops one of them fails a test instead of shipping quietly.
    func testKnownParserPhrasesArePresent() {
        let allPhrases = Set(CommandCatalog.sections.flatMap { $0.entries.map(\.phrase) })
        // "comma" is also featured in OnboardingView's model-download mini-deck
        // (`CommandDeck.featuredPhrases`), looked up by this exact string.
        for phrase in ["scratch that", "press enter", "copy that", "new paragraph", "comma"] {
            XCTAssertTrue(allPhrases.contains(phrase), "Missing expected phrase \"\(phrase)\"")
        }
    }
}
