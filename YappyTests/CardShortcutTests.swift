//
//  CardShortcutTests.swift
//  YappyTests
//

import CoreGraphics
import XCTest
@testable import Yappy

/// The floating cards' panels must never take keyboard focus (a key
/// nonactivating panel eats the synthetic ⌘V that Replace/Insert depend on), so
/// their chords are matched off a session-wide CGEvent tap instead. That tap
/// sees EVERY keystroke in the session: anything this matcher claims is a key
/// the frontmost app never gets, so the modifier rule is tested tightly.
///
/// Matching is by CHARACTER, not virtual keycode: the tap resolves the pressed
/// key through the user's current layout (`baseCharacter(for:)`), so Dvorak and
/// Colemak users press the key labeled I/C/S/R/T/X rather than whatever sits at
/// the ANSI position. The layout translation itself is untestable here (it
/// depends on the host's active input source); the pure matcher is what's pinned.
final class CardShortcutTests: XCTestCase {

    private let commandOption: CGEventFlags = [.maskCommand, .maskAlternate]

    func testMatchesEveryCardChord() {
        for shortcut in CardShortcut.allCases {
            XCTAssertEqual(
                CardShortcut.match(character: shortcut.letter, flags: commandOption),
                shortcut,
                "\(shortcut.rawValue) should match its own letter"
            )
        }
    }

    /// The tap reports whatever case the layout produces; ⌘⌥ with Caps Lock can
    /// arrive uppercase and must still match.
    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(CardShortcut.match(character: "I", flags: commandOption), .insert)
        XCTAssertEqual(CardShortcut.match(character: "X", flags: commandOption), .dismiss)
    }

    func testChordLettersAreUnique() {
        let letters = CardShortcut.allCases.map(\.letter)
        XCTAssertEqual(Set(letters).count, letters.count)
    }

    /// ⌘⌥D is the SYSTEM Show/Hide Dock shortcut — the dismiss chord moved to X
    /// so a visible card never swallows a global macOS command. Pinned so a
    /// future re-lettering has to consciously step around it.
    func testNoChordUsesTheDockToggleLetter() {
        XCTAssertFalse(CardShortcut.allCases.contains { $0.letter == "d" })
        XCTAssertEqual(CardShortcut.dismiss.letter, "x")
    }

    func testIgnoresKeysWithoutBothModifiers() {
        XCTAssertNil(CardShortcut.match(character: "i", flags: []))
        XCTAssertNil(CardShortcut.match(character: "i", flags: [.maskCommand]))
        XCTAssertNil(CardShortcut.match(character: "i", flags: [.maskAlternate]))
    }

    /// ⌘⌥⇧I and ⌘⌥⌃I belong to whatever app is frontmost — claiming them would
    /// silently break the user's own shortcuts while a card lingers.
    func testIgnoresExtraModifiers() {
        XCTAssertNil(CardShortcut.match(character: "i", flags: [.maskCommand, .maskAlternate, .maskShift]))
        XCTAssertNil(CardShortcut.match(character: "i", flags: [.maskCommand, .maskAlternate, .maskControl]))
    }

    /// Caps Lock / numeric-keypad bits ride along on ordinary keystrokes and
    /// must not stop a chord from matching.
    func testIgnoresIrrelevantModifierBits() {
        XCTAssertEqual(
            CardShortcut.match(
                character: "c",
                flags: [.maskCommand, .maskAlternate, .maskAlphaShift, .maskNumericPad]
            ),
            .copy
        )
    }

    func testIgnoresUnboundKeys() {
        // Escape stays with EscapeInterceptor — two head-inserted taps racing
        // for one key would make the winner undefined. An untranslatable key
        // arrives as nil and must never match.
        XCTAssertNil(CardShortcut.match(character: "e", flags: commandOption))
        XCTAssertNil(CardShortcut.match(character: " ", flags: commandOption))
        XCTAssertNil(CardShortcut.match(character: nil, flags: commandOption))
    }

    func testEveryChordHasADistinctSpokenAndDisplayedForm() {
        let spoken = CardShortcut.allCases.map(\.spokenShortcut)
        let displayed = CardShortcut.allCases.map(\.displayShortcut)
        XCTAssertEqual(Set(spoken).count, spoken.count)
        XCTAssertEqual(Set(displayed).count, displayed.count)
        XCTAssertEqual(CardShortcut.insert.displayShortcut, "⌘⌥I")
        XCTAssertEqual(CardShortcut.insert.spokenShortcut, "Command Option I")
        XCTAssertEqual(CardShortcut.dismiss.displayShortcut, "⌘⌥X")
    }
}

/// The Answers card lives in a panel that never takes focus, so VoiceOver only
/// hears about a run through these announcements.
final class AskRunStatusAnnouncementTests: XCTestCase {

    func testEveryWorkingStateAnnouncesSomething() {
        for status in [AskRunStatus.preparing, .listening, .transcribing, .thinking, .working] {
            XCTAssertNotNil(status.accessibilityAnnouncement, status.rawValue)
        }
    }

    func testTerminalFailuresAnnounce() {
        XCTAssertEqual(AskRunStatus.failed.accessibilityAnnouncement, "Answer failed")
        XCTAssertEqual(AskRunStatus.cancelled.accessibilityAnnouncement, "Answer cancelled")
    }

    /// AskController already posts "Answer ready" on completion; a second
    /// announcement here would talk over it.
    func testCompletedAndIdleStaySilent() {
        XCTAssertNil(AskRunStatus.completed.accessibilityAnnouncement)
        XCTAssertNil(AskRunStatus.idle.accessibilityAnnouncement)
    }

    func testAnnouncementsAreDistinct() {
        let spoken = AskRunStatus.allAnnouncements
        XCTAssertEqual(Set(spoken).count, spoken.count)
    }
}

private extension AskRunStatus {
    static var allAnnouncements: [String] {
        [AskRunStatus.preparing, .listening, .transcribing, .thinking, .working, .failed, .cancelled]
            .compactMap(\.accessibilityAnnouncement)
    }
}
