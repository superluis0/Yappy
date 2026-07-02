//
//  DictionaryStore.swift
//  Yappy
//

import Foundation
import Combine

/// A pending, user-facing suggestion that Yappy mistook `heard` for `corrected`
/// — mined from a "scratch that" + re-dictation, never applied automatically.
/// Accepting one turns `heard` into a learned alias of `corrected`; a wrong
/// alias silently applied would degrade accuracy, so the human stays in the loop.
struct AliasSuggestion: Codable, Identifiable, Equatable {
    let id: UUID
    let heard: String
    let corrected: String
    let createdAt: Date

    init(id: UUID = UUID(), heard: String, corrected: String, createdAt: Date = Date()) {
        self.id = id
        self.heard = heard
        self.corrected = corrected
        self.createdAt = createdAt
    }
}

/// Local store of custom-dictionary terms (names, jargon, acronyms) used to
/// correct transcription. Persists as JSON in Application Support. Each term may
/// carry alternative spellings (see `DictionaryTerm`) so a mishearing is
/// rewritten back to the canonical word after transcription (via `DictionaryReplacer`).
/// When the "Boost my terms in the speech model" setting is on (Parakeet/English),
/// these terms also bias recognition itself — the recognizer prefers them while
/// dictating — via FluidAudio's CTC custom-vocabulary rescoring (see
/// `ParakeetTranscriptionService.configureVocabularyBoosting`).
final class DictionaryStore: ObservableObject {
    @Published private(set) var terms: [DictionaryTerm] = []

    /// Pending "did you mean" alias suggestions, mined from the user's own
    /// corrections. Surfaced in the Dictionary view for one-tap accept — never
    /// applied on their own.
    @Published private(set) var suggestions: [AliasSuggestion] = []

    /// Just the canonical spellings — for callers that only need plain strings.
    var boostTerms: [String] { terms.map(\.text) }

    private let fileURL: URL
    /// Suggestions + dismissed keys live in their own file beside `dictionary.json`
    /// so the main file's legacy decode paths stay untouched.
    private let suggestionsURL: URL
    /// "heard|corrected" keys (lowercased) the user has dismissed, so the same
    /// mishearing isn't re-suggested forever. Bounded, oldest dropped first.
    private var dismissedKeys: [String] = []
    private static let maxSuggestions = 10
    private static let maxDismissedKeys = 100
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
        // Suggestions sit next to the terms file (derived from its directory),
        // so a temp fileURL in tests naturally routes its suggestions to temp too.
        self.suggestionsURL = self.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("dictionary-suggestions.json")
        loadFromDisk()
        loadSuggestionsFromDisk()
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

    // MARK: - Alias suggestions (learn-from-corrections)

    /// Files a mined (heard → corrected) pair as a pending suggestion, unless
    /// it's noise: an identical pending pair, an alias the matching term already
    /// knows, or a pair the user previously dismissed. All matching is
    /// case-insensitive. Caps pending suggestions, dropping the oldest.
    func addSuggestion(heard: String, corrected: String) {
        let heardTrimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTrimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heardTrimmed.isEmpty, !correctedTrimmed.isEmpty,
              heardTrimmed.caseInsensitiveCompare(correctedTrimmed) != .orderedSame else {
            return
        }

        // Already pending?
        guard !suggestions.contains(where: {
            $0.heard.caseInsensitiveCompare(heardTrimmed) == .orderedSame &&
            $0.corrected.caseInsensitiveCompare(correctedTrimmed) == .orderedSame
        }) else { return }

        // Already dismissed once — don't nag.
        guard !dismissedKeys.contains(Self.dismissKey(heard: heardTrimmed, corrected: correctedTrimmed)) else {
            return
        }

        // Already known: a term spelled `corrected` that already lists `heard`.
        let alreadyKnown = terms.contains { term in
            term.text.caseInsensitiveCompare(correctedTrimmed) == .orderedSame &&
            term.allAliases.contains { $0.caseInsensitiveCompare(heardTrimmed) == .orderedSame }
        }
        guard !alreadyKnown else { return }

        suggestions.append(AliasSuggestion(heard: heardTrimmed, corrected: correctedTrimmed))
        // Bound the list, dropping the oldest first (append order == age order).
        if suggestions.count > Self.maxSuggestions {
            suggestions.removeFirst(suggestions.count - Self.maxSuggestions)
        }
        persistSuggestions()
    }

    /// Accepts a suggestion: `heard` becomes a learned alias of the term spelled
    /// `corrected` (created if it doesn't exist yet), then the suggestion is
    /// removed. This is the only path from a suggestion into the alias machinery.
    func acceptSuggestion(_ suggestion: AliasSuggestion) {
        if let existing = terms.first(where: { $0.text.caseInsensitiveCompare(suggestion.corrected) == .orderedSame }) {
            addLearnedAliases([suggestion.heard], to: existing)
        } else {
            var term = DictionaryTerm(text: suggestion.corrected)
            term.learnedAliases = [suggestion.heard]
            terms.append(term)
            persist()
        }
        suggestions.removeAll { $0.id == suggestion.id }
        persistSuggestions()
    }

    /// Dismisses a suggestion and remembers the pair so the same mishearing isn't
    /// re-suggested. The dismissed-key list is bounded (oldest dropped).
    func dismissSuggestion(_ suggestion: AliasSuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }

        let key = Self.dismissKey(heard: suggestion.heard, corrected: suggestion.corrected)
        if !dismissedKeys.contains(key) {
            dismissedKeys.append(key)
            if dismissedKeys.count > Self.maxDismissedKeys {
                dismissedKeys.removeFirst(dismissedKeys.count - Self.maxDismissedKeys)
            }
        }
        persistSuggestions()
    }

    private static func dismissKey(heard: String, corrected: String) -> String {
        "\(heard.lowercased())|\(corrected.lowercased())"
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

    /// On-disk shape for suggestions: pending list + dismissed keys in one file.
    /// Separate from `dictionary.json` so the terms file format never changes.
    private struct SuggestionsEnvelope: Codable {
        var suggestions: [AliasSuggestion]
        var dismissedKeys: [String]
    }

    private func loadSuggestionsFromDisk() {
        guard let data = try? Data(contentsOf: suggestionsURL),
              let envelope = try? Self.decoder.decode(SuggestionsEnvelope.self, from: data) else {
            return
        }
        suggestions = envelope.suggestions
        dismissedKeys = envelope.dismissedKeys
    }

    private func persistSuggestions() {
        let envelope = SuggestionsEnvelope(suggestions: suggestions, dismissedKeys: dismissedKeys)
        let url = suggestionsURL
        ioQueue.async {
            guard let data = try? Self.encoder.encode(envelope) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
