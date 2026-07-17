//
//  HotkeyStateMachineTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class HotkeyStateMachineTests: XCTestCase {

    // MARK: - Hold Mode

    func testHoldStartsOnDownAndStopsOnUp() {
        var machine = HotkeyStateMachine(mode: .rightCommandHold)
        XCTAssertEqual(machine.handle(.down, at: 0.0), .start)
        XCTAssertTrue(machine.isActive)
        XCTAssertEqual(machine.handle(.up, at: 1.0), .stop)
        XCTAssertFalse(machine.isActive)
    }

    func testHoldShorterThanMinimumCancels() {
        var machine = HotkeyStateMachine(mode: .rightCommandHold)
        XCTAssertEqual(machine.handle(.down, at: 0.0), .start)
        XCTAssertEqual(machine.handle(.up, at: 0.05), .cancel)
        XCTAssertFalse(machine.isActive)
    }

    func testHoldIgnoresRepeatedDownEdges() {
        var machine = HotkeyStateMachine(mode: .rightCommandHold)
        XCTAssertEqual(machine.handle(.down, at: 0.0), .start)
        XCTAssertEqual(machine.handle(.down, at: 0.1), .none, "Key repeat must not retrigger")
        XCTAssertEqual(machine.handle(.down, at: 0.2), .none)
        XCTAssertEqual(machine.handle(.up, at: 1.0), .stop)
    }

    func testHoldDebouncesBouncyDownAfterUp() {
        var machine = HotkeyStateMachine(mode: .rightCommandHold)
        XCTAssertEqual(machine.handle(.down, at: 0.0), .start)
        XCTAssertEqual(machine.handle(.up, at: 1.0), .stop)
        // A down edge within the debounce window of the up is a misfire.
        XCTAssertEqual(machine.handle(.down, at: 1.0 + Constants.hotkeyDebounceInterval / 2), .none)
        // A later one is legitimate.
        XCTAssertEqual(machine.handle(.down, at: 2.0), .start)
    }

    func testHoldUpWithoutDownDoesNothing() {
        var machine = HotkeyStateMachine(mode: .rightCommandHold)
        XCTAssertEqual(machine.handle(.up, at: 0.0), .none)
    }

    func testRightOptionHoldBehavesLikeCommandHold() {
        var machine = HotkeyStateMachine(mode: .rightOptionHold)
        XCTAssertEqual(machine.handle(.down, at: 0.0), .start)
        XCTAssertEqual(machine.handle(.up, at: 0.5), .stop)
    }

    func testRightControlHoldBehavesLikeCommandHold() {
        var machine = HotkeyStateMachine(mode: .rightControlHold)
        XCTAssertEqual(machine.handle(.down, at: 0.0), .start)
        XCTAssertEqual(machine.handle(.up, at: 0.5), .stop)
        // A press shorter than the minimum is treated as an accidental tap.
        var quick = HotkeyStateMachine(mode: .rightControlHold)
        XCTAssertEqual(quick.handle(.down, at: 0.0), .start)
        XCTAssertEqual(quick.handle(.up, at: 0.01), .cancel)
    }

    // MARK: - Double-Tap Mode

    private func tap(_ machine: inout HotkeyStateMachine, at time: TimeInterval,
                     duration: TimeInterval = 0.1) -> HotkeyStateMachine.Action {
        _ = machine.handle(.down, at: time)
        return machine.handle(.up, at: time + duration)
    }

    func testDoubleTapStarts() {
        var machine = HotkeyStateMachine(mode: .rightCommandDoubleTap)
        XCTAssertEqual(tap(&machine, at: 0.0), .none, "First tap arms the double tap")
        XCTAssertEqual(tap(&machine, at: 0.3), .start, "Second tap inside the window starts")
        XCTAssertTrue(machine.isActive)
    }

    func testSingleTapWhileActiveStops() {
        var machine = HotkeyStateMachine(mode: .rightCommandDoubleTap)
        _ = tap(&machine, at: 0.0)
        _ = tap(&machine, at: 0.3)
        XCTAssertEqual(tap(&machine, at: 5.0), .stop)
        XCTAssertFalse(machine.isActive)
    }

    func testSlowTapsDoNotStart() {
        var machine = HotkeyStateMachine(mode: .rightCommandDoubleTap)
        XCTAssertEqual(tap(&machine, at: 0.0), .none)
        XCTAssertEqual(tap(&machine, at: 0.0 + Constants.doubleTapWindow + 0.5), .none,
                       "Taps outside the double-tap window must not start")
    }

    func testLongPressIsNotATap() {
        var machine = HotkeyStateMachine(mode: .rightCommandDoubleTap)
        XCTAssertEqual(tap(&machine, at: 0.0), .none)
        XCTAssertEqual(tap(&machine, at: 0.3, duration: Constants.tapMaxDuration + 0.3), .none,
                       "A held press doesn't complete a double tap")
    }

    func testDeactivateClearsActiveSession() {
        var machine = HotkeyStateMachine(mode: .rightCommandHold)
        _ = machine.handle(.down, at: 0.0)
        XCTAssertTrue(machine.isActive)
        machine.deactivate()
        XCTAssertFalse(machine.isActive)
    }

    // MARK: - Double-Tap-Lock Activation (orthogonal to key)

    /// The three "Hold" presets, exercised under the NEW `.doubleTapLock`
    /// ACTIVATION — proving activation composes with any key, not just the
    /// legacy `.rightCommandDoubleTap` preset (covered above).
    private static let holdPresetKeys: [HotkeyOption] = [.rightCommandHold, .rightOptionHold, .rightControlHold]

    func testDoubleTapLockStartsForEveryKeyPreset() {
        for key in Self.holdPresetKeys {
            var machine = HotkeyStateMachine(mode: key, activation: .doubleTapLock)
            XCTAssertEqual(tap(&machine, at: 0.0), .none, "\(key): first tap arms the double tap")
            XCTAssertEqual(tap(&machine, at: 0.3), .start, "\(key): second tap inside the window starts")
            XCTAssertTrue(machine.isActive, "\(key)")
        }
    }

    func testDoubleTapLockSingleTapWhileActiveStopsForEveryKeyPreset() {
        for key in Self.holdPresetKeys {
            var machine = HotkeyStateMachine(mode: key, activation: .doubleTapLock)
            _ = tap(&machine, at: 0.0)
            _ = tap(&machine, at: 0.3)
            XCTAssertEqual(tap(&machine, at: 5.0), .stop, "\(key)")
            XCTAssertFalse(machine.isActive, "\(key)")
        }
    }

    func testDoubleTapLockSlowTapsDoNotStartForEveryKeyPreset() {
        for key in Self.holdPresetKeys {
            var machine = HotkeyStateMachine(mode: key, activation: .doubleTapLock)
            XCTAssertEqual(tap(&machine, at: 0.0), .none, "\(key)")
            XCTAssertEqual(tap(&machine, at: 0.0 + Constants.doubleTapWindow + 0.5), .none,
                           "\(key): taps outside the double-tap window must not start")
        }
    }

    func testDoubleTapLockLongPressIsNotATapForEveryKeyPreset() {
        for key in Self.holdPresetKeys {
            var machine = HotkeyStateMachine(mode: key, activation: .doubleTapLock)
            XCTAssertEqual(tap(&machine, at: 0.0), .none, "\(key)")
            XCTAssertEqual(tap(&machine, at: 0.3, duration: Constants.tapMaxDuration + 0.3), .none,
                           "\(key): a held press doesn't complete a double tap")
        }
    }

    /// Esc-cancel lives above the state machine (`AppDelegate.escapeCancel`
    /// calls `deactivate()`, then cancels the recording) — this is the
    /// machine-level contract that path depends on: `deactivate()` must clear
    /// an active LOCKED session exactly like it already does for a held one.
    /// (The OTHER force-stop, `AppDelegate.armMaxDurationTimer`'s wall-clock
    /// safety timeout, also bottoms out in this same `deactivate()` call and
    /// never inspects mode/activation, so it's covered by the same guarantee.)
    func testDoubleTapLockDeactivateClearsActiveSessionForEveryKeyPreset() {
        for key in Self.holdPresetKeys {
            var machine = HotkeyStateMachine(mode: key, activation: .doubleTapLock)
            _ = tap(&machine, at: 0.0)
            _ = tap(&machine, at: 0.3)
            XCTAssertTrue(machine.isActive, "\(key)")
            machine.deactivate()
            XCTAssertFalse(machine.isActive, "\(key): deactivate() must stop a locked recording same as a held one")
        }
    }

    func testLegacyDoubleTapPresetBehavesLikeRightCommandHoldPlusDoubleTapLock() {
        // `HotkeyStateMachine(mode: .rightCommandDoubleTap)` (the pre-existing
        // call shape, no activation argument) must keep behaving exactly like
        // the new orthogonal (key: .rightCommandHold, activation: .doubleTapLock).
        var legacy = HotkeyStateMachine(mode: .rightCommandDoubleTap)
        var explicit = HotkeyStateMachine(mode: .rightCommandHold, activation: .doubleTapLock)
        XCTAssertEqual(tap(&legacy, at: 0.0), tap(&explicit, at: 0.0))
        XCTAssertEqual(tap(&legacy, at: 0.3), tap(&explicit, at: 0.3))
        XCTAssertEqual(legacy.isActive, explicit.isActive)
    }

    func testLegacyDoubleTapPresetIgnoresExplicitHoldToTalkActivationArgument() {
        // A pre-migration persisted `.rightCommandDoubleTap` must keep its
        // double-tap behavior even if somehow constructed with an explicit
        // `.holdToTalk` activation — the legacy preset always wins.
        var machine = HotkeyStateMachine(mode: .rightCommandDoubleTap, activation: .holdToTalk)
        XCTAssertEqual(machine.activation, .doubleTapLock)
        XCTAssertEqual(tap(&machine, at: 0.0), .none, "First tap arms the double tap, not a hold-start")
        XCTAssertEqual(tap(&machine, at: 0.3), .start)
    }
}
