//
//  AskHotkeyStateMachineTests.swift
//  YappyTests
//

import CoreGraphics
import XCTest
@testable import Yappy

final class AskHotkeyStateMachineTests: XCTestCase {
    func testHoldStartsAndReleaseStops() {
        var machine = AskHotkeyStateMachine()

        XCTAssertEqual(machine.handle(.down, at: 1.0), .start)
        XCTAssertEqual(machine.handle(.up, at: 1.5), .stop)
    }

    func testDebouncesRepeatedDownEvents() {
        var machine = AskHotkeyStateMachine()

        XCTAssertEqual(machine.handle(.down, at: 1.0), .start)
        XCTAssertEqual(machine.handle(.down, at: 1.01), .none)
    }

    func testReleaseWithoutHoldIsNoOp() {
        var machine = AskHotkeyStateMachine()
        XCTAssertEqual(machine.handle(.up, at: 1.0), .none)
    }

    func testDeactivateCancelsActiveSession() {
        var machine = AskHotkeyStateMachine()
        _ = machine.handle(.down, at: 1.0)

        XCTAssertEqual(machine.deactivate(), .cancel)
        XCTAssertEqual(machine.handle(.up, at: 1.2), .none)
    }

    func testDebounceHonoredAfterRelease() {
        var machine = AskHotkeyStateMachine(debounceInterval: 0.1)
        XCTAssertEqual(machine.handle(.down, at: 1.0), .start)
        XCTAssertEqual(machine.handle(.up, at: 1.2), .stop)
        // A bounce within the debounce window after release is swallowed.
        XCTAssertEqual(machine.handle(.down, at: 1.25), .none)
        // A genuine later press starts again.
        XCTAssertEqual(machine.handle(.down, at: 1.5), .start)
    }
}

// MARK: - AskHotkeyOption (key matching + collision rules)

final class AskHotkeyOptionTests: XCTestCase {
    // Raw flag bits as macOS reports them: the generic mask plus the IOKit
    // device-dependent right-side bit.
    private let fnFlags = CGEventFlags.maskSecondaryFn
    private let rightControlFlags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0000_2000)
    private let rightShiftFlags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x0000_0004)
    private let rightOptionFlags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x0000_0040)

    func testEachOptionMatchesItsOwnKeyDownAndUp() {
        let cases: [(AskHotkeyOption, Int64, CGEventFlags)] = [
            (.fnGlobe, 63, fnFlags),
            (.rightControl, 62, rightControlFlags),
            (.rightShift, 60, rightShiftFlags),
            (.rightOption, 61, rightOptionFlags),
        ]
        for (option, keycode, downFlags) in cases {
            XCTAssertEqual(option.downState(keycode: keycode, flags: downFlags), true,
                           "\(option) down")
            XCTAssertEqual(option.downState(keycode: keycode, flags: []), false,
                           "\(option) up")
        }
    }

    func testOtherKeycodesAreIgnored() {
        // A Right Command press (keycode 54) must not register for any option.
        for option in AskHotkeyOption.allCases {
            XCTAssertNil(option.downState(keycode: 54, flags: CGEventFlags.maskCommand),
                         "\(option) must ignore foreign keycodes")
        }
    }

    func testLeftSideKeyHeldDoesNotMaskRightKeyRelease() {
        // Release of Right Control while LEFT Control stays held: the event
        // carries keycode 62 with the generic control mask still set but the
        // right-side device bit cleared. That must read as UP.
        let leftStillHeld = CGEventFlags.maskControl
        XCTAssertEqual(AskHotkeyOption.rightControl.downState(keycode: 62, flags: leftStillHeld), false)
    }

    func testFnRequiresSecondaryFnMask() {
        // Keycode 63 without the mask (release edge) reads as up.
        XCTAssertEqual(AskHotkeyOption.fnGlobe.downState(keycode: 63, flags: []), false)
    }

    // MARK: Collision rules

    func testFnAndRightShiftNeverConflict() {
        for dictation in HotkeyOption.allCases {
            for voiceEdit in [false, true] {
                XCTAssertNil(AskHotkeyOption.fnGlobe.conflict(dictation: dictation, voiceEditEnabled: voiceEdit))
                XCTAssertNil(AskHotkeyOption.rightShift.conflict(dictation: dictation, voiceEditEnabled: voiceEdit))
            }
        }
    }

    func testRightControlConflictsOnlyWithRightControlDictation() {
        XCTAssertNotNil(AskHotkeyOption.rightControl.conflict(dictation: .rightControlHold, voiceEditEnabled: false))
        XCTAssertNil(AskHotkeyOption.rightControl.conflict(dictation: .rightCommandHold, voiceEditEnabled: true))
    }

    func testRightOptionConflictsWithDictationAndVoiceEdit() {
        XCTAssertNotNil(AskHotkeyOption.rightOption.conflict(dictation: .rightOptionHold, voiceEditEnabled: false))
        XCTAssertNotNil(AskHotkeyOption.rightOption.conflict(dictation: .rightCommandHold, voiceEditEnabled: true),
                        "Voice Edit owns Right Option while enabled")
        XCTAssertNil(AskHotkeyOption.rightOption.conflict(dictation: .rightCommandHold, voiceEditEnabled: false))
    }
}
