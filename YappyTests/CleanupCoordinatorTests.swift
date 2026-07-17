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
    /// Intensities observed on single-line cleanup calls (order-preserving).
    private(set) var lastIntensities: [CleanupIntensity] = []
    /// Intensities observed on batched cleanup calls.
    private(set) var lastBatchedIntensities: [CleanupIntensity] = []

    func isAvailable() async -> Bool { true }

    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool, intensity: CleanupIntensity) async -> String {
        cleanupCallCount += 1
        lastIntensities.append(intensity)
        if let mapped = singleLineMap[text] { return mapped }
        return text + defaultCleanupSuffix
    }

    func cleanupBatched(lines: [String], tone: ToneStyle, backtrack: Bool, intensity: CleanupIntensity) async -> [String]? {
        batchedCallCount += 1
        lastBatchedIntensities.append(intensity)
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
            "hello wonderful wide world",
            tone: .casual,
            backtrack: false,
            cleanupEnabled: true
        )

        // Casualize may drop a trailing period but not " ok".
        XCTAssertEqual(result, "hello wonderful wide world ok")
        XCTAssertEqual(provider.cleanupCallCount, 1)
        XCTAssertEqual(provider.batchedCallCount, 0)
    }

    // MARK: - Intensity routing

    func testIntensityStandardPassedToProvider() async {
        settings.cleanupIntensity = .standard
        let provider = FakeCleanupProvider()
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        // Long enough that the trivial-utterance skip gate never fires — the
        // intensity assertion needs the provider round-trip to happen.
        _ = await coordinator.cleanup(
            "so i was thinking we should probably meet tomorrow afternoon",
            tone: .casual, backtrack: false, cleanupEnabled: true
        )

        XCTAssertEqual(provider.lastIntensities, [.standard])
    }

    func testIntensityConservativePassedToProvider() async {
        settings.cleanupIntensity = .conservative
        let provider = FakeCleanupProvider()
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        // Long enough that the trivial-utterance skip gate never fires — the
        // intensity assertion needs the provider round-trip to happen.
        _ = await coordinator.cleanup(
            "so i was thinking we should probably meet tomorrow afternoon",
            tone: .casual, backtrack: false, cleanupEnabled: true
        )

        XCTAssertEqual(provider.lastIntensities, [.conservative])
    }

    func testIntensityOverrideIgnoresSettings() async {
        settings.cleanupIntensity = .standard
        let provider = FakeCleanupProvider()
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        _ = await coordinator.cleanup(
            "so i was thinking we should probably meet tomorrow afternoon",
            tone: .casual, backtrack: false, cleanupEnabled: true,
            intensity: .conservative
        )

        XCTAssertEqual(provider.lastIntensities, [.conservative])
    }

    // MARK: - Skip-path sentence casing (rubric parity: short-01/02, num-03)

    func testSkippedUtterancesMatchTheEvalGold() async {
        let coordinator = CleanupCoordinator(settings: settings, provider: nil)
        // The three <=3-word rubric cases the skip gate now owns: their gold
        // outputs are exactly capitalize + terminal period.
        for (input, gold) in [
            ("sounds good", "Sounds good."),
            ("no", "No."),
            ("word count", "Word count."),
        ] {
            let out = await coordinator.cleanup(
                input, tone: .formal, backtrack: false, cleanupEnabled: true
            )
            XCTAssertEqual(out, gold)
        }
    }

    func testSentenceCasedRespectsExistingPunctuationAndCase() {
        XCTAssertEqual(CleanupCoordinator.sentenceCased("Done!"), "Done!")
        XCTAssertEqual(CleanupCoordinator.sentenceCased("OK"), "OK.")
        XCTAssertEqual(CleanupCoordinator.sentenceCased("  yes  "), "Yes.")
        XCTAssertEqual(CleanupCoordinator.sentenceCased(""), "")
    }

    // MARK: - Diff caption decision

    func testDiffCaptionWhenCleanupChangedText() {
        XCTAssertTrue(CleanupCoordinator.shouldShowDiffCaption(
            raw: "hello world",
            final: "Hello world.",
            cleanupRan: true,
            captionEnabled: true
        ))
    }

    func testDiffCaptionPunctuationOnlyStillCounts() {
        // Spec: simple inequality after trim — punctuation-only still counts.
        XCTAssertTrue(CleanupCoordinator.shouldShowDiffCaption(
            raw: "hello",
            final: "hello.",
            cleanupRan: true,
            captionEnabled: true
        ))
    }

    func testDiffCaptionNeverWhenCleanupSkipped() {
        XCTAssertFalse(CleanupCoordinator.shouldShowDiffCaption(
            raw: "hello",
            final: "Hello.",
            cleanupRan: false,
            captionEnabled: true
        ))
    }

    func testDiffCaptionNeverWhenDisabled() {
        XCTAssertFalse(CleanupCoordinator.shouldShowDiffCaption(
            raw: "hello",
            final: "Hello.",
            cleanupRan: true,
            captionEnabled: false
        ))
    }

    func testDiffCaptionNeverWhenIdenticalAfterTrim() {
        XCTAssertFalse(CleanupCoordinator.shouldShowDiffCaption(
            raw: "  Hello.  ",
            final: "Hello.",
            cleanupRan: true,
            captionEnabled: true
        ))
    }

    func testShouldSkipModelCleanupConservativeTable() {
        struct Case {
            let text: String
            let tone: ToneStyle
            let backtrack: Bool
            let expected: Bool
        }
        let cases: [Case] = [
            .init(text: "hello", tone: .casual, backtrack: true, expected: true),
            .init(text: "thanks so much", tone: .formal, backtrack: true, expected: true),
            .init(text: "delete that", tone: .casual, backtrack: true, expected: false),
            .init(text: "no wait Tuesday", tone: .casual, backtrack: true, expected: false),
            .init(text: "is that okay?", tone: .casual, backtrack: true, expected: false),
            .init(text: "- first item", tone: .casual, backtrack: true, expected: false),
            .init(text: "1. first item", tone: .casual, backtrack: true, expected: false),
            .init(text: "one two three four", tone: .casual, backtrack: true, expected: false),
            .init(text: "hello world", tone: .verbatim, backtrack: true, expected: false),
            .init(text: "", tone: .casual, backtrack: true, expected: false),
        ]

        for item in cases {
            XCTAssertEqual(
                CleanupCoordinator.shouldSkipModelCleanup(
                    text: item.text, tone: item.tone, backtrack: item.backtrack
                ),
                item.expected,
                "unexpected gate result for \(item.text)"
            )
        }
    }

    func testSkippedCleanupStillAppliesToneWithoutProviderCall() async {
        let provider = FakeCleanupProvider()
        let coordinator = CleanupCoordinator(settings: settings, provider: provider)

        let result = await coordinator.cleanup(
            "don't wait", tone: .formal, backtrack: true, cleanupEnabled: true
        )

        XCTAssertEqual(result, "Do not wait.")
        XCTAssertEqual(provider.cleanupCallCount, 0)
        XCTAssertEqual(provider.batchedCallCount, 0)
    }

    func testSkippedCleanupAppliesToneEvenWithoutProvider() async {
        let coordinator = CleanupCoordinator(settings: settings)
        let result = await coordinator.cleanup(
            "don't wait", tone: .formal, backtrack: true, cleanupEnabled: true
        )
        XCTAssertEqual(result, "Do not wait.")
    }
}
