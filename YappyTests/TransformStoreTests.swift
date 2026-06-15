//
//  TransformStoreTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class TransformStoreTests: XCTestCase {

    var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-transforms-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func store(seeds: Bool = false) -> TransformStore {
        TransformStore(fileURL: fileURL, seedsBuiltIns: seeds)
    }

    // MARK: - CRUD

    func testAddUpdateDelete() {
        let s = store()
        XCTAssertTrue(s.transforms.isEmpty)

        let t = Transform(name: "Shorten", prompt: "Make it shorter.")
        s.add(t)
        XCTAssertEqual(s.transforms.count, 1)

        var updated = t
        updated.name = "Condense"
        s.update(updated)
        XCTAssertEqual(s.transforms.first?.name, "Condense")

        s.delete(updated)
        XCTAssertTrue(s.transforms.isEmpty)
    }

    func testEnabledTransformsFiltersDisabled() {
        let s = store()
        s.add(Transform(name: "On", prompt: "x", enabled: true))
        s.add(Transform(name: "Off", prompt: "y", enabled: false))
        XCTAssertEqual(s.enabledTransforms.map(\.name), ["On"])
    }

    // MARK: - Seeding

    func testSeedsBuiltInsExactlyOnce() {
        let suite = "com.yappy.tf.seed.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }

        let first = TransformStore(fileURL: fileURL, defaults: d, seedsBuiltIns: true)
        XCTAssertTrue(first.transforms.contains { $0.name == "Polish" && $0.isBuiltIn })
        XCTAssertTrue(first.transforms.contains { $0.name == "Prompt Engineer" })
        let count = first.transforms.count

        let deadline = Date().addingTimeInterval(2)
        while (try? Data(contentsOf: fileURL)) == nil, Date() < deadline { usleep(50_000) }

        let second = TransformStore(fileURL: fileURL, defaults: d, seedsBuiltIns: true)
        XCTAssertEqual(second.transforms.count, count, "Built-ins must seed only once")
    }

    func testRoundTripsThroughDisk() {
        let s = store()
        s.add(Transform(name: "Bulletize", prompt: "Turn this into bullet points."))

        let deadline = Date().addingTimeInterval(2)
        var reloaded = store()
        while reloaded.transforms.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = store()
        }
        XCTAssertEqual(reloaded.transforms.first?.name, "Bulletize")
        XCTAssertEqual(reloaded.transforms.first?.prompt, "Turn this into bullet points.")
    }
}
