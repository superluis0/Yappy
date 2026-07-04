//
//  CodexEventTests.swift
//  YappyTests
//
//  Parser tests written against REAL payloads captured from `codex app-server`
//  (codex-cli 0.142.x) during a live turn.
//

import XCTest
@testable import Yappy

final class CodexEventTests: XCTestCase {
    func testParsesTurnStartedWithNestedTurnID() throws {
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "turn/started",
            "params": [
                "threadId": "thread-123",
                "turn": ["id": "turn-456", "status": "inProgress"]
            ]
        ]))

        XCTAssertEqual(envelope.event, .turnStarted)
        XCTAssertEqual(envelope.threadID, "thread-123")
        XCTAssertEqual(envelope.turnID, "turn-456")
    }

    func testParsesAgentMessageDelta() throws {
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "item/agentMessage/delta",
            "params": [
                "threadId": "thread-123",
                "turnId": "turn-456",
                "itemId": "msg_046ded",
                "delta": "Mexico plays England on"
            ]
        ]))

        XCTAssertEqual(envelope.event, .agentMessageDelta(itemID: "msg_046ded", delta: "Mexico plays England on"))
    }

    func testReasoningCompletedNeverLeaksItemID() throws {
        // Real shape: reasoning items carry NO text, just an rs_… id — the old
        // parser scraped that id into the answer.
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "reasoning",
                    "id": "rs_046ded27767187c3016a46c85a7e2881",
                    "summary": [],
                    "content": []
                ],
                "threadId": "thread-123",
                "turnId": "turn-456"
            ]
        ]))

        XCTAssertEqual(envelope.event, .reasoningCompleted(summary: nil))
    }

    func testReasoningCompletedExtractsSummaryText() throws {
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "reasoning",
                    "id": "rs_1",
                    "summary": [["type": "summary_text", "text": "Checking the fixture schedule"]]
                ]
            ]
        ]))

        XCTAssertEqual(envelope.event, .reasoningCompleted(summary: "Checking the fixture schedule"))
    }

    func testWebSearchCompletedExtractsQuery() throws {
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "webSearch",
                    "id": "ws_046ded27767187c3",
                    "query": "Mexico England 2026 World Cup match date",
                    "action": [
                        "type": "search",
                        "query": "Mexico England 2026 World Cup match date"
                    ]
                ]
            ]
        ]))

        XCTAssertEqual(envelope.event, .webSearchCompleted(query: "Mexico England 2026 World Cup match date"))
    }

    func testAgentMessageCompletedCarriesPhaseAndFullText() throws {
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "agentMessage",
                    "id": "msg_046ded",
                    "text": "Mexico plays England on Sunday, July 5, 2026.",
                    "phase": "final_answer"
                ]
            ]
        ]))

        XCTAssertEqual(
            envelope.event,
            .agentMessageCompleted(
                itemID: "msg_046ded",
                phase: "final_answer",
                text: "Mexico plays England on Sunday, July 5, 2026."
            )
        )
    }

    func testUserMessageEchoIsIgnored() throws {
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "userMessage",
                    "id": "2be0dfea",
                    "content": [["type": "text", "text": "When does Mexico play England?"]]
                ]
            ]
        ]))

        XCTAssertEqual(envelope.event, .ignored(method: "item/completed"))
    }

    func testBookkeepingTrafficIsIgnored() throws {
        for method in ["thread/tokenUsage/updated", "account/rateLimits/updated", "mcpServer/startupStatus/updated", "thread/status/changed", "warning"] {
            let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
                "method": method,
                "params": ["threadId": "t"]
            ]))
            XCTAssertEqual(envelope.event, .ignored(method: method), "expected \(method) to be ignored")
        }
    }

    func testTurnCompletedSuccessAndFailure() throws {
        let success = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "turn/completed",
            "params": ["threadId": "t", "turn": ["id": "u", "status": "completed"]]
        ]))
        XCTAssertEqual(success.event, .turnCompleted(failureMessage: nil))

        let failure = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "turn/completed",
            "params": ["threadId": "t", "turn": ["id": "u", "status": "failed", "error": ["message": "boom"]]]
        ]))
        XCTAssertEqual(failure.event, .turnCompleted(failureMessage: "boom"))
    }

    func testRootErrorBecomesServerError() throws {
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "jsonrpc": "2.0",
            "error": ["code": -32000, "message": "turn failed"]
        ]))

        XCTAssertEqual(envelope.event, .serverError(message: "turn failed"))
    }

    func testToolCallProgressExtractsMessage() throws {
        let envelope = try XCTUnwrap(CodexEventEnvelope(jsonObject: [
            "method": "item/mcpToolCall/progress",
            "params": [
                "threadId": "t",
                "turnId": "u",
                "message": "Reading the source"
            ]
        ]))

        XCTAssertEqual(envelope.event, .toolCallProgress(text: "Reading the source"))
    }
}
