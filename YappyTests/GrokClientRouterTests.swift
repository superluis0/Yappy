//
//  GrokClientRouterTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

@MainActor
final class GrokClientRouterTests: XCTestCase {

    private final class CountingGrokClient: GrokAsking {
        var onEvent: (@Sendable (GrokEvent) -> Void)?
        private(set) var askCalls: [GrokAskRequest] = []
        private(set) var cancelCount = 0
        private(set) var stopCount = 0
        var askError: Error?

        func ask(_ request: GrokAskRequest) async throws {
            askCalls.append(request)
            if let askError { throw askError }
        }

        func cancel() { cancelCount += 1 }
        func stop() { stopCount += 1 }
    }

    private enum TestError: Error { case warmFailed }

    func testWarmSuccessDoesNotCallOneShot() async throws {
        let warm = CountingGrokClient()
        let oneShot = CountingGrokClient()
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)
        let request = GrokAskRequest(prompt: "hi", model: "grok")

        try await router.ask(request)

        XCTAssertEqual(warm.askCalls.count, 1)
        XCTAssertEqual(oneShot.askCalls.count, 0)
        XCTAssertEqual(warm.askCalls.first, request)
    }

    func testWarmThrowsFallsBackToOneShot() async throws {
        let warm = CountingGrokClient()
        warm.askError = TestError.warmFailed
        let oneShot = CountingGrokClient()
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)
        let request = GrokAskRequest(prompt: "retry me", model: "grok", effort: "high")

        try await router.ask(request)

        XCTAssertEqual(warm.askCalls.count, 1)
        XCTAssertEqual(oneShot.askCalls.count, 1)
        XCTAssertEqual(oneShot.askCalls.first, request)
    }

    func testWarmAndOneShotBothFailPropagatesError() async {
        let warm = CountingGrokClient()
        warm.askError = TestError.warmFailed
        let oneShot = CountingGrokClient()
        oneShot.askError = TestError.warmFailed
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)

        do {
            try await router.ask(GrokAskRequest(prompt: "x", model: ""))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(warm.askCalls.count, 1)
            XCTAssertEqual(oneShot.askCalls.count, 1)
        }
    }

    func testCancelFansOutToBoth() {
        let warm = CountingGrokClient()
        let oneShot = CountingGrokClient()
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)

        router.cancel()

        XCTAssertEqual(warm.cancelCount, 1)
        XCTAssertEqual(oneShot.cancelCount, 1)
    }

    func testStopFansOutToBoth() {
        let warm = CountingGrokClient()
        let oneShot = CountingGrokClient()
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)

        router.stop()

        XCTAssertEqual(warm.stopCount, 1)
        XCTAssertEqual(oneShot.stopCount, 1)
    }

    func testOnEventIsWiredToBothClients() {
        let warm = CountingGrokClient()
        let oneShot = CountingGrokClient()
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)

        var received: [GrokEvent] = []
        router.onEvent = { received.append($0) }

        warm.onEvent?(.error(message: "warm"))
        oneShot.onEvent?(.error(message: "shot"))

        XCTAssertEqual(received.count, 2)
    }
}
