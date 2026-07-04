//
//  GrokEventTests.swift
//  YappyTests
//
//  Written against the REAL `--output-format streaming-json` wire format
//  captured from grok 0.2.82 during a live headless turn.
//

import XCTest
@testable import Yappy

final class GrokEventTests: XCTestCase {
    func testParsesThoughtDelta() {
        XCTAssertEqual(
            GrokEvent.parse(line: #"{"type": "thought", "data": "The"}"#),
            .thought(delta: "The")
        )
    }

    func testParsesTextDelta() {
        XCTAssertEqual(
            GrokEvent.parse(line: #"{"type": "text", "data": "Searching"}"#),
            .text(delta: "Searching")
        )
    }

    func testParsesEndWithStopReason() {
        XCTAssertEqual(
            GrokEvent.parse(line: #"{"type": "end", "stopReason": "EndTurn", "sessionId": "019f249a", "requestId": "495e7da7"}"#),
            .end(stopReason: "EndTurn", sessionId: "019f249a")
        )
    }

    func testParsesErrorEvent() {
        XCTAssertEqual(
            GrokEvent.parse(line: #"{"type": "error", "message": "rate limited"}"#),
            .error(message: "rate limited")
        )
    }

    func testUnknownTypeIsIgnoredNotMangled() {
        XCTAssertEqual(
            GrokEvent.parse(line: #"{"type": "toolUse", "id": "tu_123", "name": "web_search"}"#),
            .ignored(type: "toolUse")
        )
    }

    func testBlankAndNonJSONLinesAreNil() {
        XCTAssertNil(GrokEvent.parse(line: ""))
        XCTAssertNil(GrokEvent.parse(line: "   "))
        XCTAssertNil(GrokEvent.parse(line: "not json"))
        XCTAssertNil(GrokEvent.parse(line: #"{"no_type": true}"#))
    }

    // MARK: - fromSessionUpdate (grok agent stdio notifications)

    private func parseNotification(_ json: String) -> GrokEvent? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return nil
        }
        return GrokEvent.fromSessionUpdate(
            method: method,
            params: object["params"] as? [String: Any] ?? [:]
        )
    }

    func testFromSessionUpdateThoughtChunk() {
        XCTAssertEqual(
            parseNotification(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"S","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user is asking..."}}}}"#),
            .thought(delta: "The user is asking...")
        )
    }

    func testFromSessionUpdateMessageChunk() {
        XCTAssertEqual(
            parseNotification(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"S","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"OK"}}}}"#),
            .text(delta: "OK")
        )
    }

    func testFromSessionUpdateToolCall() {
        XCTAssertEqual(
            parseNotification(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"S","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"WebFetch","rawInput":{"url":"https://example.com"}}}}"#),
            .toolStarted(title: "WebFetch")
        )
    }

    func testFromSessionUpdateToolCallUpdateCompleted() {
        XCTAssertEqual(
            parseNotification(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"S","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed","title":"WebFetch","locations":[]}}}"#),
            .toolCompleted(title: "WebFetch", failed: false)
        )
    }

    func testFromSessionUpdateTurnCompleted() {
        XCTAssertEqual(
            parseNotification(#"{"jsonrpc":"2.0","method":"_x.ai/session/update","params":{"sessionId":"S","update":{"sessionUpdate":"turn_completed","prompt_id":"P","stop_reason":"end_turn"}}}"#),
            .end(stopReason: "end_turn", sessionId: "S")
        )
    }

    func testFromSessionUpdateUnknownKindIsNil() {
        XCTAssertNil(
            parseNotification(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"S","update":{"sessionUpdate":"available_commands_update","commands":[]}}}"#)
        )
    }
}
