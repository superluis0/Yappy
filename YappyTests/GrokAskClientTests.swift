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

    // MARK: - Agent permission triage

    private func permissionParams(
        kind: String?,
        title: String = "Tool call",
        options: [[String: Any]]
    ) -> [String: Any] {
        var toolCall: [String: Any] = ["title": title]
        if let kind { toolCall["kind"] = kind }
        return ["sessionId": "s1", "toolCall": toolCall, "options": options]
    }

    private let standardOptions: [[String: Any]] = [
        ["optionId": "allow-always", "kind": "allow_always", "name": "Always Allow"],
        ["optionId": "allow-once", "kind": "allow_once", "name": "Allow"],
        ["optionId": "reject-once", "kind": "reject_once", "name": "Reject"],
    ]

    func testPermissionApprovesSearchToolWithOncePreferred() {
        let decision = GrokAgentClient.permissionDecision(
            params: permissionParams(kind: "search", options: standardOptions)
        )
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.outcome["outcome"] as? String, "selected")
        XCTAssertEqual(decision.outcome["optionId"] as? String, "allow-once",
                       "allow_once must win over allow_always")
    }

    func testPermissionApprovesFetchTool() {
        let decision = GrokAgentClient.permissionDecision(
            params: permissionParams(kind: "fetch", options: standardOptions)
        )
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.outcome["optionId"] as? String, "allow-once")
    }

    func testPermissionRejectsExecuteTool() {
        let decision = GrokAgentClient.permissionDecision(
            params: permissionParams(kind: "execute", options: standardOptions)
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.outcome["outcome"] as? String, "selected")
        XCTAssertEqual(decision.outcome["optionId"] as? String, "reject-once")
    }

    func testPermissionRejectsEditAndReadTools() {
        for kind in ["edit", "read", "delete", "move", "other"] {
            let decision = GrokAgentClient.permissionDecision(
                params: permissionParams(kind: kind, options: standardOptions)
            )
            XCTAssertFalse(decision.allowed, "kind \(kind) must be rejected")
            XCTAssertEqual(decision.outcome["optionId"] as? String, "reject-once")
        }
    }

    func testPermissionMissingKindFallsBackToResearchTitleMarkers() {
        let research = GrokAgentClient.permissionDecision(
            params: permissionParams(kind: nil, title: "Searching the web", options: standardOptions)
        )
        XCTAssertTrue(research.allowed)

        let opaque = GrokAgentClient.permissionDecision(
            params: permissionParams(kind: nil, title: "Run command", options: standardOptions)
        )
        XCTAssertFalse(opaque.allowed)
    }

    func testPermissionWithNoParseableOptionsCancels() {
        let decision = GrokAgentClient.permissionDecision(
            params: permissionParams(kind: "search", options: [])
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.outcome["outcome"] as? String, "cancelled")
        XCTAssertNil(decision.outcome["optionId"],
                     "a cancel must never carry an invented option")
    }
}
