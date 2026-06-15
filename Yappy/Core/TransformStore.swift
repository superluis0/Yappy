//
//  TransformStore.swift
//  Yappy
//

import Foundation
import Combine

/// A named AI rewrite applied to selected text: the user's instruction (prompt)
/// plus a display name. Two built-ins ship by default; users can add their own.
struct Transform: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    var enabled: Bool
    /// True for the seeded built-in transforms (Polish, Prompt Engineer).
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, prompt: String, enabled: Bool = true, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey { case id, name, prompt, enabled, isBuiltIn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }
}

/// Local, on-disk store of transforms. Persists as JSON in Application Support.
/// Seeds the built-in transforms once, the same way DictionaryStore seeds its
/// starter terms — so a user can delete a built-in without it returning.
final class TransformStore: ObservableObject {
    @Published private(set) var transforms: [Transform] = []

    /// Enabled transforms, for the menu and auto-after-dictation lookups.
    var enabledTransforms: [Transform] { transforms.filter(\.enabled) }

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.yappy.transformstore", qos: .utility)
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static let seededKey = "com.yappy.transformsSeeded"

    /// The starter transforms, mirroring WisprFlow's defaults.
    static let builtIns: [Transform] = [
        Transform(
            name: "Polish",
            prompt: "Rewrite the text to be clear and concise. Fix grammar, spelling, "
                + "and awkward phrasing while keeping the original meaning and voice. "
                + "Do not add new information.",
            isBuiltIn: true
        ),
        Transform(
            name: "Prompt Engineer",
            prompt: "Restructure the text into a clear, well-organized prompt for an AI "
                + "assistant: state the goal up front, include the relevant context, and "
                + "specify the desired output format. Keep all the user's intent.",
            isBuiltIn: true
        ),
    ]

    /// - Parameters:
    ///   - fileURL: Override for tests; defaults to Application Support/Yappy/transforms.json.
    ///   - defaults: UserDefaults for the one-time seed flag (override in tests).
    ///   - seedsBuiltIns: Seed the built-in transforms on first run.
    init(fileURL: URL? = nil, defaults: UserDefaults = .standard, seedsBuiltIns: Bool = true) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Yappy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("transforms.json")
        }
        loadFromDisk()
        if seedsBuiltIns { seedBuiltInsIfNeeded(defaults: defaults) }
    }

    // MARK: - Mutations

    func add(_ transform: Transform) {
        transforms.append(transform)
        persist()
    }

    func update(_ transform: Transform) {
        guard let index = transforms.firstIndex(where: { $0.id == transform.id }) else { return }
        transforms[index] = transform
        persist()
    }

    func delete(_ transform: Transform) {
        transforms.removeAll { $0.id == transform.id }
        persist()
    }

    // MARK: - Seeding

    private func seedBuiltInsIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)

        let existing = Set(transforms.map { $0.name.lowercased() })
        let newcomers = Self.builtIns.filter { !existing.contains($0.name.lowercased()) }
        guard !newcomers.isEmpty else { return }
        transforms.append(contentsOf: newcomers)
        persist()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? Self.decoder.decode([Transform].self, from: data) else {
            return
        }
        transforms = loaded
    }

    private func persist() {
        let snapshot = transforms
        let url = fileURL
        ioQueue.async {
            guard let data = try? Self.encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
