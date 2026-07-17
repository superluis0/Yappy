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
    case rightControlHold = "Right Control (Hold)"

    /// Display name for UI presentation.
    var displayName: String {
        return self.rawValue
    }
}

/// Whether the chosen dictation key (`HotkeyOption`) must be HELD for the
/// whole recording, or a quick double-tap LOCKS a hands-free recording that a
/// single tap then stops. Orthogonal to which key is picked — applies to all
/// four `HotkeyOption` presets. See `HotkeyStateMachine` for the edge logic.
enum HotkeyActivation: String, CaseIterable, Codable {
    case holdToTalk
    case doubleTapLock

    /// Display name for UI presentation.
    var displayName: String {
        switch self {
        case .holdToTalk: return "Hold to Talk"
        case .doubleTapLock: return "Double-Tap Lock"
        }
    }

    /// One-line explainer shown under the Activation picker in Settings.
    var explainer: String {
        switch self {
        case .holdToTalk:
            return "Hold the key down to record; release it to stop."
        case .doubleTapLock:
            return "Double-tap the key to start a hands-free recording; a single tap stops it."
        }
    }
}

/// Selectable on-device speech-to-text model. Both are FluidAudio CoreML models
/// used in batch mode (transcribe the full recorded buffer on hotkey release).
enum TranscriptionModel: String, CaseIterable, Codable {
    /// English-only Parakeet TDT (~443 MB). The default — fastest, no new download.
    case parakeet
    /// NVIDIA Nemotron multilingual (~670 MB). Handles many languages.
    case nemotron

    /// Display name for UI presentation.
    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet (English)"
        case .nemotron: return "Nemotron (Multilingual)"
        }
    }
}

/// The glowing rim around the recording pill while it listens.
enum ListeningGlowStyle: String, CaseIterable, Codable, Identifiable {
    case rainbow
    case white
    case orange

    var id: String { rawValue }

    /// Display name for UI presentation.
    var displayName: String {
        switch self {
        case .rainbow: return "Rainbow"
        case .white: return "White"
        case .orange: return "Orange"
        }
    }
}

/// How aggressively AI cleanup reshapes a transcript.
/// - `standard`: punctuation, casing, fillers, and light polish (today's behavior).
/// - `conservative`: punctuation, capitalization, and standalone fillers only —
///   no rewording or restructuring.
enum CleanupIntensity: String, CaseIterable, Codable, Identifiable {
    case conservative
    case standard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conservative: return "Conservative"
        case .standard: return "Standard"
        }
    }
}

