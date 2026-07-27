//
//  AskRuntimeStorage.swift
//  Yappy
//

import Foundation

/// Deletes backend runtime artifacts that can contain question/answer text.
/// Callers own process lifecycle — purge only after backend processes exited.
enum AskRuntimeStorage {
    /// Relative paths under the backend home slated for deletion.
    static func purgeManifest(for backend: AskBackend) -> [String] {
        switch backend {
        case .codex:
            [
                "logs_2.sqlite",
                "logs_2.sqlite-wal",
                "logs_2.sqlite-shm",
                "state_5.sqlite",
                "state_5.sqlite-wal",
                "state_5.sqlite-shm",
                "sessions",
                "goals_1.sqlite",
                "goals_1.sqlite-wal",
                "goals_1.sqlite-shm",
                "memories_1.sqlite",
                "memories_1.sqlite-wal",
                "memories_1.sqlite-shm"
            ]
        case .grok:
            [
                ".grok/sessions",
                ".grok/active_sessions.json",
                ".grok/active_sessions.lock",
                ".grok/logs"
            ]
        }
    }

    /// Deletes manifest paths under `home`. Missing paths tolerated.
    /// Returns bytes reclaimed. Logs ONE VLog.store line (byte count only).
    @discardableResult
    static func purge(_ backend: AskBackend, home: URL) -> Int64 {
        let fileManager = FileManager.default
        var reclaimed: Int64 = 0

        for relativePath in purgeManifest(for: backend) {
            let artifact = home.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: artifact.path) else { continue }

            let byteCount = sizeOfArtifact(at: artifact, fileManager: fileManager)
            do {
                try fileManager.removeItem(at: artifact)
                reclaimed += byteCount
            } catch {
                continue
            }
        }

        VLog.store("runtime purge backend=\(backend.rawValue) reclaimed=\(reclaimed)")
        return reclaimed
    }

    /// Convenience over the real homes (resolved via client accessors).
    @discardableResult
    static func purgeAll() -> Int64 {
        var reclaimed = purge(.codex, home: CodexAskClient.homeURL)
        if let grokHome = try? GrokAskClient.grokHomeURL() {
            reclaimed += purge(.grok, home: grokHome)
        }
        reclaimed += purgeSpokenAnswers()
        return reclaimed
    }

    /// Deletes the synthesized speech of read-aloud answers.
    /// `TTSSpeakClient` writes `answer-N.wav` here and only clears the folder
    /// in its own `init()` — i.e. at the NEXT launch — so without this the
    /// audio of an answer outlives both quit and "clear". Callers stop speech
    /// before purging (`dismiss()` → `stopSpeaking()`, and quit tears the
    /// helper down), so no file is deleted mid-playback; NSSound has already
    /// read the data it is playing regardless.
    @discardableResult
    static func purgeSpokenAnswers() -> Int64 {
        let fileManager = FileManager.default
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return 0 }
        let directory = support
            .appendingPathComponent("Yappy", isDirectory: true)
            .appendingPathComponent("tts", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: []
        ) else { return 0 }

        var reclaimed: Int64 = 0
        for url in contents {
            reclaimed += sizeOfArtifact(at: url, fileManager: fileManager)
            try? fileManager.removeItem(at: url)
        }
        if reclaimed > 0 {
            VLog.store("runtime purge spoken-answers reclaimed=\(reclaimed)")
        }
        return reclaimed
    }

    /// Synchronous launch sweep = purgeAll(). Call BEFORE any backend prewarm.
    static func orphanSweepAtLaunch() {
        purgeAll()
    }

    private static func sizeOfArtifact(at url: URL, fileManager: FileManager) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return 0
        }
        guard values.isDirectory == true else {
            return Int64(values.fileSize ?? 0)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            guard let childValues = try? childURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), childValues.isRegularFile == true else {
                continue
            }
            total += Int64(childValues.fileSize ?? 0)
        }
        return total
    }
}
