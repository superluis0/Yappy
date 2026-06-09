//
//  ShortcutStore.swift
//  Yappy
//

import Foundation
import Combine

/// A spoken-cue → expansion pair (e.g. say "my email" → full signature).
struct VoiceShortcut: Identifiable, Codable, Equatable {
    let id: UUID
    var trigger: String
    var expansion: String
    var enabled: Bool

    init(id: UUID = UUID(), trigger: String, expansion: String, enabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.enabled = enabled
    }
}

/// Local, on-disk store of voice shortcuts. Persists as JSON in Application Support.
final class ShortcutStore: ObservableObject {
    @Published private(set) var shortcuts: [VoiceShortcut] = []

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.yappy.shortcutstore", qos: .utility)

    /// - Parameter fileURL: Override for tests; defaults to Application Support/Yappy/shortcuts.json.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Yappy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("shortcuts.json")
        }
        loadFromDisk()
    }

    // MARK: - Mutations

    func add(_ shortcut: VoiceShortcut) {
        shortcuts.append(shortcut)
        persist()
    }

    func update(_ shortcut: VoiceShortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index] = shortcut
        persist()
    }

    func delete(_ shortcut: VoiceShortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        persist()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([VoiceShortcut].self, from: data) else {
            return
        }
        shortcuts = loaded
    }

    private func persist() {
        let snapshot = shortcuts
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
