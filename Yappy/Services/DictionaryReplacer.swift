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
    /// A compiled whole-word rule: the alias matcher plus the canonical-spelling
    /// replacement template.
    private let rules: [(regex: NSRegularExpression, template: String)]

    init(terms: [DictionaryTerm]) {
        // Compile each alias's regex ONCE here (longest alias first, so a
        // multi-word alias wins over a shorter overlapping one). `apply` then just
        // runs the precompiled matchers — building a fresh DictionaryReplacer per
        // dictation no longer recompiles every pattern.
        rules = terms
            .flatMap { term in term.allAliases.map { (alias: $0, replacement: term.text) } }
            .sorted { $0.alias.count > $1.alias.count }
            .compactMap { rule -> (regex: NSRegularExpression, template: String)? in
                let trimmed = rule.alias.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                let pattern = "(?<![\\w])\(NSRegularExpression.escapedPattern(for: trimmed))(?![\\w])"
                let regex: NSRegularExpression
                do {
                    regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                } catch {
                    VLog.app("a dictionary replacement pattern failed to compile")
                    return nil
                }
                return (regex, NSRegularExpression.escapedTemplate(for: rule.replacement))
            }
    }

    func apply(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }
}
