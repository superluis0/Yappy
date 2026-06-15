//
//  NotesStore.swift
//  Yappy
//

import Foundation
import Combine

/// A single Scratchpad note. The display title is derived from the first
/// non-empty line, so there's no separate title field to keep in sync.
struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var body: String
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), body: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First non-empty line, trimmed, or "New note" when empty.
    var displayTitle: String {
        let firstLine = body.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty ? "New note" : firstLine
    }
}

/// Local, on-disk store of Scratchpad notes, newest-updated first. Persists as
/// JSON in Application Support — no cloud, no accounts (matching the rest of the app).
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.yappy.notesstore", qos: .utility)

    /// - Parameter fileURL: Override for tests; defaults to Application Support/Yappy/notes.json.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Yappy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("notes.json")
        }
        loadFromDisk()
    }

    // MARK: - Mutations

    /// Creates a new empty note at the top and returns it.
    @discardableResult
    func create() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        persist()
        return note
    }

    /// Updates a note's body and bumps its modified time. Order is left stable
    /// (no live re-sort) so the sidebar doesn't jump around while typing.
    func update(_ note: Note, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].body = body
        notes[index].updatedAt = Date()
        persist()
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        persist()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([Note].self, from: data) else {
            return
        }
        notes = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        let snapshot = notes
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
