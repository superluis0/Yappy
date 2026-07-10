//
//  CleanupCoordinatorTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

// MARK: - Fake provider

@MainActor
private final class FakeCleanupProvider: CleanupProvider {
    var displayName: String = "Fake"

    /// Maps input line → cleaned line for single-line cleanup.
    var singleLineMap: [String: String] = [:]
    /// If set, `cleanup` returns this for any input not in `singleLineMap`.
    var defaultCleanupSuffix: String = " [cleaned]"
    /// When non-nil, `cleanupBatched` returns this value (including nil = force per-line).
    var batchedResult: [String]??
    /// Count of single-line cleanup calls.
    private(set) var cleanupCallCount = 0
    /// Count of batched cleanup calls.
    private(set) var batchedCallCount = 0

    func isAvailable() async -> Bool { true }

    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool) async -> String {
        cleanupCallCount += 1
        if let mapped = singleLineMap[text] { return mapped }
        return text + defaultCleanupSuffix
    }

    func cleanupBatched(lines: [String], tone: ToneStyle, backtrack: Bool) async -> [String]? {
        batchedCallCount += 1
        if let explicit = batchedResult {
            return explicit
        }
        return lines.map { $0 + defaultCleanupSuffix }
    }
}

// MARK: - Tests

@MainActor
final class CleanupCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: Settings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CleanupCoordinatorTests-\(UUID().uuidString)")
        settings = Settings(defaults: defaults)
        settings.cleanupEnabled = true
    }

    override func tearDown() {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        defaults = nil
        settings = nil
        super.tearDown()
    }

    func testMultiLineNewlinesPreserved() async {
        let provider = FakeCleanupProvider()
        provider.batchedResult = .some(["Alpha", "Beta"])
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        let result = await coordinator.cleanup(
            "alpha\nbeta",
            tone: .casual,
            backtrack: false,
            cleanupEnabled: true
        )

        XCTAssertEqual(result, "Alpha\nBeta")
        XCTAssertEqual(provider.batchedCallCount, 1)
        XCTAssertEqual(provider.cleanupCallCount, 0)
    }

    func testBlankLinePassthrough() async {
        let provider = FakeCleanupProvider()
        provider.batchedResult = .some(["First", "Second"])
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        let result = await coordinator.cleanup(
            "first\n\nsecond",
            tone: .casual,
            backtrack: false,
            cleanupEnabled: true
        )

        XCTAssertEqual(result, "First\n\nSecond")
        // Only the two non-blank lines are batched; blank stays empty.
        XCTAssertEqual(provider.batchedCallCount, 1)
    }

    func testBatchedCountMismatchFallsBackToPerLine() async {
        let provider = FakeCleanupProvider()
        // Wrong count → coordinator must fall back to per-line.
        provider.batchedResult = .some(["only-one"])
        provider.singleLineMap = [
            "one": "ONE",
            "two": "TWO",
        ]
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        let result = await coordinator.cleanup(
            "one\ntwo",
            tone: .casual,
            backtrack: false,
            cleanupEnabled: true
        )

        XCTAssertEqual(result, "ONE\nTWO")
        XCTAssertEqual(provider.batchedCallCount, 1)
        XCTAssertEqual(provider.cleanupCallCount, 2)
    }

    func testBatchedNilFallsBackToPerLine() async {
        let provider = FakeCleanupProvider()
        provider.batchedResult = .some(nil)
        provider.defaultCleanupSuffix = "!"
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        let result = await coordinator.cleanup(
            "a\nb",
            tone: .casual,
            backtrack: false,
            cleanupEnabled: true
        )

        XCTAssertEqual(result, "a!\nb!")
        XCTAssertEqual(provider.cleanupCallCount, 2)
    }

    func testProviderReturningOriginalForOneLine() async {
        let provider = FakeCleanupProvider()
        provider.batchedResult = .some(nil)
        provider.singleLineMap = [
            "keep me": "keep me",
            "change me": "CHANGED",
        ]
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        let result = await coordinator.cleanup(
            "keep me\nchange me",
            tone: .casual,
            backtrack: false,
            cleanupEnabled: true
        )

        XCTAssertEqual(result, "keep me\nCHANGED")
    }

    func testSingleLineUsesDirectCleanupNotBatch() async {
        let provider = FakeCleanupProvider()
        provider.defaultCleanupSuffix = " ok"
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        let result = await coordinator.cleanup(
            "hello world",
            tone: .casual,
            backtrack: false,
            cleanupEnabled: true
        )

        // Casualize may drop a trailing period but not " ok".
        XCTAssertEqual(result, "hello world ok")
        XCTAssertEqual(provider.cleanupCallCount, 1)
        XCTAssertEqual(provider.batchedCallCount, 0)
    }
}
