//
//  StorageInventoryTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class StorageInventoryTests: XCTestCase {
    func testMeasuresNestedFilesAndIgnoresOutsideSymlink() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let root = fixture.appendingPathComponent("root", isDirectory: true)
        let nested = root.appendingPathComponent("nested/deeper", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside.bin")
        let link = root.appendingPathComponent("outside-link")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let first = root.appendingPathComponent("first.bin")
        let second = nested.appendingPathComponent("second.bin")
        try Data(repeating: 0x41, count: 1_337).write(to: first)
        try Data(repeating: 0x42, count: 8_191).write(to: second)
        try Data(repeating: 0x43, count: 64 * 1_024).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let expected = try allocatedSize(of: first) + allocatedSize(of: second)
        let items = await StorageInventory.measure(
            locations: [
                StorageLocation(id: "fixture", title: "Fixture", detail: "Nested fixture", url: root),
            ]
        )

        XCTAssertEqual(
            items,
            [StorageItem(id: "fixture", title: "Fixture", detail: "Nested fixture", bytes: expected)]
        )
    }

    func testEmptyDirectoryAndMissingPathMeasureZero() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let empty = fixture.appendingPathComponent("empty", isDirectory: true)
        let missing = fixture.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let items = await StorageInventory.measure(
            locations: [
                StorageLocation(id: "empty", title: "Empty", detail: "Empty directory", url: empty),
                StorageLocation(id: "missing", title: "Missing", detail: "Missing directory", url: missing),
            ]
        )

        XCTAssertEqual(items.map(\.bytes), [0, 0])
        XCTAssertTrue(items.allSatisfy(\.isEmpty))
    }

    func testMeasuresSingleFile() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageInventoryTests-\(UUID().uuidString).bin")
        try Data(repeating: 0x44, count: 4_097).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let expected = try allocatedSize(of: fixture)
        let items = await StorageInventory.measure(
            locations: [
                StorageLocation(id: "file", title: "File", detail: "Single file", url: fixture),
            ]
        )

        XCTAssertEqual(items.first?.bytes, expected)
    }

    func testFormattedByteCountHasHumanReadableNumberAndUnit() {
        let formatted = StorageInventory.formatted(1_234_567_890)
        XCTAssertNotNil(formatted.range(of: #"\d"#, options: .regularExpression))
        XCTAssertNotNil(formatted.range(of: #"[A-Za-z]"#, options: .regularExpression))

        let zero = StorageInventory.formatted(0)
        XCTAssertFalse(zero.isEmpty)
        XCTAssertFalse(zero.localizedCaseInsensitiveContains("KB"))
    }

    func testLocationsHaveUniqueNonemptyIDsAndMetadata() {
        let locations = StorageInventory.locations
        let ids = locations.map(\.id)

        XCTAssertFalse(locations.isEmpty)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertTrue(locations.allSatisfy {
            !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.detail.trimmingCharacters(in: .whitespaces).isEmpty
        })
    }

    private func allocatedSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
}