/// Application settings with UserDefaults persistence.
/// Fully local — no API keys. AI cleanup runs on-device via Apple Intelligence
/// (Foundation Models, macOS 26+); nothing leaves the Mac.
final class Settings: ObservableObject {
    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyOption = "com.yappy.hotkeyOption"
        static let hotkeyActivation = "com.yappy.hotkeyActivation"
        static let transcriptionModel = "com.yappy.transcriptionModel"
        static let launchAtLogin = "com.yappy.launchAtLogin"
        static let cleanupEnabled = "com.yappy.cleanupEnabled"
        static let audioFeedbackEnabled = "com.yappy.audioFeedbackEnabled"
        static let listeningGlowStyle = "com.yappy.listeningGlowStyle"
        static let askHotkeyOption = "com.yappy.askHotkeyOption"
        static let audioFeedbackVolume = "com.yappy.audioFeedbackVolume"
        static let dismissedSuggestions = "com.yappy.dismissedSuggestions"
        static let contextAwareToneEnabled = "com.yappy.contextAwareToneEnabled"
        static let backtrackEnabled = "com.yappy.backtrackEnabled"
        static let toneOverrides = "com.yappy.toneOverrides"
        static let adaptiveModeEnabled = "com.yappy.adaptiveModeEnabled"
        static let appModeOverrides = "com.yappy.appModeOverrides"
        static let customDictionaryEnabled = "com.yappy.customDictionaryEnabled"
        static let vocabularyBoostingEnabled = "com.yappy.vocabularyBoostingEnabled"
        static let numberFormattingEnabled = "com.yappy.numberFormattingEnabled"
        static let numberedListsEnabled = "com.yappy.numberedListsEnabled"
        static let fillerRemovalEnabled = "com.yappy.fillerRemovalEnabled"
        static let spokenCommandsEnabled = "com.yappy.spokenCommandsEnabled"
        static let spokenPunctuationEnabled = "com.yappy.spokenPunctuationEnabled"
        static let voiceEditingEnabled = "com.yappy.voiceEditingEnabled"
        static let voiceControlEnabled = "com.yappy.voiceControlEnabled"
        static let voiceEditAnywhereEnabled = "com.yappy.voiceEditAnywhereEnabled"
        static let saveHistoryEnabled = "com.yappy.saveHistoryEnabled"
        static let historyRetentionDays = "com.yappy.historyRetentionDays"
        static let activeModeID = "com.yappy.activeModeID"
        static let useCases = "com.yappy.useCases"
        static let onboardingComplete = "com.yappy.onboardingComplete"
        static let hasTriedMode = "com.yappy.hasTriedMode"
        static let hasAddedDictionaryTerm = "com.yappy.hasAddedDictionaryTerm"
        static let hasOpenedScratchpad = "com.yappy.hasOpenedScratchpad"
        static let autoUpdateChecksEnabled = "com.yappy.autoUpdateChecksEnabled"
        static let legacyCleanupMigrated = "com.yappy.legacyCleanupMigrated"
        static let cleanupDefaultOnMigrated = "com.yappy.cleanupDefaultOnMigrated"
        static let askEnabled = "com.yappy.askEnabled"
        static let askBackend = "com.yappy.askBackend"
        static let askGrokModel = "com.yappy.askGrokModel"
        static let askSaveHistoryEnabled = "com.yappy.askSaveHistoryEnabled"
        static let answersSpeakEnabled = "com.yappy.answersSpeakEnabled"
        static let answersAutoSpeak = "com.yappy.answersAutoSpeak"
        static let answersVoice = "com.yappy.answersVoice"
        static let answersVoiceSpeed = "com.yappy.answersVoiceSpeed"
        static let dictionaryAutoLearnEnabled = "com.yappy.dictionaryAutoLearnEnabled"
        static let cleanupIntensity = "com.yappy.cleanupIntensity"
        static let cleanupDiffCaptionEnabled = "com.yappy.cleanupDiffCaptionEnabled"

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

    /// Whether the chosen hotkey must be held, or double-tapped to lock a
    /// hands-free recording. Orthogonal to `hotkeyOption`; applies to any key.
    @Published var hotkeyActivation: HotkeyActivation = .holdToTalk {
        didSet { if !isLoading { save() } }
    }

    /// On-device speech-to-text model used for dictation. Default Parakeet
    /// (English); switching to Nemotron downloads the multilingual model.
    @Published var transcriptionModel: TranscriptionModel = .parakeet {
        didSet { if !isLoading { save() } }
    }

    /// Whether the app should launch automatically at login.
    @Published var launchAtLogin: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Whether to clean up transcripts with on-device Apple Intelligence.
    /// On by default (set once via a one-time migration; see `removeStaleKeys`).
    @Published var cleanupEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// How aggressively cleanup reshapes text. Default `.standard` (today's
    /// full polish). `.conservative` only fixes punctuation/casing/fillers.
    @Published var cleanupIntensity: CleanupIntensity = .standard {
        didSet { if !isLoading { save() } }
    }

    /// After insert, briefly show a neutral pill caption when cleanup changed
    /// the words — click reverts to the raw pre-cleanup transcript.
    @Published var cleanupDiffCaptionEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// When on, high-confidence "scratch that" corrections are applied as
    /// learned aliases immediately (with a click-to-undo caption). Low-
    /// confidence pairs still surface as Dictionary suggestion cards.
    @Published var dictionaryAutoLearnEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether audio feedback sounds are enabled.
    @Published var audioFeedbackEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// The glowing rim style around the recording pill while listening.
    @Published var listeningGlowStyle: ListeningGlowStyle = .rainbow {
        didSet { if !isLoading { save() } }
    }

    /// Which key summons Answers. Fn/Globe by default; the alternatives exist
    /// for keyboards whose Fn never reaches macOS (firmware-local Fn on many
    /// external boards).
    @Published var askHotkeyOption: AskHotkeyOption = .fnGlobe {
        didSet { if !isLoading { save() } }
    }

