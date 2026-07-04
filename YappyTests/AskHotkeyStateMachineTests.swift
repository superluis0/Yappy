//
//  AskHotkeyStateMachineTests.swift
//  YappyTests
//

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
