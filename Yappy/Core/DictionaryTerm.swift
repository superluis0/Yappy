//
//  DictionaryTerm.swift
//  Yappy
//

import Foundation

/// A custom-dictionary entry: the canonical spelling plus the alternative
/// spellings the speech model tends to produce for it. `aliases` are entered by
/// hand ("sounds like"); `learnedAliases` are mined from voice-training takes.
/// `DictionaryReplacer` rewrites either kind of mishearing back to `text` after
/// transcription; with "Boost my terms in the speech model" enabled the same
/// terms also bias recognition itself (Parakeet/English only).
struct DictionaryTerm: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var aliases: [String]
    var learnedAliases: [String]
    /// True for terms seeded from the built-in starter dictionary (dev/tech
    /// jargon). Lets the UI flag them and the seeder avoid re-adding them.
    var isBuiltIn: Bool

    init(id: UUID = UUID(), text: String, aliases: [String] = [],
         learnedAliases: [String] = [], isBuiltIn: Bool = false) {
        self.id = id
        self.text = text
        self.aliases = aliases
        self.learnedAliases = learnedAliases
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey { case id, text, aliases, learnedAliases, isBuiltIn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        learnedAliases = try c.decodeIfPresent([String].self, forKey: .learnedAliases) ?? []
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// Manual + learned aliases, trimmed and de-duplicated case-insensitively
    /// (manual first), excluding any that equal `text`. These are the strings
    /// `DictionaryReplacer` rewrites back to `text`.
    var allAliases: [String] {
        var seen: Set<String> = [text.lowercased()]
        var result: [String] = []
        for alias in aliases + learnedAliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }
}
