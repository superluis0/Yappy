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

/// The register a cleaned transcript is shaped into. Applied as a DETERMINISTIC
/// post-cleanup transform (see `apply(to:)`), NOT as a model-prompt hint — on-device
/// runs showed prompt-level tone hints broke intent-safety, so tone is enforced by
/// pure text rules after the model's cleanup instead.
///
/// `Codable` is customized to survive the removal of the legacy `.excited` case:
/// any persisted `"excited"` (in modes.json or per-app tone overrides) decodes to
/// `.casual` — excited was informal-leaning and did nothing distinct, so `.casual`
/// is the closest surviving behavior — rather than throwing and corrupting the load.
enum ToneStyle: String, CaseIterable, Codable {
    case verbatim   // minimal cleanup, preserve as-is (good for code)
    case formal
    case casual

    var displayName: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .formal: return "Formal"
        case .casual: return "Casual"
        }
    }

    /// Legacy raw value → surviving case. Keeps decoding of persisted data that
    /// predates a case removal non-throwing. Currently maps the removed `"excited"`
    /// to `.casual`.
    private static let legacyRawValues: [String: ToneStyle] = [
        "excited": .casual,
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let known = ToneStyle(rawValue: raw) {
            self = known
        } else if let migrated = ToneStyle.legacyRawValues[raw] {
            self = migrated
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown ToneStyle raw value \"\(raw)\"")
        }
    }

    // MARK: - Deterministic tone transform

    /// Shapes `text` for this register. Pure and self-contained (no FoundationModels
    /// dependency) so it compiles everywhere and is unit-testable; applied by the
    /// cleanup coordinator to the final cleaned string.
    ///
    /// - `.verbatim` and `.formal`/`.casual` all pass through UNCHANGED when they
    ///   have no rule to apply. `.verbatim` never transforms (it also skips cleanup
    ///   upstream); `.formal` expands whitelisted contractions and ensures terminal
    ///   punctuation; `.casual` drops a trailing period on a short single sentence.
    func apply(to text: String) -> String {
        switch self {
        case .verbatim: return text
        case .formal: return ToneStyle.formalize(text)
        case .casual: return ToneStyle.casualize(text)
        }
    }

    /// Strip the trailing period from a short, single-sentence, single-line
    /// utterance. Conservative by design: any ambiguity (internal punctuation,
    /// multi-line, long, ends in ?/!) leaves the text untouched. Behavior was
    /// validated empirically against the on-device model before shipping.
    static func casualize(_ text: String) -> String {
        // Single line only.
        guard !text.contains("\n") else { return text }

        // Must end with "." (never touch "?"/"!" or anything else).
        guard text.hasSuffix(".") else { return text }

        // Exactly one sentence: no sentence-terminator anywhere but the final ".".
        // Examine every character except the last; if any is ./!/?, bail. This also
        // rejects decimals ("2.4.") and abbreviations ("e.g. do it.") — the internal
        // "." disqualifies them, which is the safe direction.
        let withoutLast = text.dropLast()
        if withoutLast.contains(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            return text
        }

        // <= 12 words (whitespace-delimited, non-empty tokens).
        let wordCount = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).count
        guard wordCount <= 12 else { return text }

        // All predicates hold: drop the single trailing period.
        return String(text.dropLast())
    }

    /// The contraction whitelist, lowercased key -> expansion. Only UNAMBIGUOUS
    /// forms: every 's here resolves to "is" (never possessive/has) and no 'd
    /// appears. "let's" -> "let us" is the one non-"is" 's. "can't"/"won't" have
    /// irregular expansions; "cannot" is deliberately absent (left as-is).
    private static let contractionExpansions: [String: String] = [
        "don't": "do not",
        "doesn't": "does not",
        "didn't": "did not",
        "can't": "cannot",
        "won't": "will not",
        "isn't": "is not",
        "aren't": "are not",
        "wasn't": "was not",
        "weren't": "were not",
        "couldn't": "could not",
        "shouldn't": "should not",
        "wouldn't": "would not",
        "haven't": "have not",
        "hasn't": "has not",
        "hadn't": "had not",
        "i'm": "I am",
        "i've": "I have",
        "i'll": "I will",
        "we're": "we are",
        "we've": "we have",
        "we'll": "we will",
        "they're": "they are",
        "they've": "they have",
        "they'll": "they will",
        "you're": "you are",
        "you've": "you have",
        "you'll": "you will",
        "it's": "it is",
        "that's": "that is",
        "there's": "there is",
        "what's": "what is",
        "who's": "who is",
        "let's": "let us",
    ]

    /// Apply the case of `source`'s first letter to `expansion`. The whitelist stores
    /// each expansion in its NATURAL sentence-internal case ("do not", "cannot", and
    /// crucially "I am"/"I have"/"I will" with a capital I because the pronoun is
    /// always capitalized). Rule:
    ///   * source starts uppercase -> uppercase the expansion's first char
    ///     ("Don't" -> "Do not", "I'm" -> "I am").
    ///   * source starts lowercase -> KEEP the stored case ("don't" -> "do not",
    ///     "i'm" -> "I am" — never lowercase a leading pronoun "I").
    /// Only-uppercasing (never force-lowercasing) is what preserves the always-cap
    /// "I" while still respecting an uppercase source word.
    private static func matchLeadingCase(of source: Substring, to expansion: String) -> String {
        guard let sourceFirst = source.first, let expansionFirst = expansion.first else {
            return expansion
        }
        if sourceFirst.isUppercase {
            return String(expansionFirst).uppercased() + expansion.dropFirst()
        }
        return expansion
    }

    /// A word character for tokenization: letters, digits, and the ASCII/typographic
    /// apostrophes that appear inside contractions. Splitting on the complement keeps
    /// punctuation and whitespace as separators, so "Don't." tokenizes to the word
    /// "Don't" plus the trailing ".".
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return scalar == "'" || scalar == "\u{2019}"  // ' and ’
    }

    /// Expand whitelisted contractions, then ensure terminal punctuation. Walks the
    /// string token by token, treating a run of word characters as one word and
    /// everything else as verbatim separators. Each word is looked up by its
    /// lowercased, apostrophe-normalized form; a hit is replaced case-preserved, a
    /// miss is left exactly as written. This never touches non-whitelisted words
    /// (gonna, she's, I'd) and preserves all spacing/punctuation between words.
    /// Ported verbatim from the Phase-A reference.
    static func formalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count + 8)

        var currentWord = ""

        func flushWord() {
            guard !currentWord.isEmpty else { return }
            // Normalize the typographic apostrophe to ASCII for the lookup key.
            let key = currentWord.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if let expansion = contractionExpansions[key] {
                result += matchLeadingCase(of: currentWord[...], to: expansion)
            } else {
                result += currentWord
            }
            currentWord = ""
        }

        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                currentWord.unicodeScalars.append(scalar)
            } else {
                flushWord()
                result.unicodeScalars.append(scalar)
            }
        }
        flushWord()

        return ensureTerminalPunctuation(result)
    }

    /// Append "." iff the (trailing-whitespace-trimmed) text ends with a letter or
    /// digit. Text ending in ?/!/./:/) etc. is left alone. Empty stays empty.
    private static func ensureTerminalPunctuation(_ text: String) -> String {
        // Only trailing whitespace is significant for the terminal check; preserve the
        // text otherwise. Trim the tail, inspect, then re-attach nothing (a dictated
        // line shouldn't carry trailing spaces post-cleanup anyway).
        let trimmed = text.replacingOccurrences(
            of: "[ \t]+$", with: "", options: .regularExpression)
        guard let last = trimmed.last else { return trimmed }
        if last.isLetter || last.isNumber {
            return trimmed + "."
        }
        return trimmed
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
    case secure       // AXSecureTextField — a password / secret field
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
        // Secure wins over everything: a password field must never be treated as a normal
        // single-line input (it has to skip AI cleanup and history). macOS is inconsistent
        // about where "secure" shows up, so check both role and subrole for the marker.
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return .secure }
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

        // One AX round-trip for role + subrole instead of two. A missing attribute comes
        // back as a non-String entry (a wrapped error / null), which `as? String` maps to
        // nil — exactly the "absent subrole" case the classifier already tolerates.
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute] as CFArray
        var valuesObj: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
                element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesObj) == .success,
              let values = valuesObj as? [AnyObject], values.count == 2 else {
            return .unknown
        }
        return kind(role: values[0] as? String, subrole: values[1] as? String)
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
