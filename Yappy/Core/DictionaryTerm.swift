//
//  DictionaryTerm.swift
//  Yappy
//

import Foundation

/// A custom-dictionary entry: the canonical spelling plus the alternative
/// spellings the speech model tends to produce for it. `aliases` are entered by
/// hand ("sounds like"); `learnedAliases` are mined from voice-training takes.
/// Both feed FluidAudio's vocabulary rescorer so a mishearing snaps back to `text`.
struct DictionaryTerm: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var aliases: [String]
    var learnedAliases: [String]

    init(id: UUID = UUID(), text: String, aliases: [String] = [], learnedAliases: [String] = []) {
        self.id = id
        self.text = text
        self.aliases = aliases
        self.learnedAliases = learnedAliases
    }

    private enum CodingKeys: String, CodingKey { case id, text, aliases, learnedAliases }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        learnedAliases = try c.decodeIfPresent([String].self, forKey: .learnedAliases) ?? []
    }

    /// Manual + learned aliases, trimmed and de-duplicated case-insensitively
    /// (manual first), excluding any that equal `text`. This is what's handed to
    /// the rescorer.
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
