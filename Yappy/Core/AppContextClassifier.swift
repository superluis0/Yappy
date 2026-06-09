//
//  AppContextClassifier.swift
//  Yappy
//

import Foundation

/// Broad category of the app receiving dictation, used to pick a default tone.
enum AppCategory: String, CaseIterable, Codable {
    case email
    case workChat
    case personalChat
    case code
    case other

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .workChat: return "Work chat"
        case .personalChat: return "Personal chat"
        case .code: return "Code & terminal"
        case .other: return "Other"
        }
    }

    /// Default tone per category.
    var defaultTone: ToneStyle {
        switch self {
        case .email, .workChat: return .formal
        case .personalChat: return .casual
        case .code: return .verbatim
        case .other: return .formal
        }
    }
}

/// How the cleanup model should shape the text.
enum ToneStyle: String, CaseIterable, Codable {
    case verbatim   // minimal cleanup, preserve as-is (good for code)
    case formal
    case casual
    case excited

    var displayName: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .excited: return "Excited"
        }
    }

    /// Guidance injected into the cleanup system prompt.
    var promptGuidance: String {
        switch self {
        case .verbatim:
            return "Keep the text essentially verbatim. Only fix obvious transcription errors. Do not reword, do not reformat, preserve any code or commands exactly."
        case .formal:
            return "Use a clear, professional tone with proper punctuation and complete sentences."
        case .casual:
            return "Use a relaxed, conversational tone; contractions are fine; keep it natural."
        case .excited:
            return "Use an upbeat, enthusiastic tone while keeping the original meaning."
        }
    }
}

/// Maps the frontmost application's bundle identifier to a category.
enum AppContextClassifier {
    private static let map: [String: AppCategory] = [
        // Email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.mail": .email,
        "com.CanaryMail": .email,
        // Work chat
        "com.tinyspeck.slackmacgap": .workChat,
        "com.microsoft.teams2": .workChat,
        "com.microsoft.teams": .workChat,
        "com.hnc.Discord": .workChat,
        "com.google.Chat": .workChat,
        // Personal chat
        "com.apple.MobileSMS": .personalChat,
        "net.whatsapp.WhatsApp": .personalChat,
        "org.whispersystems.signal-desktop": .personalChat,
        "ru.keepcoder.Telegram": .personalChat,
        "com.facebook.archon": .personalChat,
        // Code & terminal
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "com.microsoft.VSCodeInsiders": .code,
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "dev.warp.Warp-Stable": .code,
        "com.jetbrains.intellij": .code,
        "com.jetbrains.pycharm": .code,
        "com.sublimetext.4": .code,
        "com.todesktop.230313mzl4w4u92": .code, // Cursor
    ]

    static func category(forBundleID bundleID: String?) -> AppCategory {
        guard let bundleID else { return .other }
        return map[bundleID] ?? .other
    }
}
