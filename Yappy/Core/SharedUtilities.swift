//
//  SharedUtilities.swift
//  Yappy
//
//  Shared helpers used across multiple clients and formatters. Zero-behavior
//  de-duplication only — keep logic byte-identical to the prior local copies.
//

import Foundation

// MARK: - Model / research constants

/// Codex model ID used for Ask turns (config.toml, thread/start, turn/start, UI label).
enum CodexModel {
    static let id = "gpt-5.5"
}

/// Substrings that identify a Grok tool title as research-only (web / search / fetch).
let researchToolKeywords: Set<String> = ["web", "search", "fetch"]

// MARK: - NSLock

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - String

extension String {
    /// Uppercases the first character; empty string is returned unchanged.
    func capitalizedFirstCharacter() -> String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}

// MARK: - Voice phrase normalization

enum SpokenPhraseNormalizer {
    /// Lowercased, fillers removed, edge punctuation stripped, whitespace collapsed.
    /// Shared by `VoiceControlCommand` and `VoiceEditCommand` parsers.
    static func normalize(_ raw: String) -> String {
        FillerWordRemover.remove(raw).lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
