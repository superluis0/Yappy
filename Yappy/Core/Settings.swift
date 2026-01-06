//
//  Settings.swift
//  Yappy
//
//  Created on 2026-01-04.
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

/// Application settings with UserDefaults persistence.
/// Manages API keys, hotkey preferences, and application behavior settings.
final class Settings: ObservableObject {
    // MARK: - UserDefaults Keys

    private enum Keys {
        static let openAIAPIKey = "com.yappy.openAIAPIKey"
        static let openRouterAPIKey = "com.yappy.openRouterAPIKey"
        static let hotkeyOption = "com.yappy.hotkeyOption"
        static let launchAtLogin = "com.yappy.launchAtLogin"
        static let cleanupEnabled = "com.yappy.cleanupEnabled"
        static let voiceCommandsEnabled = "com.yappy.voiceCommandsEnabled"
        static let audioFeedbackEnabled = "com.yappy.audioFeedbackEnabled"
        static let audioFeedbackVolume = "com.yappy.audioFeedbackVolume"
        static let streamingTextEnabled = "com.yappy.streamingTextEnabled"
    }

    // MARK: - Published Properties

    /// OpenAI API key for Whisper transcription service.
    @Published var openAIAPIKey: String = "" {
        didSet {
            if isLoading { return }
            save()
        }
    }

    /// OpenRouter API key for Grok cleanup/enhancement service.
    @Published var openRouterAPIKey: String = "" {
        didSet {
            if isLoading { return }
            save()
        }
    }

    /// Selected hotkey activation method.
    @Published var hotkeyOption: HotkeyOption = .rightCommandHold {
        didSet {
            if isLoading { return }
            save()
        }
    }

    /// Whether the app should launch automatically at login.
    @Published var launchAtLogin: Bool = false {
        didSet {
            if isLoading { return }
            save()
        }
    }

    /// Whether to enable AI-powered transcription cleanup.
    @Published var cleanupEnabled: Bool = true {
        didSet {
            if isLoading { return }
            save()
        }
    }

    /// Whether voice commands are enabled (e.g., "delete that", "new line").
    @Published var voiceCommandsEnabled: Bool = true {
        didSet {
            if isLoading { return }
            save()
        }
    }

    /// Whether audio feedback sounds are enabled.
    @Published var audioFeedbackEnabled: Bool = true {
        didSet {
            if isLoading { return }
            save()
        }
    }

    /// Volume level for audio feedback (0.0 - 1.0).
    @Published var audioFeedbackVolume: Float = 0.5 {
        didSet {
            if isLoading { return }
            save()
        }
    }

    /// Whether streaming text insertion is enabled (word-by-word typing effect).
    @Published var streamingTextEnabled: Bool = true {
        didSet {
            if isLoading { return }
            save()
        }
    }

    // MARK: - Computed Properties

    /// Returns true if both API keys are configured.
    var isConfigured: Bool {
        return !openAIAPIKey.isEmpty && !openRouterAPIKey.isEmpty
    }

    // MARK: - Private Properties

    private let defaults: UserDefaults
    private var isLoading = false

    // MARK: - Initialization

    /// Initializes settings and loads persisted values.
    ///
    /// - Parameter defaults: The UserDefaults instance to use. Defaults to .standard.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Persistence Methods

    /// Saves all settings to UserDefaults.
    /// Called automatically when any published property changes.
    func save() {
        defaults.set(openAIAPIKey, forKey: Keys.openAIAPIKey)
        defaults.set(openRouterAPIKey, forKey: Keys.openRouterAPIKey)
        defaults.set(hotkeyOption.rawValue, forKey: Keys.hotkeyOption)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled)
        defaults.set(voiceCommandsEnabled, forKey: Keys.voiceCommandsEnabled)
        defaults.set(audioFeedbackEnabled, forKey: Keys.audioFeedbackEnabled)
        defaults.set(audioFeedbackVolume, forKey: Keys.audioFeedbackVolume)
        defaults.set(streamingTextEnabled, forKey: Keys.streamingTextEnabled)
        
        // Force synchronize to ensure values are written to disk
        defaults.synchronize()
        
        print("💾 Settings saved - OpenRouter key: \(openRouterAPIKey.isEmpty ? "empty" : "set (\(openRouterAPIKey.prefix(4))...)")")
    }

    /// Loads all settings from UserDefaults.
    /// Called during initialization to restore persisted state.
    func load() {
        isLoading = true
        defer { isLoading = false }
        
        openAIAPIKey = defaults.string(forKey: Keys.openAIAPIKey) ?? ""
        openRouterAPIKey = defaults.string(forKey: Keys.openRouterAPIKey) ?? ""

        if let hotkeyRawValue = defaults.string(forKey: Keys.hotkeyOption),
           let loadedHotkey = HotkeyOption(rawValue: hotkeyRawValue) {
            hotkeyOption = loadedHotkey
        }

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)

        // Default to true if not set, otherwise use stored value
        if defaults.object(forKey: Keys.cleanupEnabled) != nil {
            cleanupEnabled = defaults.bool(forKey: Keys.cleanupEnabled)
        } else {
            cleanupEnabled = true
        }

        // Voice commands - default to true
        if defaults.object(forKey: Keys.voiceCommandsEnabled) != nil {
            voiceCommandsEnabled = defaults.bool(forKey: Keys.voiceCommandsEnabled)
        } else {
            voiceCommandsEnabled = true
        }

        // Audio feedback - default to true
        if defaults.object(forKey: Keys.audioFeedbackEnabled) != nil {
            audioFeedbackEnabled = defaults.bool(forKey: Keys.audioFeedbackEnabled)
        } else {
            audioFeedbackEnabled = true
        }

        // Audio feedback volume - default to 0.5
        if defaults.object(forKey: Keys.audioFeedbackVolume) != nil {
            audioFeedbackVolume = defaults.float(forKey: Keys.audioFeedbackVolume)
        } else {
            audioFeedbackVolume = 0.5
        }

        // Streaming text - default to true
        if defaults.object(forKey: Keys.streamingTextEnabled) != nil {
            streamingTextEnabled = defaults.bool(forKey: Keys.streamingTextEnabled)
        } else {
            streamingTextEnabled = true
        }
        
        print("📋 Settings loaded - OpenRouter key: \(openRouterAPIKey.isEmpty ? "empty" : "set (\(openRouterAPIKey.prefix(4))...)")")
    }

    // MARK: - Utility Methods

    /// Resets all settings to default values.
    func reset() {
        openAIAPIKey = ""
        openRouterAPIKey = ""
        hotkeyOption = .rightCommandHold
        launchAtLogin = false
        cleanupEnabled = true
        voiceCommandsEnabled = true
        audioFeedbackEnabled = true
        audioFeedbackVolume = 0.5
        streamingTextEnabled = true

        // Clear from UserDefaults
        defaults.removeObject(forKey: Keys.openAIAPIKey)
        defaults.removeObject(forKey: Keys.openRouterAPIKey)
        defaults.removeObject(forKey: Keys.hotkeyOption)
        defaults.removeObject(forKey: Keys.launchAtLogin)
        defaults.removeObject(forKey: Keys.cleanupEnabled)
        defaults.removeObject(forKey: Keys.voiceCommandsEnabled)
        defaults.removeObject(forKey: Keys.audioFeedbackEnabled)
        defaults.removeObject(forKey: Keys.audioFeedbackVolume)
        defaults.removeObject(forKey: Keys.streamingTextEnabled)
    }
}
