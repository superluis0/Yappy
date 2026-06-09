//
//  DictionaryStoreTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class DictionaryStoreTests: XCTestCase {

    var fileURL: URL!
    var store: DictionaryStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-dictionary-tests-\(UUID().uuidString).json")
        store = DictionaryStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        store = nil
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.terms.isEmpty)
    }

    func testAddAndRemove() {
        store.add("Kubernetes")
        XCTAssertEqual(store.terms, ["Kubernetes"])
        store.remove("Kubernetes")
        XCTAssertTrue(store.terms.isEmpty)
    }

    func testRejectsBlankAndDuplicates() {
        store.add("Anthropic")
        store.add("   ")
        store.add("anthropic") // case-insensitive duplicate
        XCTAssertEqual(store.terms, ["Anthropic"])
    }

    func testTrimsWhitespace() {
        store.add("  PyTorch  ")
        XCTAssertEqual(store.terms, ["PyTorch"])
    }

    func testPersistsAcrossInstances() {
        store.add("TensorRT")

        let deadline = Date().addingTimeInterval(2)
        var reloaded = DictionaryStore(fileURL: fileURL)
        while reloaded.terms.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = DictionaryStore(fileURL: fileURL)
        }
        XCTAssertEqual(reloaded.terms, ["TensorRT"])
    }
}
