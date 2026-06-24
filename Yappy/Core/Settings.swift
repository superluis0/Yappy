//
//  Settings.swift
//  Yappy
//

import Foundation
import Combine

/// Hotkey activation options for triggering voice recording.
enum HotkeyOption: String, CaseIterable, Codable {
    case rightCommandHold = "Right Command (Hold)"
    case rightCommandDoubleTap = "Right Command (Double Tap)"
    case rightOptionHold = "Right Option (Hold)"

    /// Display name for UI presentation.
    var displayName: String {
        return self.rawValue
    }
}

/// Which backend runs AI cleanup, Command Mode, and Transforms. `automatic`
/// prefers an on-device model when available, then falls back to LM Studio.
enum CleanupBackend: String, CaseIterable, Codable {
    case automatic
    case appleIntelligence
    case builtIn
    case lmStudio

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .appleIntelligence: return "Apple Intelligence"
        case .builtIn: return "Built-in model"
        case .lmStudio: return "LM Studio"
        }
    }
}

/// Application settings with UserDefaults persistence.
/// Fully local — no API keys. The optional LLM cleanup talks to LM Studio on localhost.
final class Settings: ObservableObject {
    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyOption = "com.yappy.hotkeyOption"
        static let launchAtLogin = "com.yappy.launchAtLogin"
        static let cleanupEnabled = "com.yappy.cleanupEnabled"
        static let cleanupBackend = "com.yappy.cleanupBackend"
        static let audioFeedbackEnabled = "com.yappy.audioFeedbackEnabled"
        static let audioFeedbackVolume = "com.yappy.audioFeedbackVolume"
        static let lmStudioModelID = "com.yappy.lmStudioModelID"
        static let lmStudioBaseURL = "com.yappy.lmStudioBaseURL"
        static let commandModeEnabled = "com.yappy.commandModeEnabled"
        static let commandHotkeyOption = "com.yappy.commandHotkeyOption"
        static let autoTransformID = "com.yappy.autoTransformID"
        static let dismissedSuggestions = "com.yappy.dismissedSuggestions"
        static let contextAwareToneEnabled = "com.yappy.contextAwareToneEnabled"
        static let backtrackEnabled = "com.yappy.backtrackEnabled"
        static let toneOverrides = "com.yappy.toneOverrides"
        static let adaptiveModeEnabled = "com.yappy.adaptiveModeEnabled"
        static let appModeOverrides = "com.yappy.appModeOverrides"
        static let customDictionaryEnabled = "com.yappy.customDictionaryEnabled"
        static let numberFormattingEnabled = "com.yappy.numberFormattingEnabled"
        static let numberedListsEnabled = "com.yappy.numberedListsEnabled"
        static let fillerRemovalEnabled = "com.yappy.fillerRemovalEnabled"
        static let spokenCommandsEnabled = "com.yappy.spokenCommandsEnabled"
        static let spokenPunctuationEnabled = "com.yappy.spokenPunctuationEnabled"
        static let voiceEditingEnabled = "com.yappy.voiceEditingEnabled"
        static let voiceControlEnabled = "com.yappy.voiceControlEnabled"
        static let activeModeID = "com.yappy.activeModeID"
        static let onboardingComplete = "com.yappy.onboardingComplete"
        static let legacyCleanupMigrated = "com.yappy.legacyCleanupMigrated"

