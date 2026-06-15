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
        store = DictionaryStore(fileURL: fileURL, seedsBuiltIns: false)
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
        var reloaded = DictionaryStore(fileURL: fileURL, seedsBuiltIns: false)
        while reloaded.terms.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = DictionaryStore(fileURL: fileURL, seedsBuiltIns: false)
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

    // MARK: - Built-in seeding

    func testSeedsBuiltInTermsExactlyOnce() {
        let suite = "com.yappy.dict.seed.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-seed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = DictionaryStore(fileURL: url, defaults: d, seedsBuiltIns: true)
        XCTAssertFalse(first.terms.isEmpty, "Built-in terms should be seeded")
        XCTAssertTrue(first.terms.contains { $0.text == "Supabase" && $0.isBuiltIn })
        let seededCount = first.terms.count

        // Let the async persist land, then re-open with the same flag store.
        let deadline = Date().addingTimeInterval(2)
        while (try? Data(contentsOf: url)) == nil, Date() < deadline { usleep(50_000) }

        let second = DictionaryStore(fileURL: url, defaults: d, seedsBuiltIns: true)
        XCTAssertEqual(second.terms.count, seededCount, "Built-ins must seed only once")
    }

    func testSeedingSkipsTermsTheUserAlreadyHas() throws {
        let suite = "com.yappy.dict.seed2.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-seed2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let userTerm = DictionaryTerm(text: "Supabase", aliases: ["my custom alias"])
        try JSONEncoder().encode([userTerm]).write(to: url, options: .atomic)

        let store = DictionaryStore(fileURL: url, defaults: d, seedsBuiltIns: true)
        let supabase = store.terms.filter { $0.text.caseInsensitiveCompare("Supabase") == .orderedSame }
        XCTAssertEqual(supabase.count, 1, "Seeding must not duplicate a term the user already has")
        XCTAssertEqual(supabase.first?.aliases, ["my custom alias"], "User's own term is preserved")
    }

    // MARK: - Legacy migration

    func testDecodesLegacyStringArray() throws {
        // Old dictionary.json was a bare array of strings.
        let legacy = try JSONEncoder().encode(["Kubernetes", "Anthropic"])
        try legacy.write(to: fileURL, options: .atomic)

        let migrated = DictionaryStore(fileURL: fileURL, seedsBuiltIns: false)
        XCTAssertEqual(migrated.boostTerms, ["Kubernetes", "Anthropic"])
        XCTAssertTrue(migrated.terms.allSatisfy { $0.aliases.isEmpty && $0.learnedAliases.isEmpty })
    }

    func testLegacyFileIsRewrittenAsObjects() throws {
        let legacy = try JSONEncoder().encode(["Kubernetes"])
        try legacy.write(to: fileURL, options: .atomic)
        _ = DictionaryStore(fileURL: fileURL, seedsBuiltIns: false) // triggers migrate + persist

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
