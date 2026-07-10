//
//  AskHistoryStoreTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

@MainActor
final class AskHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-history-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testAddInsertsNewestFirst() {
        let store = AskHistoryStore(directory: directory)
        store.add(question: "first?", answer: "one", backend: "codex")
        store.add(question: "second?", answer: "two", backend: "grok")

        XCTAssertEqual(store.entries.map(\.question), ["second?", "first?"])
        XCTAssertEqual(store.last?.answer, "two")
        XCTAssertEqual(store.last?.backend, "grok")
    }

    func testEmptyAnswerIsNotRecorded() {
        let store = AskHistoryStore(directory: directory)
        store.add(question: "q", answer: "   \n", backend: "codex")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPersistenceRoundTrip() {
        let first = AskHistoryStore(directory: directory)
        first.add(question: "capital of France?", answer: "Paris.", backend: "codex")
        first.flushForTesting()

        let second = AskHistoryStore(directory: directory)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.question, "capital of France?")
        XCTAssertEqual(second.entries.first?.answer, "Paris.")
    }

    func testToggleFavoriteFlipsAndPersists() {
        let first = AskHistoryStore(directory: directory)
        first.add(question: "save this?", answer: "Saved.", backend: "codex")

        first.toggleFavorite(first.entries[0])
        XCTAssertEqual(first.entries.first?.isFavorite, true)
        first.flushForTesting()

        let second = AskHistoryStore(directory: directory)
        XCTAssertEqual(second.entries.first?.isFavorite, true)

        second.toggleFavorite(second.entries[0])
        XCTAssertEqual(second.entries.first?.isFavorite, false)
        second.flushForTesting()

        let third = AskHistoryStore(directory: directory)
        XCTAssertEqual(third.entries.first?.isFavorite, false)
    }

    func testLegacyHistoryWithoutFavoriteDecodesAsNotFavorite() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("ask-history.json")
        let json = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "date": 0,
            "question": "legacy?",
            "answer": "Legacy answer.",
            "backend": "grok",
            "modelLabel": null
          }
        ]
        """
        try json.data(using: .utf8)?.write(to: fileURL, options: .atomic)

        let store = AskHistoryStore(directory: directory)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.question, "legacy?")
        XCTAssertEqual(store.entries.first?.isFavorite, false)
    }

    func testCapKeepsNewest100() {
        let store = AskHistoryStore(directory: directory)
        for index in 1...105 {
            store.add(question: "q\(index)", answer: "a\(index)", backend: "codex")
        }
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertEqual(store.entries.first?.question, "q105")
        XCTAssertEqual(store.entries.last?.question, "q6")
    }

    func testGarbageBytesLoadYieldsEmptyNoCrash() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("ask-history.json")
        try Data("{{{not-json".utf8).write(to: fileURL, options: .atomic)

        let store = AskHistoryStore(directory: directory)
        XCTAssertTrue(store.entries.isEmpty)
        store.add(question: "after?", answer: "ok", backend: "codex")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testCapPreservesFavoritesEvictsOldestNonFavorite() {
        let store = AskHistoryStore(directory: directory, maxEntries: 3)
        store.add(question: "q1", answer: "a1", backend: "codex")
        store.add(question: "q2", answer: "a2", backend: "codex")
        store.add(question: "q3", answer: "a3", backend: "codex")

        let favorite = store.entries.last!
        store.toggleFavorite(favorite)
        XCTAssertEqual(favorite.question, "q1")

        store.add(question: "q4", answer: "a4", backend: "codex")
        store.add(question: "q5", answer: "a5", backend: "codex")
        store.add(question: "q6", answer: "a6", backend: "codex")

        XCTAssertEqual(store.entries.count, 3)
        XCTAssertTrue(store.entries.contains(where: { $0.question == "q1" && $0.isFavorite }))
        XCTAssertFalse(store.entries.contains(where: { $0.question == "q2" }))
        XCTAssertFalse(store.entries.contains(where: { $0.question == "q3" }))
        XCTAssertEqual(store.entries.first?.question, "q6")
    }

    func testRemoveAndClear() {
        let store = AskHistoryStore(directory: directory)
        store.add(question: "a?", answer: "1", backend: "codex")
        store.add(question: "b?", answer: "2", backend: "codex")

        let victim = store.entries[0]
        store.remove(victim)
        XCTAssertEqual(store.entries.map(\.question), ["a?"])

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        store.flushForTesting()

        let reloaded = AskHistoryStore(directory: directory)
        XCTAssertTrue(reloaded.entries.isEmpty, "clear must also remove the file")
    }

    func testClearDoesNotResurrectPendingSave() {
        let store = AskHistoryStore(directory: directory)
        store.add(question: "gone?", answer: "should not return", backend: "codex")
        store.clear()
        store.flushForTesting()

        let reloaded = AskHistoryStore(directory: directory)
        XCTAssertTrue(reloaded.entries.isEmpty, "a stale queued save must not resurrect cleared history")
    }

    func testRapidAddsPersistInNewestFirstOrder() {
        let store = AskHistoryStore(directory: directory)
        store.add(question: "first?", answer: "one", backend: "codex")
        store.add(question: "second?", answer: "two", backend: "grok")
        store.flushForTesting()

        let reloaded = AskHistoryStore(directory: directory)
        XCTAssertEqual(reloaded.entries.map(\.question), ["second?", "first?"])
        XCTAssertEqual(reloaded.entries.map(\.answer), ["two", "one"])
    }
}
