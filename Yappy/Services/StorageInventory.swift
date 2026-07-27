//
//  StorageInventory.swift
//  Yappy
//

import Foundation

/// One user-visible line in the Privacy → "Storage on this Mac" diagnostic.
struct StorageItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let bytes: Int64

    var isEmpty: Bool { bytes == 0 }
}

struct StorageLocation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let url: URL
}

enum StorageInventory {
    /// Every persistent location in the privacy diagnostic, in display order.
    ///
    /// Path construction is deliberately side-effect-free. In particular, this
    /// does not call the Answers home accessors because the Grok accessor creates
    /// its directory. The appended paths mirror those accessors exactly.
    static var locations: [StorageLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let yappySupport = applicationSupport.appendingPathComponent("Yappy", isDirectory: true)

        return [
            StorageLocation(
                id: "models",
                title: "Speech models",
                detail: "Downloaded speech recognition models, shared with other FluidAudio apps.",
                url: applicationSupport
                    .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            ),
            StorageLocation(
                id: "dictation-history",
                title: "Dictation history",
                detail: "Transcripts saved for History, search, and personal insights.",
                url: yappySupport.appendingPathComponent("history.json")
            ),
            StorageLocation(
                id: "dictation-stats",
                title: "Dictation statistics",
                detail: "Lifetime word and dictation-time totals, without audio.",
                url: yappySupport.appendingPathComponent("history.stats.json")
            ),
            StorageLocation(
                id: "answer-history",
                title: "Answer history",
                detail: "Questions and completed Answers kept when answer history is enabled.",
                url: yappySupport.appendingPathComponent("ask-history.json")
            ),
            StorageLocation(
                id: "answers-codex",
                title: "Answers runtime — Codex",
                detail: "Private Codex configuration, credentials copy, caches, and temporary runtime state.",
                url: yappySupport.appendingPathComponent("CodexAskHome", isDirectory: true)
            ),
            StorageLocation(
                id: "answers-grok",
                title: "Answers runtime — Grok",
                detail: "Private Grok configuration, credentials copy, caches, and temporary runtime state.",
                url: yappySupport.appendingPathComponent("GrokHome", isDirectory: true)
            ),
            StorageLocation(
                id: "tts-voices",
                title: "Text-to-speech voices",
                detail: "The local Kokoro model and voices used to read Answers aloud.",
                url: home
                    .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
                    .appendingPathComponent(
                        "models--mlx-community--Kokoro-82M-8bit",
                        isDirectory: true
                    )
            ),
            // The ONLY audio Yappy writes to disk. Your voice is never recorded
            // to a file — this is the synthesized speech of answers read aloud
            // (TTSSpeakClient writes answer-N.wav here, owner-only). Listed
            // explicitly so the audio claim is verifiable, not just asserted.
            StorageLocation(
                id: "spoken-answers",
                title: "Spoken answers (audio)",
                detail: "Synthesized speech of answers read aloud. Cleared when Yappy restarts or you clear Answers data.",
                url: yappySupport.appendingPathComponent("tts", isDirectory: true)
            ),
            StorageLocation(
                id: "diagnostic-log",
                title: "Diagnostic log",
                detail: "Timings and state for troubleshooting, rewritten each launch. Holds no transcripts.",
                url: home.appendingPathComponent("Library/Logs/Yappy", isDirectory: true)
            ),
            StorageLocation(
                id: "notes",
                title: "Scratchpad notes",
                detail: "Notes saved from the local Scratchpad.",
                url: yappySupport.appendingPathComponent("notes.json")
            ),
            StorageLocation(
                id: "dictionary",
                title: "Custom dictionary",
                detail: "Terms and pronunciations used to improve local transcription.",
                url: yappySupport.appendingPathComponent("dictionary.json")
            ),
            StorageLocation(
                id: "dictionary-suggestions",
                title: "Dictionary suggestions",
                detail: "Local correction suggestions and dismissed suggestion keys.",
                url: yappySupport.appendingPathComponent("dictionary-suggestions.json")
            ),
            StorageLocation(
                id: "modes",
                title: "Modes",
                detail: "Your saved dictation modes and their cleanup preferences.",
                url: yappySupport.appendingPathComponent("modes.json")
            ),
            StorageLocation(
                id: "shortcuts",
                title: "Voice shortcuts",
                detail: "Spoken shortcut triggers and their saved expansions.",
                url: yappySupport.appendingPathComponent("shortcuts.json")
            ),
        ]
    }

    /// Sizes every location at utility priority and resumes on the main actor.
    /// Missing or unreadable paths are represented by zero-byte items.
    @MainActor
    static func measure() async -> [StorageItem] {
        await measure(locations: locations)
    }

    /// Injectable location list keeps the filesystem walk independently testable.
    @MainActor
    static func measure(locations: [StorageLocation]) async -> [StorageItem] {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager()
            return locations.map { location in
                StorageItem(
                    id: location.id,
                    title: location.title,
                    detail: location.detail,
                    bytes: allocatedSize(of: location.url, fileManager: fileManager)
                )
            }
        }.value
    }

    /// Formats a positive byte count for display, for example "1.2 GB".
    static func formatted(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 bytes" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// Counts regular files only. Symbolic links are never followed or counted,
    /// which prevents a link inside a measured tree from pulling in outside data.
    private static func allocatedSize(of url: URL, fileManager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
        ]

        guard let rootValues = try? url.resourceValues(forKeys: keys),
              rootValues.isSymbolicLink != true else {
            return 0
        }

        if rootValues.isRegularFile == true {
            return byteCount(from: rootValues)
        }

        guard rootValues.isDirectory == true,
              let enumerator = fileManager.enumerator(
                  at: url,
                  includingPropertiesForKeys: Array(keys),
                  options: [],
                  errorHandler: { _, _ in true }
              ) else {
            return 0
        }

        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            guard let values = try? childURL.resourceValues(forKeys: keys) else {
                continue
            }
            if values.isSymbolicLink == true {
                // Skip the entry only. Do NOT call skipDescendants() here: on a
                // symlink that suppresses descent into the level's remaining
                // subdirectories, silently under-counting sibling trees
                // (measured: a nested folder went uncounted entirely). The
                // enumerator never follows symlinked directories on its own, so
                // skipping the entry is enough to keep outside data out.
                continue
            }
            guard values.isRegularFile == true else { continue }

            let (sum, overflow) = total.addingReportingOverflow(byteCount(from: values))
            total = overflow ? Int64.max : sum
        }
        return total
    }

    private static func byteCount(from values: URLResourceValues) -> Int64 {
        Int64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
    }
}
