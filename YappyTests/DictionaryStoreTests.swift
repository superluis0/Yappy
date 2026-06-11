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
        XCTAssertEqual(store.boostTerms, ["Kubernetes"])
        store.remove(store.terms[0])
        XCTAssertTrue(store.terms.isEmpty)
    }

    func testRejectsBlankAndDuplicates() {
        store.add("Anthropic")
        store.add("   ")
        store.add("anthropic") // case-insensitive duplicate
        XCTAssertEqual(store.boostTerms, ["Anthropic"])
    }

    func testTrimsWhitespace() {
        store.add("  PyTorch  ")
        XCTAssertEqual(store.boostTerms, ["PyTorch"])
    }

    func testPersistsAcrossInstances() {
        store.add("TensorRT")

        let deadline = Date().addingTimeInterval(2)
        var reloaded = DictionaryStore(fileURL: fileURL)
        while reloaded.terms.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = DictionaryStore(fileURL: fileURL)
        }
        XCTAssertEqual(reloaded.boostTerms, ["TensorRT"])
    }

    // MARK: - Aliases

    func testSetAndRoundTripAliases() {
        store.add("Luis")
        let term = store.terms[0]
        store.setAliases(["Lewis", "Louie"], for: term)
        store.addLearnedAliases(["Louise"], to: term)

        let updated = store.terms[0]
        XCTAssertEqual(updated.aliases, ["Lewis", "Louie"])
        XCTAssertEqual(updated.learnedAliases, ["Louise"])
        XCTAssertEqual(updated.allAliases, ["Lewis", "Louie", "Louise"])
    }

    func testAllAliasesDedupesAndExcludesText() {
        let term = DictionaryTerm(
            text: "Luis",
            aliases: ["Lewis", "luis", "Louie"],
            learnedAliases: ["lewis", "Louise"]
        )
        // "luis" == text (dropped), "lewis" duplicates "Lewis" (dropped).
        XCTAssertEqual(term.allAliases, ["Lewis", "Louie", "Louise"])
    }

    func testLearnedAliasesDoNotDuplicate() {
        store.add("Yappy")
        let term = store.terms[0]
        store.addLearnedAliases(["Yappie"], to: term)
        store.addLearnedAliases(["yappie", "Yappee"], to: term)
        XCTAssertEqual(store.terms[0].learnedAliases, ["Yappie", "Yappee"])
    }

    // MARK: - Legacy migration

    func testDecodesLegacyStringArray() throws {
        // Old dictionary.json was a bare array of strings.
        let legacy = try JSONEncoder().encode(["Kubernetes", "Anthropic"])
        try legacy.write(to: fileURL, options: .atomic)

        let migrated = DictionaryStore(fileURL: fileURL)
        XCTAssertEqual(migrated.boostTerms, ["Kubernetes", "Anthropic"])
        XCTAssertTrue(migrated.terms.allSatisfy { $0.aliases.isEmpty && $0.learnedAliases.isEmpty })
    }

    func testLegacyFileIsRewrittenAsObjects() throws {
        let legacy = try JSONEncoder().encode(["Kubernetes"])
        try legacy.write(to: fileURL, options: .atomic)
        _ = DictionaryStore(fileURL: fileURL) // triggers migrate + persist

        // Wait for the async rewrite, then confirm it now decodes as terms.
        let deadline = Date().addingTimeInterval(2)
        var decodedAsObjects = false
        while Date() < deadline {
            if let data = try? Data(contentsOf: fileURL),
               (try? JSONDecoder().decode([DictionaryTerm].self, from: data)) != nil {
                decodedAsObjects = true
                break
            }
            usleep(50_000)
        }
        XCTAssertTrue(decodedAsObjects, "Legacy file should be rewritten as DictionaryTerm objects")
    }
}
