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

        // Clear from UserDefaults
        defaults.removeObject(forKey: Keys.openAIAPIKey)
        defaults.removeObject(forKey: Keys.openRouterAPIKey)
        defaults.removeObject(forKey: Keys.hotkeyOption)
        defaults.removeObject(forKey: Keys.launchAtLogin)
        defaults.removeObject(forKey: Keys.cleanupEnabled)
    }
}
