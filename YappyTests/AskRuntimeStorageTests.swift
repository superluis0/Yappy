//
//  AskRuntimeStorageTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class AskRuntimeStorageTests: XCTestCase {
    private struct Fixture {
        let home: URL
        let markerPaths: [String]
        let survivorPaths: [String]
        let plantedMarkerBytes: Int64
        let survivorData: [String: Data]
    }

    func testManifestContentsMatchPrivacyContract() {
        XCTAssertEqual(
            AskRuntimeStorage.purgeManifest(for: .codex),
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
                "memories_1.sqlite-shm",
            ]
        )
        XCTAssertEqual(
            AskRuntimeStorage.purgeManifest(for: .grok),
            [
                ".grok/sessions",
                ".grok/active_sessions.json",
                ".grok/active_sessions.lock",
                ".grok/logs",
            ]
        )
    }

    func testPurgeDeletesEveryManifestPathAndPreservesSurvivors() throws {
        for backend in AskBackend.allCases {
            let fixture = try makeFixture(for: backend)
            defer { try? FileManager.default.removeItem(at: fixture.home) }

            for relativePath in fixture.markerPaths {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: fixture.home.appendingPathComponent(relativePath).path
                    ),
                    "Fixture marker was not planted: \(relativePath)"
                )
            }
            let reclaimed = AskRuntimeStorage.purge(backend, home: fixture.home)

            XCTAssertGreaterThan(reclaimed, 0, "\(backend.rawValue) should reclaim bytes")
            XCTAssertGreaterThanOrEqual(reclaimed, fixture.plantedMarkerBytes)
            for relativePath in AskRuntimeStorage.purgeManifest(for: backend) {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: fixture.home.appendingPathComponent(relativePath).path
                    ),
                    "Manifest artifact survived: \(relativePath)"
                )
            }
            for relativePath in fixture.survivorPaths {
                let survivorURL = fixture.home.appendingPathComponent(relativePath)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: survivorURL.path),
                    "Non-runtime file was deleted: \(relativePath)"
                )
                if let expectedData = fixture.survivorData[relativePath] {
                    let actualData = try Data(contentsOf: survivorURL)
                    XCTAssertEqual(
                        actualData, expectedData,
                        "Survivor file was modified: \(relativePath)"
                    )
                }
            }
        }
    }

    func testSecondPurgeIsIdempotent() throws {
        for backend in AskBackend.allCases {
            let fixture = try makeFixture(for: backend)
            defer { try? FileManager.default.removeItem(at: fixture.home) }

            XCTAssertGreaterThan(AskRuntimeStorage.purge(backend, home: fixture.home), 0)
            XCTAssertEqual(AskRuntimeStorage.purge(backend, home: fixture.home), 0)
        }
    }

    func testNonexistentHomeReturnsZero() {
        let nonexistentHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskRuntimeStorageTests-\(UUID().uuidString)", isDirectory: true)

        for backend in AskBackend.allCases {
            XCTAssertEqual(AskRuntimeStorage.purge(backend, home: nonexistentHome), 0)
        }
    }

    private func makeFixture(for backend: AskBackend) throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskRuntimeStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let markerPaths: [String]
        let survivorPaths: [String]
        switch backend {
        case .codex:
            markerPaths = [
                "logs_2.sqlite",
                "logs_2.sqlite-wal",
                "logs_2.sqlite-shm",
                "state_5.sqlite",
                "state_5.sqlite-wal",
                "state_5.sqlite-shm",
                "sessions/2026/07/23/rollout-x.jsonl",
                "goals_1.sqlite",
                "goals_1.sqlite-wal",
                "goals_1.sqlite-shm",
                "memories_1.sqlite",
                "memories_1.sqlite-wal",
                "memories_1.sqlite-shm",
            ]
            survivorPaths = [
                "auth.json",
                "config.toml",
                "bundled/asset.bin",
                "plugins/p.bin",
                "cache/c.json",
            ]
        case .grok:
            markerPaths = [
                ".grok/sessions/question%20with%20spaces/session-id/chat_history.jsonl",
                ".grok/sessions/question%20with%20spaces/session-id/prompt_history.jsonl",
                ".grok/active_sessions.json",
                ".grok/active_sessions.lock",
                ".grok/logs/runtime.log",
            ]
            survivorPaths = [
                ".grok/auth.json",
                ".grok/config.toml",
                "bundled/asset.bin",
                "plugins/p.bin",
                "cache/c.json",
            ]
        }

        var plantedMarkerBytes: Int64 = 0
        for (index, relativePath) in markerPaths.enumerated() {
            let data = Data("private marker \(index): question and answer text".utf8)
            try write(data, relativePath: relativePath, under: home)
            plantedMarkerBytes += Int64(data.count)
        }
        for (index, relativePath) in survivorPaths.enumerated() {
            try write(Data("survivor \(index)".utf8), relativePath: relativePath, under: home)
        }

        // Capture survivor data for verification
        var survivorData: [String: Data] = [:]
        for relativePath in survivorPaths {
            let survivorURL = home.appendingPathComponent(relativePath)
            if let data = try? Data(contentsOf: survivorURL) {
                survivorData[relativePath] = data
            }
        }
        
        return Fixture(
            home: home,
            markerPaths: markerPaths,
            survivorPaths: survivorPaths,
            plantedMarkerBytes: plantedMarkerBytes,
            survivorData: survivorData
        )
    }


    // MARK: - Spoken-answer audio (the only audio Yappy writes)

    func testPurgeSpokenAnswersDeletesEveryWavAndReportsBytes() throws {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        let directory = support
            .appendingPathComponent("Yappy", isDirectory: true)
            .appendingPathComponent("tts", isDirectory: true)
        // Never clobber real spoken answers: skip when the folder already has
        // content (a developer machine mid-playback).
        let existing = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        try XCTSkipUnless(existing.isEmpty, "tts folder in use; skipping destructive check")

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x41, count: 2048)
        for index in 1...3 {
            try payload.write(to: directory.appendingPathComponent("answer-\(index).wav"))
        }

        let reclaimed = AskRuntimeStorage.purgeSpokenAnswers()

        XCTAssertGreaterThanOrEqual(reclaimed, Int64(payload.count * 3),
                                    "Reports at least the bytes it deleted")
        let remaining = try fileManager.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty, "Every answer-N.wav is gone")
        XCTAssertEqual(AskRuntimeStorage.purgeSpokenAnswers(), 0, "Idempotent")
    }

    private func write(_ data: Data, relativePath: String, under home: URL) throws {
        let fileURL = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
    }
}
