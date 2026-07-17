//
//  DictionaryStoreTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class DictionaryStoreTests: XCTestCase {

    var testDir: URL!
    var fileURL: URL!
    var store: DictionaryStore!

    override func setUp() {
        super.setUp()
        // A per-test directory so the derived suggestions file (which sits
        // beside the terms file) is isolated too — it doesn't carry the test's
        // UUID in its own name.
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-dictionary-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        fileURL = testDir.appendingPathComponent("dictionary.json")
        store = DictionaryStore(fileURL: fileURL, seedsBuiltIns: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
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

    // MARK: - Vocabulary-boosting replacement plausibility

    func testImplausibleBoostReplacementRejected() {
        // Field regression: the CTC rescorer acoustically matched spoken "error"
        // to the term "Terraform" and rewrote every occurrence. Textually the two
        // share almost nothing — the guard must reject it.
        XCTAssertFalse(ParakeetTranscriptionService.plausibleBoostReplacement(
            original: "error", term: "Terraform", aliases: ["terra form"]))
    }

    func testPlausibleBoostReplacementsAccepted() {
        // Real mishearings are textually close to the term or an alias.
        XCTAssertTrue(ParakeetTranscriptionService.plausibleBoostReplacement(
            original: "terra form", term: "Terraform", aliases: ["terra form"]))
        XCTAssertTrue(ParakeetTranscriptionService.plausibleBoostReplacement(
            original: "harkonen", term: "Harkonnen", aliases: []))
        XCTAssertTrue(ParakeetTranscriptionService.plausibleBoostReplacement(
            original: "super base", term: "Supabase", aliases: ["super base"]))
        // Alias-only similarity counts too ("veet" is nothing like "Vite" spelled,
        // but it IS the alias).
        XCTAssertTrue(ParakeetTranscriptionService.plausibleBoostReplacement(
            original: "veet", term: "Vite", aliases: ["veet"]))
    }

    func testEditSimilarityBounds() {
        XCTAssertEqual(ParakeetTranscriptionService.editSimilarity("same", "same"), 1.0)
        XCTAssertEqual(ParakeetTranscriptionService.editSimilarity("", ""), 1.0)
        XCTAssertEqual(ParakeetTranscriptionService.editSimilarity("abc", ""), 0.0)
        XCTAssertTrue(ParakeetTranscriptionService.editSimilarity("Error", "error") == 1.0)
        // "error" is a SUBSEQUENCE of "terraform" (4 insertions, similarity ~0.56)
        // — deceptively high, which is exactly why the threshold sits above it.
        XCTAssertLessThan(ParakeetTranscriptionService.editSimilarity("error", "terraform"),
                          ParakeetTranscriptionService.boostReplacementMinSimilarity)
    }

    // MARK: - Vocabulary-boosting term builder

    func testBuildBoostTermsIsEmptyForNoInput() {
        XCTAssertTrue(ParakeetTranscriptionService.buildBoostTerms(from: []).isEmpty)
    }

    func testBuildBoostTermsDropsShortTerms() {
        let terms = [
            DictionaryTerm(text: "Go"),        // 2 chars — dropped
            DictionaryTerm(text: "  R  "),     // 1 char after trim — dropped
            DictionaryTerm(text: "Vim"),       // 3 chars — kept
            DictionaryTerm(text: "Kubernetes"), // kept
        ]
        let built = ParakeetTranscriptionService.buildBoostTerms(from: terms)
        XCTAssertEqual(built.map(\.text), ["Vim", "Kubernetes"])
    }

    func testBuildBoostTermsCapsAtMaxKeepingDictionaryOrder() {
        let count = ParakeetTranscriptionService.vocabularyMaxTermCount + 25
        let terms = (0..<count).map { DictionaryTerm(text: "term\($0)") }
        let built = ParakeetTranscriptionService.buildBoostTerms(from: terms)

        XCTAssertEqual(built.count, ParakeetTranscriptionService.vocabularyMaxTermCount)
        // The first N in dictionary order are kept.
        XCTAssertEqual(built.first?.text, "term0")
        XCTAssertEqual(built.last?.text, "term\(ParakeetTranscriptionService.vocabularyMaxTermCount - 1)")
    }

    func testBuildBoostTermsFoldsManualAndLearnedAliases() {
        let term = DictionaryTerm(
            text: "Luis",
            aliases: ["Lewis", "Louie"],
            learnedAliases: ["Louise"]
        )
        let built = ParakeetTranscriptionService.buildBoostTerms(from: [term])
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built.first?.text, "Luis")
        // Mirrors DictionaryTerm.allAliases: manual first, learned appended.
        XCTAssertEqual(built.first?.aliases, ["Lewis", "Louie", "Louise"])
    }

    // MARK: - Alias suggestions (learn-from-corrections)

    func testAddSuggestionDedupesIdenticalPending() {
        store.addSuggestion(heard: "harkonen", corrected: "Harkonnen")
        store.addSuggestion(heard: "Harkonen", corrected: "harkonnen") // case-insensitive dup
        XCTAssertEqual(store.suggestions.count, 1)
        XCTAssertEqual(store.suggestions.first?.heard, "harkonen")
        XCTAssertEqual(store.suggestions.first?.corrected, "Harkonnen")
    }

    func testAddSuggestionSkipsAlreadyKnownAlias() {
        store.add("Luis")
        store.addLearnedAliases(["Lewis"], to: store.terms[0])
        store.addSuggestion(heard: "lewis", corrected: "luis") // already known
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testAddSuggestionRespectsDismissedKeys() {
        store.addSuggestion(heard: "harkonen", corrected: "Harkonnen")
        let suggestion = store.suggestions[0]
        store.dismissSuggestion(suggestion)
        XCTAssertTrue(store.suggestions.isEmpty)

        // Same pair should not come back after being dismissed.
        store.addSuggestion(heard: "Harkonen", corrected: "harkonnen")
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testAddSuggestionCapsAtTenDroppingOldest() {
        for i in 0..<13 {
            store.addSuggestion(heard: "heard\(i)", corrected: "corrected\(i)")
        }
        XCTAssertEqual(store.suggestions.count, 10)
        // The three oldest (0,1,2) were dropped; 3...12 remain in order.
        XCTAssertEqual(store.suggestions.first?.heard, "heard3")
        XCTAssertEqual(store.suggestions.last?.heard, "heard12")
    }

    func testAcceptSuggestionAddsLearnedAliasToExistingTerm() {
        store.add("Luis")
        store.addSuggestion(heard: "Lewis", corrected: "luis") // matches case-insensitively
        let suggestion = store.suggestions[0]
        store.acceptSuggestion(suggestion)

        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(store.terms[0].learnedAliases, ["Lewis"])
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testAcceptSuggestionCreatesTermWhenMissing() {
        store.addSuggestion(heard: "harkonen", corrected: "Harkonnen")
        let suggestion = store.suggestions[0]
        store.acceptSuggestion(suggestion)

        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(store.terms[0].text, "Harkonnen")
        XCTAssertEqual(store.terms[0].learnedAliases, ["harkonen"])
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    // MARK: - Auto-learn apply / undo

    func testApplyLearnedAliasCreatesTermAndUndoRemovesIt() {
        let applied = store.applyLearnedAlias(heard: "harkonen", corrected: "Harkonnen")
        XCTAssertEqual(applied?.heard, "harkonen")
        XCTAssertEqual(applied?.corrected, "Harkonnen")
        XCTAssertEqual(applied?.createdTerm, true)
        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(store.terms[0].learnedAliases, ["harkonen"])

        store.undoLearnedAlias(applied!)
        XCTAssertTrue(store.terms.isEmpty, "Undo must remove the term it created")
    }

    func testApplyLearnedAliasOnExistingTermUndoOnlyRemovesAlias() {
        store.add("Luis")
        let applied = store.applyLearnedAlias(heard: "Lewis", corrected: "luis")
        XCTAssertEqual(applied?.createdTerm, false)
        XCTAssertEqual(store.terms[0].learnedAliases, ["Lewis"])

        store.undoLearnedAlias(applied!)
        XCTAssertEqual(store.terms.count, 1)
        XCTAssertTrue(store.terms[0].learnedAliases.isEmpty)
        XCTAssertEqual(store.terms[0].text, "Luis")
    }

    func testApplyLearnedAliasNoopWhenAlreadyKnown() {
        store.add("Luis")
        _ = store.applyLearnedAlias(heard: "Lewis", corrected: "Luis")
        let second = store.applyLearnedAlias(heard: "Lewis", corrected: "Luis")
        XCTAssertNil(second)
        XCTAssertEqual(store.terms[0].learnedAliases, ["Lewis"])
    }

    func testDismissSuggestionRemovesAndPreventsReAdd() {
        store.addSuggestion(heard: "cooper netties", corrected: "kubernetes")
        XCTAssertEqual(store.suggestions.count, 1)
        store.dismissSuggestion(store.suggestions[0])
        XCTAssertTrue(store.suggestions.isEmpty)

        store.addSuggestion(heard: "cooper netties", corrected: "kubernetes")
        XCTAssertTrue(store.suggestions.isEmpty, "A dismissed pair must not be re-suggested")
    }

    func testSuggestionsPersistAcrossReload() {
        store.addSuggestion(heard: "harkonen", corrected: "Harkonnen")

        let deadline = Date().addingTimeInterval(2)
        var reloaded = DictionaryStore(fileURL: fileURL, seedsBuiltIns: false)
        while reloaded.suggestions.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = DictionaryStore(fileURL: fileURL, seedsBuiltIns: false)
        }
        XCTAssertEqual(reloaded.suggestions.count, 1)
        XCTAssertEqual(reloaded.suggestions.first?.heard, "harkonen")
        XCTAssertEqual(reloaded.suggestions.first?.corrected, "Harkonnen")
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
