//
//  ParakeetModelDirectoryTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class ParakeetModelDirectoryTests: XCTestCase {

    private let required = [
        "Decoder.mlmodelc",
        "Encoder.mlmodelc",
        "JointDecision.mlmodelc",
        "Preprocessor.mlmodelc",
        "config.json",
        "parakeet_vocab.json"
    ]

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-model-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func presentEntries(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names)
    }

    func testTempDirWithRequiredEntriesReturnsTrue() throws {
        for entry in required {
            let url = tempDir.appendingPathComponent(entry)
            // Create as files (or empty dirs for .mlmodelc package-like names).
            if entry.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data().write(to: url)
            }
        }

        let present = presentEntries(in: tempDir)
        XCTAssertTrue(
            ParakeetTranscriptionService.modelDirectoryContainsRequiredEntries(
                presentEntries: present,
                requiredEntries: required
            )
        )
    }

    func testTempDirWithoutRequiredEntriesReturnsFalse() throws {
        // Only two of the required entries.
        try Data().write(to: tempDir.appendingPathComponent("config.json"))
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Encoder.mlmodelc"),
            withIntermediateDirectories: true
        )

        let present = presentEntries(in: tempDir)
        XCTAssertFalse(
            ParakeetTranscriptionService.modelDirectoryContainsRequiredEntries(
                presentEntries: present,
                requiredEntries: required
            )
        )
    }

    func testEmptyPresentSetIsFalse() {
        XCTAssertFalse(
            ParakeetTranscriptionService.modelDirectoryContainsRequiredEntries(
                presentEntries: [],
                requiredEntries: required
            )
        )
    }

    func testEmptyRequiredIsTrue() {
        XCTAssertTrue(
            ParakeetTranscriptionService.modelDirectoryContainsRequiredEntries(
                presentEntries: ["anything"],
                requiredEntries: []
            )
        )
    }
}
