//
//  HistoryInsightsTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class HistoryInsightsTests: XCTestCase {

    /// `text` repeated `count` times as history entries.
    private func entries(_ text: String, _ count: Int) -> [DictationEntry] {
        (0..<count).map { _ in DictationEntry(text: text, durationSeconds: 2) }
    }

    private func suggest(
        _ entries: [DictationEntry],
        existing: [VoiceShortcut] = [],
        dismissed: Set<String> = []
    ) -> [ShortcutSuggestion] {
        HistoryInsights.suggestedShortcuts(from: entries, existing: existing, dismissedKeys: dismissed)
    }

    func testRepeatedPhraseSurfaces() {
        let result = suggest(entries("best regards, Luis", 3))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.count, 3)
        XCTAssertEqual(result.first?.phrase, "best regards, Luis")
    }

    func testBelowThresholdExcluded() {
        XCTAssertTrue(suggest(entries("see you tomorrow", 2)).isEmpty)
    }

    func testExistingShortcutExpansionExcluded() {
        let shortcut = VoiceShortcut(trigger: "sig", expansion: "best regards, Luis")
        XCTAssertTrue(suggest(entries("best regards, Luis", 4), existing: [shortcut]).isEmpty)
    }

    func testSingleWordExcluded() {
        XCTAssertTrue(suggest(entries("okay", 5)).isEmpty)
    }

    func testOverLongPhraseExcluded() {
        let long = "one two three four five six seven eight nine ten eleven twelve thirteen"
        XCTAssertTrue(suggest(entries(long, 4)).isEmpty)
    }

    func testDismissedExcluded() {
        let key = HistoryInsights.normalize("schedule a follow up")
        XCTAssertTrue(suggest(entries("schedule a follow up", 4), dismissed: [key]).isEmpty)
    }

    func testCaseAndWhitespaceInsensitiveGrouping() {
        var es = entries("Hello   There", 2)
        es += entries("hello there", 1)
        let result = suggest(es)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.count, 3)
    }

    func testOrderedByCountDescending() {
        var es = entries("phrase alpha here", 3)
        es += entries("phrase beta here", 5)
        let result = suggest(es)
        XCTAssertEqual(result.map(\.count), [5, 3])
        XCTAssertEqual(result.first?.phrase, "phrase beta here")
    }

    func testEmptyHistory() {
        XCTAssertTrue(suggest([]).isEmpty)
    }
}
