//
//  AppContextClassifier.swift
//  Yappy
//

import ApplicationServices
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

/// The kind of text field currently holding the caret. Used to refine
/// formatting: a single-line or search field can't hold line breaks or
/// paragraphs, so dictated structure is flattened before it's inserted.
enum FocusedFieldKind {
    case singleLine   // AXTextField — a one-line input (URL bar, form field)
    case multiLine    // AXTextArea — a multi-line editor or composer
    case search       // AXSearchField subrole — Spotlight, a search box
    case unknown      // couldn't determine (no focus, opaque app, not trusted)
}

/// Reads the accessibility role/subrole of the focused element to classify the
/// kind of field receiving dictation. Advisory only: any failure yields
/// `.unknown` so it can never block or misdirect dictation.
enum FocusedFieldClassifier {
    /// Pure mapping from an AX role/subrole to a field kind, factored out so it's
    /// unit-testable without the live accessibility API. Subrole wins over role
    /// (a search field reports role `AXTextField` plus subrole `AXSearchField`).
    static func kind(role: String?, subrole: String?) -> FocusedFieldKind {
        if subrole == kAXSearchFieldSubrole as String { return .search }
        if role == kAXTextAreaRole as String { return .multiLine }
        if role == kAXTextFieldRole as String { return .singleLine }
        return .unknown
    }

    /// Reads the system-wide focused element's role + subrole and maps them to a
    /// `FocusedFieldKind`. A single cheap AX round-trip; resilient by design —
    /// returns `.unknown` on any failure (no focus, missing attribute, not
    /// trusted) rather than throwing or blocking. Mirrors the focused-element
    /// read in `TextInserter.precedingContext()`.
    static func classifyFocusedField() -> FocusedFieldKind {
        let system = AXUIElementCreateSystemWide()
        var focusedObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focusedObj) == .success,
              let focused = focusedObj else { return .unknown }
        let element = focused as! AXUIElement

        return kind(role: copyStringAttribute(element, kAXRoleAttribute),
                    subrole: copyStringAttribute(element, kAXSubroleAttribute))
    }

    /// Copies a string-valued AX attribute, returning nil if it's absent or not a
    /// string (subrole in particular is optional on many elements).
    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var valueObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueObj) == .success else {
            return nil
        }
        return valueObj as? String
    }

    /// Collapses text to a single clean line for a single-line/search field:
    /// newlines become spaces, runs of whitespace collapse to one space, and the
    /// result is trimmed. Pure and idempotent so it's unit-testable and safe to
    /// re-apply.
    static func collapseToSingleLine(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
