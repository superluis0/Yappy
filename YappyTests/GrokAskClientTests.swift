//
//  GrokAskClientTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class GrokAskClientTests: XCTestCase {

    func testAuthFailureClassifier() {
        for message in [
            "Grok agent error: Authentication required",
            "not logged in",
            "401 Unauthorized",
            "token expired",
            "Your session has expired",
            "invalid credentials"
        ] {
            XCTAssertTrue(isAuthFailure(message), message)
        }
        // Realistic non-auth failures that CONTAIN auth-ish substrings — a
        // false positive here poisons backend health and reroutes questions,
        // so the classifier must stay phrase-level (see isAuthFailure).
        for message in [
            "rate limit", "network timeout", "context canceled",
            "rate limit: token budget exhausted for this window",
            "your free trial expired yesterday, upgrade to continue",
            "the page returned 401 in the body of the fetched article",
            "tool output: user login page HTML follows",
            "maximum context tokens reached"
        ] {
            XCTAssertFalse(isAuthFailure(message), message)
        }
    }

    @MainActor
    func testAnswersLightStateUsesFileAndLastKnownHealth() {
        XCTAssertEqual(SettingsView.lightState(fileSignedIn: true, health: .unknown), .ready)
        XCTAssertEqual(SettingsView.lightState(fileSignedIn: true, health: .ready), .ready)
        XCTAssertEqual(SettingsView.lightState(fileSignedIn: true, health: .authExpired), .authExpired)
        XCTAssertEqual(SettingsView.lightState(fileSignedIn: false, health: .ready), .needsLogin)
        XCTAssertEqual(SettingsView.lightState(fileSignedIn: false, health: .notInstalled), .notInstalled)
    }

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
        ["optionId": "reject-once", "kind": "reject_once", "name": "Reject"]
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

    // MARK: - Spawn environment isolation (Phase B purge/process race)

    func testGrokSpawnEnvironmentPinsHomeToPrivateDirectory() {
        let home = URL(fileURLWithPath: "/tmp/YappyTests-GrokHome")
        let env = GrokAskClient.spawnEnvironment(home: home)
        XCTAssertEqual(env["HOME"], home.path,
                        "Grok's filesystem isolation hangs entirely on HOME pointing at the private home")
    }

    func testGrokSpawnEnvironmentPrependsLocalBinToPath() {
        let home = URL(fileURLWithPath: "/tmp/YappyTests-GrokHome")
        let env = GrokAskClient.spawnEnvironment(home: home)
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(
            env["PATH"]?.hasPrefix("\(realHome)/.local/bin:\(realHome)/.npm-global/bin:") ?? false,
            "PATH must still prepend ~/.local/bin then ~/.npm-global/bin"
        )
    }

    func testCodexSpawnEnvironmentPinsCodexHomeAndPreservesRealHome() {
        let home = URL(fileURLWithPath: "/tmp/YappyTests-CodexHome")
        let env = CodexAskClient.spawnEnvironment(home: home)
        XCTAssertEqual(env["CODEX_HOME"], home.path)
        // Characterize current behavior exactly: codex's HOME is the real
        // home (unlike Grok's, which is overridden), so it can still resolve
        // unrelated real-home lookups while CODEX_HOME does the isolating.
        XCTAssertEqual(env["HOME"], FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testCodexSpawnEnvironmentPrependsLocalBinToPath() {
        let home = URL(fileURLWithPath: "/tmp/YappyTests-CodexHome")
        let env = CodexAskClient.spawnEnvironment(home: home)
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(
            env["PATH"]?.hasPrefix("\(realHome)/.local/bin:\(realHome)/.npm-global/bin:") ?? false,
            "PATH must still prepend ~/.local/bin then ~/.npm-global/bin"
        )
    }

    // MARK: - ProcessExitWaiter (bounded wait so purge can't race WAL checkpoint)

    func testProcessExitWaiterReturnsTrueQuicklyAfterTermination() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try? process.run()
        process.terminate()

        let start = Date()
        let exited = ProcessExitWaiter.waitForExit(process, timeout: 2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(exited)
        XCTAssertLessThan(elapsed, 1.5, "termination is near-instant; should not consume the full timeout")
    }

    func testProcessExitWaiterTimesOutWhileStillRunning() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try? process.run()
        defer { process.terminate() }

        let start = Date()
        let exited = ProcessExitWaiter.waitForExit(process, timeout: 0.3)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(exited)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 1.0, "should return promptly once the timeout elapses, not wait indefinitely")
    }

    func testProcessExitWaiterReturnsTrueForNilProcess() {
        XCTAssertTrue(ProcessExitWaiter.waitForExit(nil, timeout: 0.1))
    }
}
