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
        try? FileManager.default.removeItem(at: statsFileURL)
        store = nil
        super.tearDown()
    }

    /// The lifetime-stats sidecar the store writes beside its entries file.
    var statsFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("stats.json")
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

    func testAddUpdatesEntriesSynchronously() {
        let entry = DictationEntry(text: "paste-safe entry", durationSeconds: 2)
        store.add(entry)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, entry.id)
        XCTAssertEqual(store.entries[0].text, "paste-safe entry")
    }

    func testAddDefersDerivedStatsRecomputeCoalescing() {
        store.add(DictationEntry(text: "one two", durationSeconds: 2))
        store.add(DictationEntry(text: "three four five", durationSeconds: 3))
        store.recomputeDerivedNowForTesting()

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.totalWords, 5)
    }

    func testWordCountAndStats() {
        store.add(DictationEntry(text: "hello world how are you", durationSeconds: 5))
        store.recomputeDerivedNowForTesting()

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

    // MARK: - Lifetime stats survive list mutations

    func testClearAllKeepsLifetimeStats() {
        store.add(DictationEntry(text: "one two three", durationSeconds: 3))
        store.add(DictationEntry(text: "four five", durationSeconds: 2))

        store.clearAll()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.totalWords, 5)
        XCTAssertEqual(store.totalDurationSeconds, 5, accuracy: 0.001)
    }

    func testDeleteKeepsLifetimeStats() {
        let entry = DictationEntry(text: "delete me now", durationSeconds: 2)
        store.add(entry)
        store.add(DictationEntry(text: "keep me", durationSeconds: 1))

        store.delete(entry)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.totalWords, 5)
    }

    func testLifetimeStatsSurviveClearAcrossRelaunch() {
        store.add(DictationEntry(text: "one two three four", durationSeconds: 4))
        store.clearAll()

        // Wait for the async sidecar write, then simulate an app relaunch.
        let settled = expectation(description: "io settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertEqual(reloaded.totalWords, 4)
    }

    func testLifetimeStatsSeedFromExistingEntriesOnFirstLoad() throws {
        // Pre-sidecar install: entries exist on disk, no stats file. The first
        // load must seed the lifetime counters from the visible history.
        let entries = [
            DictationEntry(text: "six words here in this entry", durationSeconds: 6),
            DictationEntry(text: "two more", durationSeconds: 2)
        ]
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL)

        let migrated = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(migrated.totalWords, 8)
        XCTAssertEqual(migrated.totalDurationSeconds, 8, accuracy: 0.001)
    }

    func testLifetimeStatsNeverLoadLowerThanVisibleEntries() throws {
        // A stale/corrupt sidecar that undercounts is corrected upward by the
        // entries that are plainly on disk.
        let entries = [DictationEntry(text: "one two three four five", durationSeconds: 5)]
        try JSONEncoder().encode(entries).write(to: fileURL)
        try Data(#"{"words":2,"durationSeconds":1}"#.utf8).write(to: statsFileURL)

        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.totalWords, 5)
    }

    // MARK: - Retention

    func testApplyingRetentionKeepsRecentDropsOld() {
        let now = Date()
        let recent = DictationEntry(date: now.addingTimeInterval(-3 * 86_400), text: "recent", durationSeconds: 1)
        let old = DictationEntry(date: now.addingTimeInterval(-40 * 86_400), text: "old", durationSeconds: 1)

        let kept = HistoryStore.applyingRetention(to: [recent, old], days: 30, now: now)

        XCTAssertEqual(kept.map(\.text), ["recent"], "Only entries within the window survive")
    }

    func testApplyingRetentionForeverKeepsAll() {
        let now = Date()
        let entries = [
            DictationEntry(date: now.addingTimeInterval(-1000 * 86_400), text: "ancient", durationSeconds: 1),
            DictationEntry(date: now, text: "fresh", durationSeconds: 1)
        ]

        // days <= 0 means keep forever → input returned unchanged.
        XCTAssertEqual(HistoryStore.applyingRetention(to: entries, days: 0, now: now).count, 2)
        XCTAssertEqual(HistoryStore.applyingRetention(to: entries, days: -5, now: now).count, 2)
    }

    func testApplyingRetentionBoundaryIsInclusive() {
        let now = Date()
        // Exactly at the cutoff (7 days ago) should be kept (>=), just past it dropped.
        let atCutoff = DictationEntry(date: now.addingTimeInterval(-7 * 86_400), text: "edge", durationSeconds: 1)
        let justPast = DictationEntry(date: now.addingTimeInterval(-7 * 86_400 - 60), text: "gone", durationSeconds: 1)

        let kept = HistoryStore.applyingRetention(to: [atCutoff, justPast], days: 7, now: now)

        XCTAssertEqual(kept.map(\.text), ["edge"])
    }

    func testAddPrunesEntriesOutsideRetentionWindow() {
        store.retentionDays = 30
        store.add(DictationEntry(date: Date().addingTimeInterval(-40 * 86_400), text: "stale", durationSeconds: 1))
        store.add(DictationEntry(text: "fresh", durationSeconds: 1))

        XCTAssertEqual(store.entries.map(\.text), ["fresh"], "add() drops entries older than retentionDays")
    }

    func testAddPersistsPrunedSet() throws {
        // With a retention window, add() should both prune in memory AND write the
        // pruned set to disk, so a fresh reload never resurrects stale entries.
        store.retentionDays = 30
        store.add(DictationEntry(date: Date().addingTimeInterval(-40 * 86_400), text: "stale", durationSeconds: 1))
        store.add(DictationEntry(text: "fresh", durationSeconds: 1))

        // Writes are async on a utility queue; allow them to flush.
        let deadline = Date().addingTimeInterval(2)
        var reloaded = HistoryStore(fileURL: fileURL)
        while reloaded.entries.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = HistoryStore(fileURL: fileURL)
        }

        XCTAssertEqual(reloaded.entries.map(\.text), ["fresh"], "Persisted history excludes pruned entries")
    }

    // MARK: - Time saved

    func testTimeSavedMath() {
        // 400 words typed at 40 wpm = 10 min; spoken in 120 s = 2 min → 8 saved.
        XCTAssertEqual(HistoryStore.timeSavedMinutes(totalWords: 400, totalDurationSeconds: 120), 8)
        // Slower than typing → floored at 0.
        XCTAssertEqual(HistoryStore.timeSavedMinutes(totalWords: 10, totalDurationSeconds: 600), 0)
        XCTAssertEqual(HistoryStore.timeSavedMinutes(totalWords: 0, totalDurationSeconds: 0), 0)
    }

    func testTimeSavedFormatting() {
        XCTAssertEqual(HistoryStore.formatTimeSaved(minutes: 0), "0m")
        XCTAssertEqual(HistoryStore.formatTimeSaved(minutes: 59), "59m")
        XCTAssertEqual(HistoryStore.formatTimeSaved(minutes: 60), "1h 0m")
        XCTAssertEqual(HistoryStore.formatTimeSaved(minutes: 192), "3h 12m")
    }

    // MARK: - Corruption

    func testGarbageBytesLoadYieldsEmptyNoCrash() throws {
        // Corrupt on-disk JSON must not crash; load leaves the store empty.
        try Data("not-valid-json{{{".utf8).write(to: fileURL, options: .atomic)
        let corrupted = HistoryStore(fileURL: fileURL)
        XCTAssertTrue(corrupted.entries.isEmpty)
        // Store remains usable after a corrupt load.
        corrupted.add(DictationEntry(text: "after corrupt", durationSeconds: 1))
        XCTAssertEqual(corrupted.entries.count, 1)
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

    func testDecodesLegacyEntriesWithoutRawTranscript() throws {
        // History written before rawTranscript existed must still load, with the
        // missing key decoding to nil (synthesized Codable + optional field).
        let legacy = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":760000000.0,
          "text":"cleaned entry","durationSeconds":2.5,"appName":"Slack","bundleID":"com.slack"}]
        """
        try legacy.data(using: .utf8)!.write(to: fileURL)

        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].text, "cleaned entry")
        XCTAssertNil(reloaded.entries[0].rawTranscript)
    }

    func testPersistsAndReloadsRawTranscript() throws {
        store.add(DictationEntry(
            text: "Let's meet at noon.", durationSeconds: 3,
            rawTranscript: "um let us meet at noon"))

        // Writes are async on a utility queue; allow them to flush.
        let deadline = Date().addingTimeInterval(2)
        var reloaded = HistoryStore(fileURL: fileURL)
        while reloaded.entries.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = HistoryStore(fileURL: fileURL)
        }

        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].text, "Let's meet at noon.")
        XCTAssertEqual(reloaded.entries[0].rawTranscript, "um let us meet at noon")
    }

    // MARK: - Top apps

    func testTopAppsAggregation() {
        store.add(DictationEntry(text: "one two", durationSeconds: 1, appName: "Slack", bundleID: "com.slack"))
        store.add(DictationEntry(text: "three", durationSeconds: 1, appName: "Slack", bundleID: "com.slack"))
        store.add(DictationEntry(text: "four five six", durationSeconds: 1, appName: "Mail", bundleID: "com.mail"))
        store.recomputeDerivedNowForTesting()

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
