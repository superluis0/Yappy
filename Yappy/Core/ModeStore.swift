//
//  ModeStore.swift
//  Yappy
//

import Foundation
import Combine

/// Local, on-disk store of dictation modes. Always contains the built-in Auto
/// mode (which can't be deleted). Persists as JSON in Application Support.
final class ModeStore: ObservableObject {
    @Published private(set) var modes: [Mode] = []

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.yappy.modestore", qos: .utility)
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// - Parameter fileURL: Override for tests; defaults to Application Support/Yappy/modes.json.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Yappy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("modes.json")
        }
        loadFromDisk()
        ensureAuto()
    }

    // MARK: - Mutations

    func add(_ mode: Mode) {
        guard !mode.isAuto else { return }
        modes.append(mode)
        persist()
    }

    func update(_ mode: Mode) {
        guard !mode.isAuto, let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index] = mode
        persist()
    }

    func delete(_ mode: Mode) {
        guard !mode.isAuto else { return }
        modes.removeAll { $0.id == mode.id }
        persist()
    }

    // MARK: - Persistence

    /// Guarantees the Auto mode is always present and first.
    private func ensureAuto() {
        if !modes.contains(where: { $0.isAuto }) {
            modes.insert(.auto, at: 0)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else {
            modes = [.auto]
            return
        }
        do {
            modes = try Self.decoder.decode([Mode].self, from: data)
        } catch {
            VLog.store("failed to decode ModeStore (\(data.count) bytes): \(error.localizedDescription)")
            modes = [.auto]
        }
    }

    private func persist() {
        let snapshot = modes
        let url = fileURL
        ioQueue.async {
            do {
                let data = try Self.encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                VLog.store("failed to write ModeStore: \(error.localizedDescription)")
            }
        }
    }
}
