//
//  LMStudioPromptTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

/// The networked parts of LMStudioService can't run in unit tests, but the
/// system-prompt assembly is pure and worth pinning down.
final class LMStudioPromptTests: XCTestCase {

    func testBacktrackClausePresentWhenEnabled() {
        let prompt = LMStudioService.cleanupPrompt(tone: .formal, backtrack: true)
        XCTAssertTrue(prompt.lowercased().contains("actually"),
                      "Backtrack guidance should be included when enabled")
        XCTAssertTrue(prompt.lowercased().contains("correct"))
    }

    func testBacktrackClauseAbsentWhenDisabled() {
        let prompt = LMStudioService.cleanupPrompt(tone: .formal, backtrack: false)
        XCTAssertFalse(prompt.lowercased().contains("actually"),
                       "Backtrack guidance should be omitted when disabled")
    }

    func testToneGuidanceAlwaysIncluded() {
        let prompt = LMStudioService.cleanupPrompt(tone: .casual, backtrack: false)
        XCTAssertTrue(prompt.contains(ToneStyle.casual.promptGuidance))
    }

    func testCleanupPromptPinsUSEnglishSpelling() {
        // Without this, the local model intermittently "corrects" US spelling to
        // British (favorite → favourite). The clause must be present for every tone.
        for tone in [ToneStyle.formal, .casual, .excited] {
            let prompt = LMStudioService.cleanupPrompt(tone: tone, backtrack: false).lowercased()
            XCTAssertTrue(prompt.contains("american") && prompt.contains("spelling"),
                          "Cleanup prompt should pin US English spelling (tone: \(tone))")
        }
    }
}
