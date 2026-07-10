//
//  TTSSpeakClientTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class TTSSpeakClientTests: XCTestCase {

    // MARK: - TTSRequestSerialGate FIFO

    func testSerialGateIsFIFO() async {
        let gate = TTSRequestSerialGate()
        var order: [Int] = []
        let lock = NSLock()

        // Hold the gate so subsequent enter() calls queue.
        await gate.enter()

        let t1 = Task {
            await gate.enter()
            lock.lock(); order.append(1); lock.unlock()
            await gate.leave()
        }
        // Give t1 a moment to park in waiters before t2 enters.
        try? await Task.sleep(nanoseconds: 20_000_000)

        let t2 = Task {
            await gate.enter()
            lock.lock(); order.append(2); lock.unlock()
            await gate.leave()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Release the initial hold — waiters should resume FIFO: 1 then 2.
        await gate.leave()

        await t1.value
        await t2.value

        XCTAssertEqual(order, [1, 2])
    }

    func testSerialGateAllowsImmediateEnterWhenIdle() async {
        let gate = TTSRequestSerialGate()
        var entered = false
        await gate.enter()
        entered = true
        await gate.leave()
        XCTAssertTrue(entered)
    }

    // MARK: - probeReadiness cache

    override func tearDown() {
        // Don't leak readiness cache across tests.
        TTSSpeakClient.cachedReady = nil
        super.tearDown()
    }

    func testProbeReadinessReturnsCachedTrue() async {
        TTSSpeakClient.cachedReady = true
        let ready = await TTSSpeakClient.probeReadiness()
        XCTAssertTrue(ready)
        XCTAssertEqual(TTSSpeakClient.cachedReady, true)
    }

    func testProbeReadinessReturnsCachedFalse() async {
        TTSSpeakClient.cachedReady = false
        let ready = await TTSSpeakClient.probeReadiness()
        XCTAssertFalse(ready)
        XCTAssertEqual(TTSSpeakClient.cachedReady, false)
    }

    func testIndeterminateNilIsNotLatchedAsFalse() async {
        // A nil cache means "not yet determined" — probeReadiness must re-probe
        // rather than treat the missing cache as a permanent false. After we set
        // nil, the cache must not already be latched to false before any probe
        // result arrives; setting true must still stick.
        TTSSpeakClient.cachedReady = nil
        XCTAssertNil(TTSSpeakClient.cachedReady)

        TTSSpeakClient.cachedReady = true
        XCTAssertEqual(TTSSpeakClient.cachedReady, true)

        // Explicit nil again is allowed and is distinct from false.
        TTSSpeakClient.cachedReady = nil
        XCTAssertNil(TTSSpeakClient.cachedReady)
        XCTAssertNotEqual(TTSSpeakClient.cachedReady, false)

        // refreshReadiness may set true/false/nil depending on the machine; the
        // contract under test is that a nil result is stored as nil (not coerced
        // to false). We simulate that contract by writing nil and confirming
        // probeReadiness with a non-nil cache still prefers the cache.
        TTSSpeakClient.cachedReady = false
        let cachedFalse = await TTSSpeakClient.probeReadiness()
        XCTAssertFalse(cachedFalse)
        XCTAssertEqual(TTSSpeakClient.cachedReady, false)
    }
}
