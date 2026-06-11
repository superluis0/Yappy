//
//  DictionaryReplacer.swift
//  Yappy
//

import Foundation

/// Applies the custom dictionary as deterministic correction rules: a whole-word,
/// case-insensitive occurrence of any alias is rewritten to its term's canonical
/// spelling ("Lewis" → "Luis"). This is the reliable counterpart to acoustic
/// vocabulary boosting — it runs on the normal batch transcript and works on
/// clips of any length, including just saying a name.
struct DictionaryReplacer {
    private let rules: [(alias: String, replacement: String)]

    init(terms: [DictionaryTerm]) {
        // Longer aliases first, so a multi-word alias wins over any shorter
        // alias that overlaps part of it.
        rules = terms
            .flatMap { term in term.allAliases.map { (alias: $0, replacement: term.text) } }
            .sorted { $0.alias.count > $1.alias.count }
    }

    func apply(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = Self.replaceWholeWord(rule.alias, with: rule.replacement, in: result)
        }
        return result
    }

    /// Case-insensitive, whole-phrase replacement bounded by word edges (mirrors
    /// ShortcutExpander's phrase replacement).
    private static func replaceWholeWord(_ phrase: String, with replacement: String, in text: String) -> String {
        let trimmed = phrase.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let pattern = "(?<![\\w])\(escaped)(?![\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