        /// Keys from the cloud-based versions of Yappy; removed on first launch.
        static let staleKeys = [
            "com.yappy.openAIAPIKey",
            "com.yappy.openRouterAPIKey",
            "com.yappy.streamingTextEnabled",
            "com.yappy.voiceCommandsEnabled",
            "com.yappy.keychainMigrationComplete",
        ]
    }

    // MARK: - Published Properties

    /// Selected hotkey activation method.
    @Published var hotkeyOption: HotkeyOption = .rightCommandHold {
        didSet { if !isLoading { save() } }
    }

    /// Whether the app should launch automatically at login.
    @Published var launchAtLogin: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Whether to clean up transcripts with a local LM Studio model. Off by default.
    @Published var cleanupEnabled: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Which backend performs AI cleanup / Command Mode / Transforms.
    @Published var cleanupBackend: CleanupBackend = .automatic {
        didSet { if !isLoading { save() } }
    }

    /// Whether audio feedback sounds are enabled.
    @Published var audioFeedbackEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Volume level for audio feedback (0.0 - 1.0).
    @Published var audioFeedbackVolume: Float = 0.5 {
        didSet { if !isLoading { save() } }
    }

    /// Identifier of the LM Studio model used for cleanup (nil = first available).
    @Published var lmStudioModelID: String? {
        didSet { if !isLoading { save() } }
    }

    /// Base URL of LM Studio's OpenAI-compatible server.
    @Published var lmStudioBaseURL: String = Constants.defaultLMStudioBaseURL {
        didSet { if !isLoading { save() } }
    }

    /// Whether Command Mode (select text + speak an instruction) is active.
    @Published var commandModeEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Hotkey that triggers Command Mode. Should differ from `hotkeyOption`.
    @Published var commandHotkeyOption: HotkeyOption = .rightOptionHold {
        didSet { if !isLoading { save() } }
    }

    /// Transform (UUID string) run automatically after every dictation; nil = none.
    @Published var autoTransformID: String? {
        didSet { if !isLoading { save() } }
    }

    /// Normalized keys of history-derived shortcut suggestions the user dismissed,
    /// so they don't reappear in the Home "Suggestions" card.
    @Published var dismissedSuggestions: Set<String> = [] {
        didSet { if !isLoading { save() } }
    }

    /// Whether cleanup adapts tone to the frontmost app's category.
    @Published var contextAwareToneEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether cleanup resolves spoken self-corrections ("at 2, actually 3").
    /// Only takes effect when AI cleanup runs (non-verbatim tone).
    @Published var backtrackEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether Auto mode honors the mode you last picked in a given app
    /// (learned per bundle id). An explicit global mode selection still wins.
    @Published var adaptiveModeEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Learned bundle id → mode UUID string, taught by picking a mode while an
    /// app is frontmost. Consulted only when no explicit global mode is selected.
    @Published var appModeOverrides: [String: String] = [:] {
        didSet { if !isLoading { save() } }
    }

    /// Per-category tone overrides; absent category = use the category default.
    @Published var toneOverrides: [AppCategory: ToneStyle] = [:] {
        didSet { if !isLoading { save() } }
    }

    /// Whether the custom dictionary (vocabulary corrections) is enabled. On by
    /// default so the built-in developer/tech starter terms apply out of the box.
    @Published var customDictionaryEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether spoken numbers are written as digits ("eleven point six" -> "11.6").
    @Published var numberFormattingEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether a spoken enumeration ("one milk two eggs three bread") is written
    /// as a numbered list. Works best with number formatting on.
    @Published var numberedListsEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether hesitation fillers ("um", "uh") are stripped from transcripts.
    @Published var fillerRemovalEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether "new line" / "new paragraph" insert real line breaks.
    @Published var spokenCommandsEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether spoken marks ("comma", "question mark") become real punctuation.
    @Published var spokenPunctuationEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether spoken edits ("scratch that", "all caps that") fix the last dictation.
    @Published var voiceEditingEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether spoken app-control commands ("switch to email mode", "open
    /// scratchpad", "new note") control Yappy instead of being dictated.
    @Published var voiceControlEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// The explicitly-selected dictation mode's id (UUID string); nil = Auto.
    @Published var activeModeID: String? {
        didSet { if !isLoading { save() } }
    }

    /// Whether the first-run onboarding flow has been completed.
    @Published var onboardingComplete: Bool = false {
        didSet { if !isLoading { save() } }
    }

    // MARK: - Tone Resolution

    /// The effective tone for a category: the user override, or the category default.
    func tone(for category: AppCategory) -> ToneStyle {
        toneOverrides[category] ?? category.defaultTone
    }

    /// True if the command hotkey collides with the dictation hotkey.
    var hotkeysCollide: Bool {
        commandHotkeyOption == hotkeyOption
    }

    // MARK: - Private Properties

    private let defaults: UserDefaults
    private var isLoading = false

    // MARK: - Initialization

    /// - Parameter defaults: The UserDefaults instance to use. Defaults to .standard.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        removeStaleKeys()
        load()
    }

    // MARK: - Persistence Methods

    /// Saves all settings to UserDefaults.
    func save() {
        defaults.set(hotkeyOption.rawValue, forKey: Keys.hotkeyOption)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled)
        defaults.set(cleanupBackend.rawValue, forKey: Keys.cleanupBackend)
        defaults.set(audioFeedbackEnabled, forKey: Keys.audioFeedbackEnabled)
        defaults.set(audioFeedbackVolume, forKey: Keys.audioFeedbackVolume)
        defaults.set(lmStudioModelID, forKey: Keys.lmStudioModelID)
        defaults.set(lmStudioBaseURL, forKey: Keys.lmStudioBaseURL)
        defaults.set(commandModeEnabled, forKey: Keys.commandModeEnabled)
        defaults.set(commandHotkeyOption.rawValue, forKey: Keys.commandHotkeyOption)
        defaults.set(autoTransformID, forKey: Keys.autoTransformID)
        defaults.set(Array(dismissedSuggestions), forKey: Keys.dismissedSuggestions)
        defaults.set(contextAwareToneEnabled, forKey: Keys.contextAwareToneEnabled)
        defaults.set(backtrackEnabled, forKey: Keys.backtrackEnabled)
        defaults.set(adaptiveModeEnabled, forKey: Keys.adaptiveModeEnabled)
        defaults.set(appModeOverrides, forKey: Keys.appModeOverrides)
        defaults.set(customDictionaryEnabled, forKey: Keys.customDictionaryEnabled)
        defaults.set(numberFormattingEnabled, forKey: Keys.numberFormattingEnabled)
        defaults.set(numberedListsEnabled, forKey: Keys.numberedListsEnabled)
        defaults.set(fillerRemovalEnabled, forKey: Keys.fillerRemovalEnabled)
        defaults.set(spokenCommandsEnabled, forKey: Keys.spokenCommandsEnabled)
        defaults.set(spokenPunctuationEnabled, forKey: Keys.spokenPunctuationEnabled)
        defaults.set(voiceEditingEnabled, forKey: Keys.voiceEditingEnabled)
        defaults.set(voiceControlEnabled, forKey: Keys.voiceControlEnabled)
        defaults.set(activeModeID, forKey: Keys.activeModeID)
        defaults.set(onboardingComplete, forKey: Keys.onboardingComplete)

        let overrides = Dictionary(uniqueKeysWithValues: toneOverrides.map { ($0.key.rawValue, $0.value.rawValue) })
        defaults.set(overrides, forKey: Keys.toneOverrides)
    }

    /// Loads all settings from UserDefaults.
    func load() {
        isLoading = true
        defer { isLoading = false }

        if let hotkeyRawValue = defaults.string(forKey: Keys.hotkeyOption),
           let loadedHotkey = HotkeyOption(rawValue: hotkeyRawValue) {
            hotkeyOption = loadedHotkey
        }

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        cleanupEnabled = defaults.bool(forKey: Keys.cleanupEnabled)
        if let raw = defaults.string(forKey: Keys.cleanupBackend),
           let backend = CleanupBackend(rawValue: raw) {
            cleanupBackend = backend
        }

        if defaults.object(forKey: Keys.audioFeedbackEnabled) != nil {
            audioFeedbackEnabled = defaults.bool(forKey: Keys.audioFeedbackEnabled)
        } else {
            audioFeedbackEnabled = true
        }

        if defaults.object(forKey: Keys.audioFeedbackVolume) != nil {
            audioFeedbackVolume = defaults.float(forKey: Keys.audioFeedbackVolume)
        } else {
            audioFeedbackVolume = 0.5
        }

        lmStudioModelID = defaults.string(forKey: Keys.lmStudioModelID)

        if let baseURL = defaults.string(forKey: Keys.lmStudioBaseURL), !baseURL.isEmpty {
            lmStudioBaseURL = baseURL
        } else {
            lmStudioBaseURL = Constants.defaultLMStudioBaseURL
        }

        if defaults.object(forKey: Keys.commandModeEnabled) != nil {
            commandModeEnabled = defaults.bool(forKey: Keys.commandModeEnabled)
        } else {
            commandModeEnabled = true
        }

        if let raw = defaults.string(forKey: Keys.commandHotkeyOption),
           let option = HotkeyOption(rawValue: raw) {
            commandHotkeyOption = option
        }

        autoTransformID = defaults.string(forKey: Keys.autoTransformID)
        dismissedSuggestions = Set(defaults.stringArray(forKey: Keys.dismissedSuggestions) ?? [])

        if defaults.object(forKey: Keys.contextAwareToneEnabled) != nil {
            contextAwareToneEnabled = defaults.bool(forKey: Keys.contextAwareToneEnabled)
        } else {
            contextAwareToneEnabled = true
        }

        if defaults.object(forKey: Keys.backtrackEnabled) != nil {
            backtrackEnabled = defaults.bool(forKey: Keys.backtrackEnabled)
        } else {
            backtrackEnabled = true
        }

        if defaults.object(forKey: Keys.adaptiveModeEnabled) != nil {
            adaptiveModeEnabled = defaults.bool(forKey: Keys.adaptiveModeEnabled)
        } else {
            adaptiveModeEnabled = true
        }

        appModeOverrides = defaults.dictionary(forKey: Keys.appModeOverrides) as? [String: String] ?? [:]

        if defaults.object(forKey: Keys.customDictionaryEnabled) != nil {
            customDictionaryEnabled = defaults.bool(forKey: Keys.customDictionaryEnabled)
        } else {
            customDictionaryEnabled = true
        }

        if defaults.object(forKey: Keys.numberFormattingEnabled) != nil {
            numberFormattingEnabled = defaults.bool(forKey: Keys.numberFormattingEnabled)
        } else {
            numberFormattingEnabled = true
        }

        if defaults.object(forKey: Keys.numberedListsEnabled) != nil {
            numberedListsEnabled = defaults.bool(forKey: Keys.numberedListsEnabled)
        } else {
            numberedListsEnabled = true
        }

        if defaults.object(forKey: Keys.fillerRemovalEnabled) != nil {
            fillerRemovalEnabled = defaults.bool(forKey: Keys.fillerRemovalEnabled)
        } else {
            fillerRemovalEnabled = true
        }

        if defaults.object(forKey: Keys.spokenCommandsEnabled) != nil {
            spokenCommandsEnabled = defaults.bool(forKey: Keys.spokenCommandsEnabled)
        } else {
            spokenCommandsEnabled = true
        }

        if defaults.object(forKey: Keys.spokenPunctuationEnabled) != nil {
            spokenPunctuationEnabled = defaults.bool(forKey: Keys.spokenPunctuationEnabled)
        } else {
            spokenPunctuationEnabled = true
        }

        if defaults.object(forKey: Keys.voiceEditingEnabled) != nil {
            voiceEditingEnabled = defaults.bool(forKey: Keys.voiceEditingEnabled)
        } else {
            voiceEditingEnabled = true
        }

        if defaults.object(forKey: Keys.voiceControlEnabled) != nil {
            voiceControlEnabled = defaults.bool(forKey: Keys.voiceControlEnabled)
        } else {
            voiceControlEnabled = true
        }

        activeModeID = defaults.string(forKey: Keys.activeModeID)

        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)

        if let raw = defaults.dictionary(forKey: Keys.toneOverrides) as? [String: String] {
            var parsed: [AppCategory: ToneStyle] = [:]
            for (key, value) in raw {
                if let category = AppCategory(rawValue: key), let tone = ToneStyle(rawValue: value) {
                    parsed[category] = tone
                }
            }
            toneOverrides = parsed
        }
    }

    // MARK: - Utility Methods

    /// Resets all settings to default values.
    func reset() {
        hotkeyOption = .rightCommandHold
        launchAtLogin = false
        cleanupEnabled = false
        cleanupBackend = .automatic
        audioFeedbackEnabled = true
        audioFeedbackVolume = 0.5
        lmStudioModelID = nil
        lmStudioBaseURL = Constants.defaultLMStudioBaseURL
        commandModeEnabled = true
        commandHotkeyOption = .rightOptionHold
        autoTransformID = nil
        dismissedSuggestions = []
        contextAwareToneEnabled = true
        backtrackEnabled = true
        adaptiveModeEnabled = true
        appModeOverrides = [:]
        toneOverrides = [:]
        customDictionaryEnabled = true
        numberFormattingEnabled = true
        numberedListsEnabled = true
        fillerRemovalEnabled = true
        spokenCommandsEnabled = true
        spokenPunctuationEnabled = true
        voiceEditingEnabled = true
        voiceControlEnabled = true
        activeModeID = nil
        // onboardingComplete intentionally not reset — it tracks lifetime state.

        for key in [
            Keys.hotkeyOption, Keys.launchAtLogin, Keys.cleanupEnabled,
            Keys.audioFeedbackEnabled, Keys.audioFeedbackVolume, Keys.lmStudioModelID,
            Keys.lmStudioBaseURL, Keys.commandModeEnabled, Keys.commandHotkeyOption, Keys.autoTransformID,
            Keys.dismissedSuggestions,
            Keys.contextAwareToneEnabled, Keys.backtrackEnabled, Keys.adaptiveModeEnabled,
            Keys.appModeOverrides, Keys.toneOverrides, Keys.customDictionaryEnabled,
            Keys.numberFormattingEnabled, Keys.numberedListsEnabled, Keys.fillerRemovalEnabled,
            Keys.spokenCommandsEnabled, Keys.spokenPunctuationEnabled,
            Keys.voiceEditingEnabled, Keys.voiceControlEnabled, Keys.activeModeID,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes settings left over from the cloud-based versions of the app.
    /// The old `cleanupEnabled` flag controlled cloud cleanup and defaulted to on,
    /// so it is reset once rather than carried over to LM Studio cleanup.
    private func removeStaleKeys() {
        for key in Keys.staleKeys {
            defaults.removeObject(forKey: key)
        }
        if !defaults.bool(forKey: Keys.legacyCleanupMigrated) {
            defaults.removeObject(forKey: Keys.cleanupEnabled)
            defaults.set(true, forKey: Keys.legacyCleanupMigrated)
        }
    }
}
