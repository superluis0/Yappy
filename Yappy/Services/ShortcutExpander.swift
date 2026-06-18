//
//  ShortcutExpander.swift
//  Yappy
//

import Foundation

/// Expands spoken cues into canned text. Two modes:
/// - Whole-utterance: if the entire transcript is just the trigger, replace it
///   wholesale (so "my email." → the signature, punctuation and all).
/// - Inline: otherwise, replace trigger phrases found inside a longer transcript.
struct ShortcutExpander {
    private let shortcuts: [VoiceShortcut]

    init(shortcuts: [VoiceShortcut]) {
        self.shortcuts = shortcuts.filter { $0.enabled && !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The expansion when the entire transcript is just a trigger (so the caller
    /// can insert it verbatim — no cleanup, no leading space). Nil otherwise.
    func wholeUtteranceExpansion(for text: String) -> String? {
        guard !shortcuts.isEmpty else { return nil }
        let normalizedInput = Self.normalize(text)
        return shortcuts.first(where: { Self.normalize($0.trigger) == normalizedInput })?.expansion
    }

    func expand(_ text: String) -> String {
        guard !shortcuts.isEmpty else { return text }

        // Whole-utterance match wins and replaces everything.
        if let whole = wholeUtteranceExpansion(for: text) {
            return whole
        }

        // Inline: replace each trigger phrase where it appears as a whole phrase.
        var result = text
        for shortcut in shortcuts {
            result = Self.replacePhrase(shortcut.trigger, with: shortcut.expansion, in: result)
        }
        return result
    }

    // MARK: - Helpers

    /// Lowercased, trimmed, trailing sentence punctuation removed.
    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
    }

    /// Case-insensitive, whole-phrase replacement bounded by word edges.
    private static func replacePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespaces)
        guard !trimmedPhrase.isEmpty else { return text }

        let escaped = NSRegularExpression.escapedPattern(for: trimmedPhrase)
        let pattern = "(?<![\\w])\(escaped)(?![\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
