//
//  DictionaryStore.swift
//  Yappy
//

import Foundation
import Combine

/// Local store of custom-dictionary terms (names, jargon, acronyms) used to
/// bias transcription. Persists as JSON in Application Support.
final class DictionaryStore: ObservableObject {
    @Published private(set) var terms: [String] = []

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.yappy.dictionarystore", qos: .utility)

    /// - Parameter fileURL: Override for tests; defaults to Application Support/Yappy/dictionary.json.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Yappy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("dictionary.json")
        }
        loadFromDisk()
    }

    // MARK: - Mutations

    func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return
        }
        terms.append(trimmed)
        persist()
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        persist()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        terms = loaded
    }

    private func persist() {
        let snapshot = terms
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
