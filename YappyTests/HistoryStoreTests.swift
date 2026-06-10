//
//  HistoryStoreTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class HistoryStoreTests: XCTestCase {

    var fileURL: URL!
    var store: HistoryStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-history-tests-\(UUID().uuidString).json")
        store = HistoryStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        store = nil
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.totalWords, 0)
        XCTAssertEqual(store.dictationsToday, 0)
        XCTAssertEqual(store.averageWordsPerMinute, 0)
        XCTAssertEqual(store.streakDays, 0)
    }

    func testAddInsertsNewestFirst() {
        store.add(DictationEntry(text: "first entry", durationSeconds: 2))
        store.add(DictationEntry(text: "second entry", durationSeconds: 2))

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].text, "second entry")
    }

    func testWordCountAndStats() {
        store.add(DictationEntry(text: "hello world how are you", durationSeconds: 5))

        XCTAssertEqual(store.entries[0].wordCount, 5)
        XCTAssertEqual(store.totalWords, 5)
        XCTAssertEqual(store.dictationsToday, 1)
        XCTAssertEqual(store.averageWordsPerMinute, 60)
        XCTAssertEqual(store.streakDays, 1)
    }

    func testDelete() {
        let entry = DictationEntry(text: "delete me", durationSeconds: 1)
        store.add(entry)
        store.add(DictationEntry(text: "keep me", durationSeconds: 1))

        store.delete(entry)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "keep me")
    }

    func testClearAll() {
        store.add(DictationEntry(text: "one", durationSeconds: 1))
        store.add(DictationEntry(text: "two", durationSeconds: 1))

        store.clearAll()

        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Backward compatibility

    func testDecodesLegacyEntriesWithoutBundleID() throws {
        // History written by versions before bundleID existed must still load.
        let legacy = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":760000000.0,
          "text":"legacy entry","durationSeconds":2.5,"appName":"Slack"},
         {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","date":760000100.0,
          "text":"no app at all","durationSeconds":1.0}]
        """
        try legacy.data(using: .utf8)!.write(to: fileURL)

        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries[0].text, "legacy entry")
        XCTAssertNil(reloaded.entries[0].bundleID)
        XCTAssertNil(reloaded.entries[1].appName)
    }

    // MARK: - Top apps

    func testTopAppsAggregation() {
        store.add(DictationEntry(text: "one two", durationSeconds: 1, appName: "Slack", bundleID: "com.slack"))
        store.add(DictationEntry(text: "three", durationSeconds: 1, appName: "Slack", bundleID: "com.slack"))
        store.add(DictationEntry(text: "four five six", durationSeconds: 1, appName: "Mail", bundleID: "com.mail"))

        let top = store.topApps()
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].appName, "Slack")
        XCTAssertEqual(top[0].count, 2)
        XCTAssertEqual(top[0].words, 3)
        XCTAssertEqual(top[1].appName, "Mail")
        XCTAssertEqual(top[1].words, 3)
    }

    func testPersistsAcrossInstances() {
        store.add(DictationEntry(text: "persist me", durationSeconds: 3))

        // Writes are async on a utility queue; allow them to flush.
        let deadline = Date().addingTimeInterval(2)
        var reloaded = HistoryStore(fileURL: fileURL)
        while reloaded.entries.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = HistoryStore(fileURL: fileURL)
        }

        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].text, "persist me")
    }
}
