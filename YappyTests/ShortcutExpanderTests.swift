//
//  ShortcutExpanderTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class ShortcutExpanderTests: XCTestCase {

    private func expander(_ shortcuts: [VoiceShortcut]) -> ShortcutExpander {
        ShortcutExpander(shortcuts: shortcuts)
    }

    func testWholeUtteranceReplacement() {
        let exp = expander([VoiceShortcut(trigger: "my email", expansion: "me@example.com")])
        XCTAssertEqual(exp.expand("my email"), "me@example.com")
    }

    func testWholeUtteranceIgnoresCaseAndTrailingPunctuation() {
        let exp = expander([VoiceShortcut(trigger: "my email", expansion: "me@example.com")])
        XCTAssertEqual(exp.expand("My email."), "me@example.com")
        XCTAssertEqual(exp.expand("  MY EMAIL!  "), "me@example.com")
    }

    func testInlineReplacement() {
        let exp = expander([VoiceShortcut(trigger: "my email", expansion: "me@example.com")])
        XCTAssertEqual(exp.expand("Reach me at my email please"),
                       "Reach me at me@example.com please")
    }

    func testInlineRespectsWordBoundaries() {
        let exp = expander([VoiceShortcut(trigger: "cal", expansion: "calendly.com/me")])
        // Should not replace the "cal" inside "calendar".
        XCTAssertEqual(exp.expand("check my calendar"), "check my calendar")
        XCTAssertEqual(exp.expand("send a cal link"), "send a calendly.com/me link")
    }

    func testDisabledShortcutIgnored() {
        let exp = expander([VoiceShortcut(trigger: "my email", expansion: "x", enabled: false)])
        XCTAssertEqual(exp.expand("my email"), "my email")
    }

    func testEmptyTriggerIgnored() {
        let exp = expander([VoiceShortcut(trigger: "   ", expansion: "x")])
        XCTAssertEqual(exp.expand("hello"), "hello")
    }

    func testNoShortcutsReturnsInput() {
        let exp = expander([])
        XCTAssertEqual(exp.expand("unchanged text"), "unchanged text")
    }

    func testMultipleInlineShortcuts() {
        let exp = expander([
            VoiceShortcut(trigger: "my email", expansion: "me@example.com"),
            VoiceShortcut(trigger: "my site", expansion: "example.com"),
        ])
        XCTAssertEqual(exp.expand("see my site or my email"),
                       "see example.com or me@example.com")
    }
}
