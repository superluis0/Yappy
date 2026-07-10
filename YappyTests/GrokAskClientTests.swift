//
//  GrokAskClientTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class GrokAskClientTests: XCTestCase {

    func testShouldRetryWhenQuickSilentFailure() {
        XCTAssertTrue(
            GrokAskClient.shouldRetryWithLegacyArgs(
                exitStatus: 1,
                sawAnyEvent: false,
                elapsed: 1.0,
                wasCancelled: false
            )
        )
    }

    func testShouldNotRetryWhenExitStatusZero() {
        XCTAssertFalse(
            GrokAskClient.shouldRetryWithLegacyArgs(
                exitStatus: 0,
                sawAnyEvent: false,
                elapsed: 1.0,
                wasCancelled: false
            )
        )
    }

    func testShouldNotRetryWhenAnyEventWasSeen() {
        XCTAssertFalse(
            GrokAskClient.shouldRetryWithLegacyArgs(
                exitStatus: 1,
                sawAnyEvent: true,
                elapsed: 1.0,
                wasCancelled: false
            )
        )
    }

    func testShouldNotRetryWhenElapsedAtOrAboveFiveSeconds() {
        XCTAssertFalse(
            GrokAskClient.shouldRetryWithLegacyArgs(
                exitStatus: 1,
                sawAnyEvent: false,
                elapsed: 5.0,
                wasCancelled: false
            )
        )
        XCTAssertFalse(
            GrokAskClient.shouldRetryWithLegacyArgs(
                exitStatus: 1,
                sawAnyEvent: false,
                elapsed: 12.0,
                wasCancelled: false
            )
        )
    }

    func testShouldNotRetryWhenCancelled() {
        XCTAssertFalse(
            GrokAskClient.shouldRetryWithLegacyArgs(
                exitStatus: 1,
                sawAnyEvent: false,
                elapsed: 0.5,
                wasCancelled: true
            )
        )
    }

    func testShouldRetryJustUnderElapsedThreshold() {
        XCTAssertTrue(
            GrokAskClient.shouldRetryWithLegacyArgs(
                exitStatus: 2,
                sawAnyEvent: false,
                elapsed: 4.999,
                wasCancelled: false
            )
        )
    }
}