    /// Volume level for audio feedback (0.0 - 1.0).
    @Published var audioFeedbackVolume: Float = 0.5 {
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

    /// Whether the speech model itself is biased toward the custom-dictionary terms
    /// (Parakeet/English only, via FluidAudio's CTC custom-vocabulary rescoring).
    /// Off by default: it downloads a ~98 MB helper model on first use and adds one
    /// extra inference pass per dictation, so it's strictly opt-in. Distinct from
    /// `customDictionaryEnabled`, which only drives post-hoc find/replace.
    @Published var vocabularyBoostingEnabled: Bool = false {
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

    /// Whether "Voice Edit Anywhere" is armed: select text in any app, hold Right
    /// Option, speak an instruction, and Replace from a preview card. Experimental
    /// and OFF by default — a distinct feature from `voiceEditingEnabled` (which
    /// edits the LAST dictation in place via "scratch that" / "all caps that").
    @Published var voiceEditAnywhereEnabled: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Whether a local log of past dictations is kept (for Home stats and the
    /// history list). On by default. When off, nothing is written to disk — the
    /// skip is enforced at the `HistoryStore.add` call site. The log is always
    /// on-device; it never leaves the Mac.
    @Published var saveHistoryEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// How many days of dictation history to keep before pruning; `0` = keep
    /// forever. Enforced by `HistoryStore` (which mirrors this value into its
    /// `retentionDays` at the app layer).
    @Published var historyRetentionDays: Int = 0 {
        didSet { if !isLoading { save() } }
    }

    /// The explicitly-selected dictation mode's id (UUID string); nil = Auto.
    @Published var activeModeID: String? {
        didSet { if !isLoading { save() } }
    }

    /// Use cases the user picked during onboarding (raw values of `UseCase`).
    /// Drives the preset Modes + seeded dictionary terms; purely informational
    /// afterward, since the user can change Modes and the dictionary freely.
    @Published var useCases: Set<String> = [] {
        didSet { if !isLoading { save() } }
    }

    /// Whether the first-run onboarding flow has been completed.
    @Published var onboardingComplete: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Whether the user has ever activated a non-Auto Mode. Backs the Home
    /// getting-started checklist; remembers "ever" since the current mode can
    /// be switched back to Auto. Set once at the mode-switch site.
    @Published var hasTriedMode: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Whether the user has ever added their own dictionary term (not a built-in
    /// or onboarding-seeded one). Backs the Home getting-started checklist.
    @Published var hasAddedDictionaryTerm: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Whether the user has ever opened the Scratchpad (⌥⇧S). Backs the Home
    /// getting-started checklist.
    @Published var hasOpenedScratchpad: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Whether Sparkle checks for app updates automatically in the background.
    /// On by default; mirrored into the updater (see `UpdateChecker`).
    @Published var autoUpdateChecksEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    // MARK: - Tone Resolution

    /// The effective tone for a category: the user override, or the category default.
    func tone(for category: AppCategory) -> ToneStyle {
        toneOverrides[category] ?? category.defaultTone
    }

    // MARK: - Private Properties

    private let defaults: UserDefaults
    // MARK: - Ask (hold-Fn voice questions)

    /// Whether the Fn "Ask" key is armed. Default OFF — this is the privacy
    /// gate: until the user flips it, nothing Yappy does touches the network.
    @Published var askEnabled: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Which backend answers Ask questions.
    @Published var askBackend: AskBackend = .codex {
        didSet { if !isLoading { save() } }
    }

    /// Which xAI model the Grok backend routes to.
    @Published var askGrokModel: AskGrokModel = .grok45 {
        didSet { if !isLoading { save() } }
    }

    /// Whether completed Ask Q&A pairs are kept in the local Ask history log.
    /// On by default. When off, nothing new is written — existing entries stay.
    @Published var askSaveHistoryEnabled: Bool = true {
        didSet { if !isLoading { save() } }
    }

    /// Whether completed Ask answers can be read aloud locally.
    @Published var answersSpeakEnabled: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Whether completed Ask answers are read aloud automatically.
    @Published var answersAutoSpeak: Bool = false {
        didSet { if !isLoading { save() } }
    }

    /// Selected on-device voice for reading completed Ask answers.
    @Published var answersVoice: String = AnswersVoice.afHeart.rawValue {
        didSet { if !isLoading { save() } }
    }

    /// Playback speed for reading Answers aloud.
    @Published var answersVoiceSpeed: AnswersVoiceSpeed = .normal {
        didSet { if !isLoading { save() } }
    }

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
        defaults.set(hotkeyActivation.rawValue, forKey: Keys.hotkeyActivation)
        defaults.set(transcriptionModel.rawValue, forKey: Keys.transcriptionModel)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled)
        defaults.set(cleanupIntensity.rawValue, forKey: Keys.cleanupIntensity)
        defaults.set(cleanupDiffCaptionEnabled, forKey: Keys.cleanupDiffCaptionEnabled)
        defaults.set(dictionaryAutoLearnEnabled, forKey: Keys.dictionaryAutoLearnEnabled)
        defaults.set(audioFeedbackEnabled, forKey: Keys.audioFeedbackEnabled)
        defaults.set(listeningGlowStyle.rawValue, forKey: Keys.listeningGlowStyle)
        defaults.set(askHotkeyOption.rawValue, forKey: Keys.askHotkeyOption)
        defaults.set(audioFeedbackVolume, forKey: Keys.audioFeedbackVolume)
        defaults.set(Array(dismissedSuggestions), forKey: Keys.dismissedSuggestions)
        defaults.set(contextAwareToneEnabled, forKey: Keys.contextAwareToneEnabled)
        defaults.set(backtrackEnabled, forKey: Keys.backtrackEnabled)
        defaults.set(adaptiveModeEnabled, forKey: Keys.adaptiveModeEnabled)
        defaults.set(appModeOverrides, forKey: Keys.appModeOverrides)
        defaults.set(customDictionaryEnabled, forKey: Keys.customDictionaryEnabled)
        defaults.set(vocabularyBoostingEnabled, forKey: Keys.vocabularyBoostingEnabled)
        defaults.set(numberFormattingEnabled, forKey: Keys.numberFormattingEnabled)
        defaults.set(numberedListsEnabled, forKey: Keys.numberedListsEnabled)
        defaults.set(fillerRemovalEnabled, forKey: Keys.fillerRemovalEnabled)
        defaults.set(spokenCommandsEnabled, forKey: Keys.spokenCommandsEnabled)
        defaults.set(spokenPunctuationEnabled, forKey: Keys.spokenPunctuationEnabled)
        defaults.set(voiceEditingEnabled, forKey: Keys.voiceEditingEnabled)
        defaults.set(voiceControlEnabled, forKey: Keys.voiceControlEnabled)
        defaults.set(voiceEditAnywhereEnabled, forKey: Keys.voiceEditAnywhereEnabled)
        defaults.set(saveHistoryEnabled, forKey: Keys.saveHistoryEnabled)
        defaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays)
        defaults.set(activeModeID, forKey: Keys.activeModeID)
        defaults.set(Array(useCases), forKey: Keys.useCases)
        defaults.set(onboardingComplete, forKey: Keys.onboardingComplete)
        defaults.set(hasTriedMode, forKey: Keys.hasTriedMode)
        defaults.set(hasAddedDictionaryTerm, forKey: Keys.hasAddedDictionaryTerm)
        defaults.set(hasOpenedScratchpad, forKey: Keys.hasOpenedScratchpad)
        defaults.set(autoUpdateChecksEnabled, forKey: Keys.autoUpdateChecksEnabled)
        defaults.set(askEnabled, forKey: Keys.askEnabled)
        defaults.set(askBackend.rawValue, forKey: Keys.askBackend)
        defaults.set(askGrokModel.rawValue, forKey: Keys.askGrokModel)
        defaults.set(askSaveHistoryEnabled, forKey: Keys.askSaveHistoryEnabled)
        defaults.set(answersSpeakEnabled, forKey: Keys.answersSpeakEnabled)
        defaults.set(answersAutoSpeak, forKey: Keys.answersAutoSpeak)
        defaults.set(answersVoice, forKey: Keys.answersVoice)
        defaults.set(answersVoiceSpeed.rawValue, forKey: Keys.answersVoiceSpeed)

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

        if let activationRawValue = defaults.string(forKey: Keys.hotkeyActivation),
           let loadedActivation = HotkeyActivation(rawValue: activationRawValue) {
            hotkeyActivation = loadedActivation
        }

        // Legacy migration: "Right Command (Double Tap)" used to bake double-tap
        // timing into the hotkey CHOICE itself. Activation is now orthogonal to
        // the key, so fold that preset onto the new pair — same physical key
        // (Right ⌘), activation moved to its own setting — and persist the
        // normalized pair immediately (`isLoading` suppresses the `didSet`
        // auto-save above) so this only ever runs once and the choice survives
        // the next launch even if this one crashes before another save.
        if hotkeyOption == .rightCommandDoubleTap {
            hotkeyOption = .rightCommandHold
            hotkeyActivation = .doubleTapLock
            defaults.set(hotkeyOption.rawValue, forKey: Keys.hotkeyOption)
            defaults.set(hotkeyActivation.rawValue, forKey: Keys.hotkeyActivation)
        }

        if let modelRawValue = defaults.string(forKey: Keys.transcriptionModel),
           let loadedModel = TranscriptionModel(rawValue: modelRawValue) {
            transcriptionModel = loadedModel
        }

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        if defaults.object(forKey: Keys.cleanupEnabled) != nil {
            cleanupEnabled = defaults.bool(forKey: Keys.cleanupEnabled)
        } else {
            cleanupEnabled = true
        }

        if let intensityRaw = defaults.string(forKey: Keys.cleanupIntensity),
           let loadedIntensity = CleanupIntensity(rawValue: intensityRaw) {
            cleanupIntensity = loadedIntensity
        } else {
            cleanupIntensity = .standard
        }

        if defaults.object(forKey: Keys.cleanupDiffCaptionEnabled) != nil {
            cleanupDiffCaptionEnabled = defaults.bool(forKey: Keys.cleanupDiffCaptionEnabled)
        } else {
            cleanupDiffCaptionEnabled = true
        }

        if defaults.object(forKey: Keys.dictionaryAutoLearnEnabled) != nil {
            dictionaryAutoLearnEnabled = defaults.bool(forKey: Keys.dictionaryAutoLearnEnabled)
        } else {
            dictionaryAutoLearnEnabled = true
        }

        if let glowRaw = defaults.string(forKey: Keys.listeningGlowStyle),
           let loadedGlow = ListeningGlowStyle(rawValue: glowRaw) {
            listeningGlowStyle = loadedGlow
        }

        if let askKeyRaw = defaults.string(forKey: Keys.askHotkeyOption),
           let loadedAskKey = AskHotkeyOption(rawValue: askKeyRaw) {
            askHotkeyOption = loadedAskKey
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

        // Off by default (absent key → false), like the checklist flags.
        vocabularyBoostingEnabled = defaults.bool(forKey: Keys.vocabularyBoostingEnabled)

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

        // Experimental — OFF by default (absent key → false).
        voiceEditAnywhereEnabled = defaults.bool(forKey: Keys.voiceEditAnywhereEnabled)

        if defaults.object(forKey: Keys.saveHistoryEnabled) != nil {
            saveHistoryEnabled = defaults.bool(forKey: Keys.saveHistoryEnabled)
        } else {
            saveHistoryEnabled = true
        }

        // Absent key → 0 (keep forever), which is exactly `integer(forKey:)`'s default.
        historyRetentionDays = defaults.integer(forKey: Keys.historyRetentionDays)

        activeModeID = defaults.string(forKey: Keys.activeModeID)

        useCases = Set(defaults.stringArray(forKey: Keys.useCases) ?? [])

        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)

        // Checklist progress flags default to false (absent key → false).
        hasTriedMode = defaults.bool(forKey: Keys.hasTriedMode)
        hasAddedDictionaryTerm = defaults.bool(forKey: Keys.hasAddedDictionaryTerm)
        hasOpenedScratchpad = defaults.bool(forKey: Keys.hasOpenedScratchpad)

        if defaults.object(forKey: Keys.autoUpdateChecksEnabled) != nil {
            autoUpdateChecksEnabled = defaults.bool(forKey: Keys.autoUpdateChecksEnabled)
        } else {
            autoUpdateChecksEnabled = true
        }

        askEnabled = defaults.bool(forKey: Keys.askEnabled)
        if let backendRaw = defaults.string(forKey: Keys.askBackend),
           let loadedBackend = AskBackend(rawValue: backendRaw) {
            askBackend = loadedBackend
        }
        if let grokModelRaw = defaults.string(forKey: Keys.askGrokModel),
           let loadedGrokModel = AskGrokModel(rawValue: grokModelRaw) {
            askGrokModel = loadedGrokModel
        }

        if defaults.object(forKey: Keys.askSaveHistoryEnabled) != nil {
            askSaveHistoryEnabled = defaults.bool(forKey: Keys.askSaveHistoryEnabled)
        } else {
            askSaveHistoryEnabled = true
        }
        answersSpeakEnabled = defaults.bool(forKey: Keys.answersSpeakEnabled)
        answersAutoSpeak = defaults.bool(forKey: Keys.answersAutoSpeak)
        if let rawVoice = defaults.string(forKey: Keys.answersVoice),
           AnswersVoice(rawValue: rawVoice) != nil {
            answersVoice = rawVoice
        } else {
            answersVoice = AnswersVoice.afHeart.rawValue
            defaults.set(answersVoice, forKey: Keys.answersVoice)
        }
        if let rawSpeed = defaults.string(forKey: Keys.answersVoiceSpeed),
           let loadedSpeed = AnswersVoiceSpeed(rawValue: rawSpeed) {
            answersVoiceSpeed = loadedSpeed
        }

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
        hotkeyActivation = .holdToTalk
        transcriptionModel = .parakeet
        launchAtLogin = false
        cleanupEnabled = true
        cleanupIntensity = .standard
        cleanupDiffCaptionEnabled = true
        dictionaryAutoLearnEnabled = true
        audioFeedbackEnabled = true
        audioFeedbackVolume = 0.5
        dismissedSuggestions = []
        contextAwareToneEnabled = true
        backtrackEnabled = true
        adaptiveModeEnabled = true
        appModeOverrides = [:]
        toneOverrides = [:]
        customDictionaryEnabled = true
        vocabularyBoostingEnabled = false
        numberFormattingEnabled = true
        numberedListsEnabled = true
        fillerRemovalEnabled = true
        spokenCommandsEnabled = true
        spokenPunctuationEnabled = true
        voiceEditingEnabled = true
        voiceControlEnabled = true
        voiceEditAnywhereEnabled = false
        saveHistoryEnabled = true
        historyRetentionDays = 0
        activeModeID = nil
        useCases = []
        autoUpdateChecksEnabled = true
        answersSpeakEnabled = false
        answersAutoSpeak = false
        answersVoice = AnswersVoice.afHeart.rawValue
        // onboardingComplete and the has* checklist flags are intentionally not
        // reset — like onboarding completion, they track lifetime "ever did this"
        // state, so a settings reset shouldn't resurrect the getting-started card.

        for key in [
            Keys.hotkeyOption, Keys.hotkeyActivation, Keys.transcriptionModel, Keys.launchAtLogin, Keys.cleanupEnabled,
            Keys.cleanupIntensity, Keys.cleanupDiffCaptionEnabled, Keys.dictionaryAutoLearnEnabled,
            Keys.audioFeedbackEnabled, Keys.audioFeedbackVolume,
            Keys.dismissedSuggestions,
            Keys.contextAwareToneEnabled, Keys.backtrackEnabled, Keys.adaptiveModeEnabled,
            Keys.appModeOverrides, Keys.toneOverrides, Keys.customDictionaryEnabled,
            Keys.vocabularyBoostingEnabled,
            Keys.numberFormattingEnabled, Keys.numberedListsEnabled, Keys.fillerRemovalEnabled,
            Keys.spokenCommandsEnabled, Keys.spokenPunctuationEnabled,
            Keys.voiceEditingEnabled, Keys.voiceControlEnabled, Keys.voiceEditAnywhereEnabled,
            Keys.saveHistoryEnabled, Keys.historyRetentionDays, Keys.activeModeID,
            Keys.useCases, Keys.autoUpdateChecksEnabled,
            Keys.answersSpeakEnabled, Keys.answersAutoSpeak, Keys.answersVoice,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes settings left over from the cloud-based versions of the app, then
    /// applies the one-time "cleanup on by default" migration.
    ///
    /// The old `cleanupEnabled` flag controlled cloud cleanup and defaulted to on,
    /// so the legacy block clears it once rather than carrying that intent over to
    /// on-device cleanup. The default-on block (which must run AFTER the legacy one,
    /// since that can `removeObject` the key) then force-enables on-device Apple
    /// Intelligence cleanup a single time for new and existing users. A later
    /// explicit toggle is written to `cleanupEnabled` and respected on next launch.
    private func removeStaleKeys() {
        for key in Keys.staleKeys {
            defaults.removeObject(forKey: key)
        }
        if !defaults.bool(forKey: Keys.legacyCleanupMigrated) {
            defaults.removeObject(forKey: Keys.cleanupEnabled)
            defaults.set(true, forKey: Keys.legacyCleanupMigrated)
        }
        if !defaults.bool(forKey: Keys.cleanupDefaultOnMigrated) {
            defaults.set(true, forKey: Keys.cleanupEnabled)
            defaults.set(true, forKey: Keys.cleanupDefaultOnMigrated)
        }
    }
}
