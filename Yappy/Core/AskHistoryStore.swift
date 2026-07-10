//
//  AskHistoryStore.swift
//  Yappy
//
//  Local history of completed Ask runs (question + answer), so an answer can
//  be re-read after the pill dismisses. Deliberately separate from the
//  dictation HistoryStore: different shape (Q&A pairs vs transcripts), and Ask
//  answers must never pollute dictation stats/streaks. Small capped JSON in
//  Application Support; personal-build feature, cleared with one click.
//

import Foundation

struct AskHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let question: String
    let answer: String
    /// Raw AskBackend value ("codex" / "grok") — stored as a string so the
    /// history file doesn't couple to the enum's future shape.
    let backend: String
    /// Friendly model name at ask time; nil for entries saved before this field existed.
    let modelLabel: String?
    /// Nil for entries saved before favorites existed.
    var favorite: Bool?

    var isFavorite: Bool { favorite ?? false }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        question: String,
        answer: String,
        backend: String,
        modelLabel: String? = nil,
        favorite: Bool? = nil
    ) {
        self.id = id
        self.date = date
        self.question = question
        self.answer = answer
        self.backend = backend
        self.modelLabel = modelLabel
        self.favorite = favorite
    }
}

@MainActor
final class AskHistoryStore: ObservableObject {
    @Published private(set) var entries: [AskHistoryEntry] = []

    internal static let maxEntries = 100
    private let maxEntries: Int
    private let fileURL: URL?
    private let ioQueue = DispatchQueue(label: "com.yappy.ask-history.io", qos: .utility)

    /// `directory` is injectable for tests; defaults to Application Support/Yappy.
    init(directory: URL? = nil, maxEntries: Int = AskHistoryStore.maxEntries) {
        self.maxEntries = maxEntries
        let base = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ))?.appendingPathComponent("Yappy", isDirectory: true)
        if let base {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
            fileURL = base.appendingPathComponent("ask-history.json")
        } else {
            fileURL = nil
        }
        load()
    }

    /// Records one completed Q&A, newest first, trimmed to the cap.
    func add(question: String, answer: String, backend: String, modelLabel: String? = nil) {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return }
        entries.insert(
            AskHistoryEntry(question: question, answer: trimmedAnswer, backend: backend, modelLabel: modelLabel),
            at: 0
        )
        trimToCap()
        save()
    }

    private func trimToCap() {
        while entries.count > maxEntries {
            if let index = entries.lastIndex(where: { !$0.isFavorite }) {
                entries.remove(at: index)
            } else {
                entries.removeLast()
            }
        }
    }

    func remove(_ entry: AskHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func toggleFavorite(_ entry: AskHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].favorite = !entries[index].isFavorite
        save()
    }

    func clear() {
        entries.removeAll()
        guard let fileURL else { return }
        let url = fileURL
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    var last: AskHistoryEntry? { entries.first }

    // MARK: - Persistence

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = try JSONDecoder().decode([AskHistoryEntry].self, from: data)
        } catch {
            VLog.store("failed to decode AskHistoryStore (\(data.count) bytes): \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = entries
        let url = fileURL
        ioQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                VLog.store("failed to write AskHistoryStore: \(error.localizedDescription)")
            }
        }
    }

    /// Test hook: drains pending I/O so on-disk state matches in-memory `entries`
    /// before tests re-instantiate the store on the same directory.
    func flushForTesting() {
        ioQueue.sync {}
    }
}
