//
//  DictionaryStore.swift
//  Yappy
//

import Foundation
import Combine

/// Local store of custom-dictionary terms (names, jargon, acronyms) used to
/// bias transcription. Persists as JSON in Application Support. Each term may
/// carry alternative spellings (see `DictionaryTerm`) so a mishearing is
/// rescored back to the canonical word.
final class DictionaryStore: ObservableObject {
    @Published private(set) var terms: [DictionaryTerm] = []

    /// Just the canonical spellings — for callers that only need plain strings.
    var boostTerms: [String] { terms.map(\.text) }

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.yappy.dictionarystore", qos: .utility)
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// One-time flag so the built-in starter terms seed exactly once — letting a
    /// user delete a built-in term without it reappearing on the next launch.
    private static let seededKey = "com.yappy.dictionarySeeded"

    /// - Parameters:
    ///   - fileURL: Override for tests; defaults to Application Support/Yappy/dictionary.json.
    ///   - defaults: UserDefaults used for the one-time seed flag (override in tests).
    ///   - seedsBuiltIns: Seed the developer/tech starter dictionary on first run.
    init(fileURL: URL? = nil, defaults: UserDefaults = .standard, seedsBuiltIns: Bool = true) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Yappy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("dictionary.json")
        }
        loadFromDisk()
        if seedsBuiltIns { seedBuiltInsIfNeeded(defaults: defaults) }
    }

    /// Appends any built-in terms the user doesn't already have, exactly once.
    /// The flag is set even when nothing is added, so deletions stick.
    private func seedBuiltInsIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)

        let existing = Set(terms.map { $0.text.lowercased() })
        let newcomers = BuiltInDictionary.terms.filter { !existing.contains($0.text.lowercased()) }
        guard !newcomers.isEmpty else { return }
        terms.append(contentsOf: newcomers)
        persist()
    }

    // MARK: - Mutations

    func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !terms.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return
        }
        terms.append(DictionaryTerm(text: trimmed))
        persist()
    }

    func remove(_ term: DictionaryTerm) {
        terms.removeAll { $0.id == term.id }
        persist()
    }

    /// Removes by canonical spelling (case-insensitive). Convenience for callers
    /// that don't hold the struct.
    func remove(text: String) {
        terms.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame }
        persist()
    }

    func update(_ term: DictionaryTerm) {
        guard let idx = terms.firstIndex(where: { $0.id == term.id }) else { return }
        terms[idx] = term
        persist()
    }

    /// Replaces the manual "sounds like" aliases for a term.
    func setAliases(_ aliases: [String], for term: DictionaryTerm) {
        guard let idx = terms.firstIndex(where: { $0.id == term.id }) else { return }
        terms[idx].aliases = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        persist()
    }

    /// Appends voice-mined aliases, de-duplicated case-insensitively against the
    /// term's existing learned aliases.
    func addLearnedAliases(_ aliases: [String], to term: DictionaryTerm) {
        guard let idx = terms.firstIndex(where: { $0.id == term.id }) else { return }
        var combined = terms[idx].learnedAliases
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !combined.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                continue
            }
            combined.append(trimmed)
        }
        terms[idx].learnedAliases = combined
        persist()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }

        // Current format: an array of DictionaryTerm objects.
        if let modern = try? Self.decoder.decode([DictionaryTerm].self, from: data) {
            terms = modern
            return
        }
        // Legacy format: a bare array of strings. Migrate in place and rewrite
        // once so the file is upgraded. A failed decode leaves `terms` empty
        // rather than wiping a good file — but we only reach here if the modern
        // decode already failed, so the data is genuinely the old shape.
        if let legacy = try? Self.decoder.decode([String].self, from: data) {
            terms = legacy.map { DictionaryTerm(text: $0) }
            persist()
        }
    }

    private func persist() {
        let snapshot = terms
        let url = fileURL
        ioQueue.async {
            guard let data = try? Self.encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
