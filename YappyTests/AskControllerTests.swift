//
//  AskControllerTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

// MARK: - Fakes

@MainActor
final class FakeCodexClient: CodexAsking {
    var onNotification: (@Sendable (CodexEventEnvelope) -> Void)?

    private(set) var prewarmCount = 0
    private(set) var askCalls: [(transcript: String, continuingThread: String?, effort: String)] = []
    private(set) var interruptCalls: [(threadID: String, turnID: String)] = []
    private(set) var stopCount = 0

    var askResult: Result<CodexRunStart, Error> = .success(
        CodexRunStart(threadID: "t1", turnID: "turn1", turnStarted: true)
    )

    func prewarm() async { prewarmCount += 1 }

    func ask(transcript: String, continuingThread: String?, effort: String) async throws -> CodexRunStart {
        askCalls.append((transcript, continuingThread, effort))
        let start = try askResult.get()
        // Follow-up asks defer turn ID to streaming events (turnStarted), matching
        // the gap where stale prior-turn events can arrive.
        if askCalls.count > 1 {
            return CodexRunStart(
                threadID: start.threadID,
                turnID: nil,
                turnStarted: start.turnStarted
            )
        }
        return start
    }

    func interrupt(threadID: String, turnID: String) {
        interruptCalls.append((threadID, turnID))
    }

    func stop() { stopCount += 1 }

    func push(_ envelope: CodexEventEnvelope) {
        onNotification?(envelope)
    }
}

@MainActor
final class FakeGrokClient: GrokAsking {
    var onEvent: (@Sendable (GrokEvent) -> Void)?

    private(set) var askCalls: [GrokAskRequest] = []
    private(set) var prewarmCount = 0
    private(set) var cancelCount = 0
    var askError: Error?
    var prewarmEvent: GrokEvent?

    func prewarm() async {
        prewarmCount += 1
        if let prewarmEvent { onEvent?(prewarmEvent) }
    }

    func ask(_ request: GrokAskRequest) async throws {
        askCalls.append(request)
        if let askError { throw askError }
    }

    func cancel() { cancelCount += 1 }

    func push(_ event: GrokEvent) {
        onEvent?(event)
    }
}

// MARK: - Tests

@MainActor
final class AskControllerTests: XCTestCase {
    private var historyDirectory: URL!

    override func setUp() {
        super.setUp()
        historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-controller-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let historyDirectory { try? FileManager.default.removeItem(at: historyDirectory) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeController(
        codex: FakeCodexClient? = nil,
        grok: FakeGrokClient? = nil,
        history: AskHistoryStore? = nil
    ) -> (AskController, FakeCodexClient, FakeGrokClient) {
        let codexClient = codex ?? FakeCodexClient()
        let grokClient = grok ?? FakeGrokClient()
        let store = history ?? AskHistoryStore(directory: historyDirectory)
        let controller = AskController(codexClient: codexClient, grokClient: grokClient, history: store)
        return (controller, codexClient, grokClient)
    }

    private func yieldUntil(_ condition: () -> Bool, maxYields: Int = 30, file: StaticString = #file, line: UInt = #line) async {
        for _ in 0..<maxYields {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition not met within \(maxYields) yields", file: file, line: line)
    }

    private func pushCodex(
        _ client: FakeCodexClient,
        threadID: String = "t1",
        turnID: String = "turn1",
        event: CodexEvent
    ) async {
        client.push(CodexEventEnvelope(threadID: threadID, turnID: turnID, event: event))
        await Task.yield()
        await Task.yield()
    }

    private func pushGrok(_ client: FakeGrokClient, event: GrokEvent) async {
        client.push(event)
        await Task.yield()
        await Task.yield()
    }

    private func completeCodexRun(
        controller: AskController,
        codex: FakeCodexClient,
        question: String,
        answer: String,
        threadID: String = "t1",
        turnID: String = "turn1"
    ) async {
        controller.beginListening()
        controller.submit(question)
        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, threadID: threadID, turnID: turnID, event: .turnStarted)
        await pushCodex(codex, threadID: threadID, turnID: turnID, event: .agentMessageDelta(itemID: "msg1", delta: answer))
        await pushCodex(codex, threadID: threadID, turnID: turnID, event: .turnCompleted(failureMessage: nil))
        await yieldUntil { controller.run?.status == .completed }
    }

    // MARK: - a. Happy path codex

    func testHappyPathCodexCompletesAndWritesHistory() async {
        let codex = FakeCodexClient()
        let history = AskHistoryStore(directory: historyDirectory)
        let (controller, _, _) = makeController(codex: codex, history: history)
        controller.saveHistory = true

        controller.beginListening()
        controller.submit("What is two plus two?")

        await yieldUntil { codex.askCalls.count == 1 }
        XCTAssertNil(codex.askCalls[0].continuingThread)
        XCTAssertEqual(codex.askCalls[0].effort, "low")

        await pushCodex(codex, event: .turnStarted)
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: "Four"))
        await pushCodex(codex, event: .turnCompleted(failureMessage: nil))

        await yieldUntil { controller.run?.status == .completed }
        XCTAssertEqual(controller.run?.answerText, "Four")
        XCTAssertEqual(controller.run?.result, "Four")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.question, "What is two plus two?")
        XCTAssertEqual(history.entries.first?.answer, "Four")
    }

    // MARK: - b. Narration strip on save

    func testNarrationStripOnSave() async {
        let codex = FakeCodexClient()
        let history = AskHistoryStore(directory: historyDirectory)
        let (controller, _, _) = makeController(codex: codex, history: history)
        controller.saveHistory = true

        controller.beginListening()
        controller.submit("Find the capital")

        await yieldUntil { codex.askCalls.count == 1 }
        let answer = "Searching for X.\nReal."
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: answer))
        await pushCodex(codex, event: .turnCompleted(failureMessage: nil))

        await yieldUntil { controller.run?.status == .completed }
        XCTAssertEqual(history.entries.first?.answer, "Real.")
    }

    // MARK: - c. Abort mid-stream

    func testAbortMidStreamInterruptsAndCancels() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Long question")

        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .turnStarted)
        await yieldUntil { controller.run?.codexThreadID == "t1" }

        controller.abort()

        XCTAssertEqual(controller.run?.status, .cancelled)
        XCTAssertEqual(codex.interruptCalls.count, 1)
        XCTAssertEqual(codex.interruptCalls[0].threadID, "t1")
        XCTAssertEqual(codex.interruptCalls[0].turnID, "turn1")
    }

    // MARK: - d. Stale-thread events dropped

    func testStaleThreadEventsAreDropped() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "First?",
            answer: "First answer."
        )
        let answerBefore = controller.run?.answerText

        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: " stale"))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(controller.run?.status, .completed)
        XCTAssertEqual(controller.run?.answerText, answerBefore)
    }

    // MARK: - e. Backend fallback

    func testBackendFallbackDispatchesGrok() async {
        let codex = FakeCodexClient()
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(codex: codex, grok: grok)
        controller.backend = .codex
        controller.backendUsable = { backend in backend == .grok }
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Fallback question")

        await yieldUntil { grok.askCalls.count == 1 }
        XCTAssertTrue(codex.askCalls.isEmpty)
        // The fallback is per-question: the user's selection stays intact so
        // the next question re-tries it once the backend is usable again.
        XCTAssertEqual(controller.backend, .codex)

        await pushGrok(grok, event: .text(delta: "Grok says hi."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }
        XCTAssertEqual(controller.run?.answerText, "Grok says hi.")
    }

    func testFallbackDoesNotStickOnceSelectedBackendUsableAgain() async {
        // Regression: grok selected but signed out at launch → codex answers via
        // fallback. After the user signs back into grok (selection unchanged, so
        // no settings event fires), the NEXT question must route to grok again.
        let codex = FakeCodexClient()
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(codex: codex, grok: grok)
        controller.backend = .grok
        var grokSignedIn = false
        controller.backendUsable = { backend in
            backend == .codex || grokSignedIn
        }
        controller.saveHistory = false

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Asked while grok is signed out",
            answer: "Codex fallback answer."
        )
        XCTAssertEqual(controller.backend, .grok)

        grokSignedIn = true
        controller.beginListening()
        controller.submit("Asked after grok re-login")

        await yieldUntil { grok.askCalls.count == 1 }
        XCTAssertEqual(codex.askCalls.count, 1)
    }

    func testRuntimeAuthFailureFallsBackOnceAndKeepsSelection() async {
        let codex = FakeCodexClient()
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(codex: codex, grok: grok)
        controller.backend = .grok
        controller.backendUsable = { _ in true }
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Runtime fallback question")
        await yieldUntil { grok.askCalls.count == 1 }

        await pushGrok(grok, event: .error(message: "Grok agent error: Authentication required"))
        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: "Codex answered."))
        await pushCodex(codex, event: .turnCompleted(failureMessage: nil))
        await yieldUntil { controller.run?.status == .completed }

        XCTAssertEqual(controller.run?.result, "Codex answered.")
        XCTAssertEqual(controller.fallbackCaption, "Answered by Codex — Grok needs re-login.")
        XCTAssertEqual(controller.grokHealth, .authExpired)
        XCTAssertEqual(controller.codexHealth, .ready)
        XCTAssertEqual(controller.backend, .grok)
    }

    func testRuntimeAuthFallbackIsOneHopWhenBothBackendsExpire() async {
        let codex = FakeCodexClient()
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(codex: codex, grok: grok)
        controller.backend = .grok
        controller.backendUsable = { _ in true }
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Both expired")
        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .error(message: "token expired"))
        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .serverError(message: "401 Unauthorized"))
        await yieldUntil { controller.run?.status == .failed }

        XCTAssertEqual(grok.askCalls.count, 1)
        XCTAssertEqual(codex.askCalls.count, 1)
        XCTAssertEqual(controller.grokHealth, .authExpired)
        XCTAssertEqual(controller.codexHealth, .authExpired)
        XCTAssertEqual(
            controller.run?.result,
            "Codex session expired — run `codex` in Terminal, then try again."
        )
    }

    func testRetryOfAuthFailureRoutesToHealthyOtherBackend() async {
        let codex = FakeCodexClient()
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(codex: codex, grok: grok)
        controller.backend = .grok
        var codexAvailable = false
        controller.backendUsable = { backend in backend == .grok || codexAvailable }
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Retry me")
        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .error(message: "not logged in"))
        await yieldUntil { controller.run?.status == .failed }

        codexAvailable = true
        controller.retry()
        await yieldUntil { codex.askCalls.count == 1 }

        XCTAssertEqual(grok.askCalls.count, 1)
        XCTAssertEqual(controller.backend, .grok)
        XCTAssertEqual(controller.fallbackCaption, "Answered by Codex — Grok needs re-login.")
    }

    func testPrewarmAuthFailureAndSuccessUpdateHealth() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        grok.prewarmEvent = .error(message: "Grok agent error: Authentication required")

        controller.prewarm()
        await yieldUntil { controller.grokHealth == .authExpired }

        grok.prewarmEvent = .ignored(type: askPrewarmReadySignal)
        controller.prewarm()
        await yieldUntil { controller.grokHealth == .ready }
    }

    func testSuccessfulTurnRestoresReadyHealth() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.backendUsable = { _ in true }
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Health check")
        await yieldUntil { grok.askCalls.count == 1 }
        controller.setHealth(.authExpired, for: .grok)
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))

        XCTAssertEqual(controller.grokHealth, .ready)
    }

    // MARK: - f. Tool blocklist

    func testCommandStartedFailsRunAndInterrupts() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Do something dangerous")

        await yieldUntil { codex.askCalls.count == 1 }
        await yieldUntil { controller.run?.codexThreadID == "t1" }

        await pushCodex(codex, event: .commandStarted(command: "rm -rf /"))

        await yieldUntil { controller.run?.status == .failed }
        XCTAssertEqual(controller.run?.result, "Ask tried to use a blocked tool and was stopped.")
        XCTAssertEqual(codex.interruptCalls.count, 1)
        XCTAssertEqual(codex.interruptCalls[0].threadID, "t1")
        XCTAssertEqual(codex.interruptCalls[0].turnID, "turn1")
    }

    // MARK: - g. Follow-up thread reuse

    func testFollowUpReusesCodexThread() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "First question",
            answer: "First answer.",
            threadID: "t1"
        )

        controller.beginListening()
        controller.submit("Follow up?")

        await yieldUntil { codex.askCalls.count == 2 }
        XCTAssertEqual(codex.askCalls[1].continuingThread, "t1")
        XCTAssertTrue(codex.askCalls[1].transcript.contains("Question:\nFollow up?"))
        XCTAssertTrue(codex.askCalls[1].transcript.contains("Context: it is"))
        XCTAssertEqual(controller.run?.turns.count, 1)
        XCTAssertEqual(controller.run?.turns[0].question, "First question")
        XCTAssertEqual(controller.run?.turns[0].answer, "First answer.")
    }

    // MARK: - h. Empty captures fade out (no ghost card)

    func testCancelCaptureWithoutSpeechClearsRun() {
        let (controller, _, _) = makeController()
        controller.saveHistory = false

        controller.beginListening()
        controller.cancelCapture()

        XCTAssertNil(controller.run, "an empty capture must fade out, not park a cancelled card")
    }

    func testEmptySubmitClearsRun() {
        let (controller, _, _) = makeController()
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("   \n")

        XCTAssertNil(controller.run)
    }

    func testAbortDuringCaptureClearsRun() {
        let (controller, _, _) = makeController()
        controller.saveHistory = false

        controller.beginPreparing()
        controller.abort()
        XCTAssertNil(controller.run, "abort during preparing must discard, not show a Stopped card")

        controller.beginListening()
        controller.abort()
        XCTAssertNil(controller.run, "abort during listening must discard, not show a Stopped card")
    }

    func testCancelledFollowUpCaptureRestoresCompletedCard() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Original question",
            answer: "Previous answer."
        )

        controller.beginListening()   // borrows the completed card for a follow-up
        controller.cancelCapture()    // silence — nothing was asked

        XCTAssertEqual(controller.run?.status, .completed)
        XCTAssertEqual(controller.run?.rawTranscript, "Original question")
        XCTAssertEqual(controller.run?.answerText, "Previous answer.")
        XCTAssertEqual(controller.run?.turns.count, 0)
    }

    // MARK: - i. Card command

    func testCardCommandCopyRestoresCompletedRun() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        var copied: String?
        controller.copyText = { copied = $0 }

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Original question",
            answer: "Previous answer."
        )

        controller.beginListening()
        controller.submit("copy that")

        XCTAssertEqual(copied, "Previous answer.")
        XCTAssertEqual(controller.run?.status, .completed)
        XCTAssertEqual(controller.run?.rawTranscript, "Original question")
        XCTAssertEqual(controller.run?.answerText, "Previous answer.")
    }

    // MARK: - j. Grok dispatch + metrics

    func testGrokDispatchDefaultsToLowEffortAndSplitsSystemPrompt() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("What is Swift?")

        await yieldUntil { grok.askCalls.count == 1 }
        XCTAssertEqual(grok.askCalls[0].effort, "low")
        XCTAssertEqual(grok.askCalls[0].systemPrompt, AskPromptPolicy.systemInstructions)
        XCTAssertTrue(grok.askCalls[0].prompt.contains("Question:\nWhat is Swift?"))
        XCTAssertFalse(grok.askCalls[0].prompt.contains("READ-ONLY"))
    }

    func testThinkHarderRoutesHighEffortToGrok() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("think harder, what is entropy?")

        await yieldUntil { grok.askCalls.count == 1 }
        XCTAssertEqual(grok.askCalls[0].effort, "high")
        XCTAssertTrue(grok.askCalls[0].prompt.contains("what is entropy?"))
        XCTAssertFalse(grok.askCalls[0].prompt.lowercased().contains("think harder"))
    }

    func testGrokFollowUpPromptCarriesPriorTurns() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("First question")

        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "First answer."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }

        controller.beginListening()
        controller.submit("Follow up?")

        await yieldUntil { grok.askCalls.count == 2 }
        XCTAssertTrue(grok.askCalls[1].prompt.contains("Earlier in this conversation:"))
        XCTAssertTrue(grok.askCalls[1].prompt.contains("First question"))
        XCTAssertTrue(grok.askCalls[1].prompt.contains("First answer."))
    }

    func testMetricsStampOrderingGrok() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        var t = 0.0
        controller.metricsClock = { t += 1; return t }

        controller.beginListening()
        controller.submit("Metrics question")

        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .thought(delta: "hmm"))
        await pushGrok(grok, event: .text(delta: "Answer."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }

        let m = controller.lastRunMetrics
        XCTAssertNotNil(m.dispatchedAt)
        XCTAssertNotNil(m.firstEventAt)
        XCTAssertNotNil(m.firstAnswerTokenAt)
        XCTAssertNotNil(m.completedAt)
        XCTAssertLessThan(m.dispatchedAt!, m.firstEventAt!)
        XCTAssertLessThan(m.firstEventAt!, m.firstAnswerTokenAt!)
        XCTAssertLessThan(m.firstAnswerTokenAt!, m.completedAt!)
    }

    func testMetricsStampOrderingCodex() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        var t = 0.0
        controller.metricsClock = { t += 1; return t }

        controller.beginListening()
        controller.submit("Metrics question")

        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .turnStarted)
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: "Answer."))
        await pushCodex(codex, event: .turnCompleted(failureMessage: nil))
        await yieldUntil { controller.run?.status == .completed }

        let m = controller.lastRunMetrics
        XCTAssertNotNil(m.dispatchedAt)
        XCTAssertNotNil(m.firstEventAt)
        XCTAssertNotNil(m.firstAnswerTokenAt)
        XCTAssertNotNil(m.completedAt)
        XCTAssertLessThan(m.dispatchedAt!, m.firstEventAt!)
        XCTAssertLessThan(m.firstEventAt!, m.firstAnswerTokenAt!)
        XCTAssertLessThan(m.firstAnswerTokenAt!, m.completedAt!)
    }

    // MARK: - k. Grok router + prewarm routing

    func testRouterFallsBackToOneShotOnWarmFailure() async {
        let warm = FakeGrokClient()
        let oneShot = FakeGrokClient()
        warm.askError = GrokAgentClient.ClientError.notWarm
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)
        let controller = AskController(
            codexClient: FakeCodexClient(),
            grokClient: router,
            history: AskHistoryStore(directory: historyDirectory)
        )
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Fallback question")

        await yieldUntil { oneShot.askCalls.count == 1 }
        XCTAssertEqual(warm.askCalls.count, 1)
        XCTAssertEqual(oneShot.askCalls[0].prompt, warm.askCalls[0].prompt)

        await pushGrok(oneShot, event: .text(delta: "One-shot answer."))
        await pushGrok(oneShot, event: .end(stopReason: "end_turn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }
        XCTAssertEqual(controller.run?.answerText, "One-shot answer.")
    }

    func testGrokEndStoresSessionID() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("What is Swift?")

        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "A language."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: "s1"))
        await yieldUntil { controller.run?.status == .completed }

        XCTAssertEqual(controller.run?.grokSessionID, "s1")
    }

    func testGrokFollowUpUsesResumeAndBareQuestion() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("First question")

        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "First answer."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: "s1"))
        await yieldUntil { controller.run?.status == .completed }

        controller.beginListening()
        controller.submit("Follow up?")

        await yieldUntil { grok.askCalls.count == 2 }
        XCTAssertEqual(grok.askCalls[1].resumeSessionID, "s1")
        XCTAssertTrue(grok.askCalls[1].prompt.contains("Question:\nFollow up?"))
        XCTAssertTrue(grok.askCalls[1].prompt.contains("Context: it is"))
        XCTAssertFalse(grok.askCalls[1].prompt.contains("Earlier in this conversation:"))
    }

    func testDispatchShowsAskingStepUntilFirstEvent() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Latency question")

        await yieldUntil { grok.askCalls.count == 1 }
        let askingTitle = "Asking Grok 4.5"
        let askingStep = controller.run?.steps.first { $0.title == askingTitle }
        XCTAssertNotNil(askingStep)
        XCTAssertEqual(askingStep?.state, .running)

        await pushGrok(grok, event: .thought(delta: "hmm"))
        let completedStep = controller.run?.steps.first { $0.title == askingTitle }
        XCTAssertEqual(completedStep?.state, .completed)
    }

    func testCompletedRunCarriesLatencySeconds() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        var t = 0.0
        controller.metricsClock = { t += 1; return t }

        controller.beginListening()
        controller.submit("Latency question")

        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "Answer."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }

        XCTAssertNotNil(controller.run?.latencySeconds)
        XCTAssertGreaterThan(controller.run?.latencySeconds ?? 0, 0)
    }

    func testGrokAfterCodexFollowUpWrapsWithoutResume() async {
        let codex = FakeCodexClient()
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(codex: codex, grok: grok)
        controller.saveHistory = false

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Codex question",
            answer: "Codex answer."
        )

        controller.backend = .grok
        controller.beginListening()
        controller.submit("Grok follow up?")

        await yieldUntil { grok.askCalls.count == 1 }
        XCTAssertNil(grok.askCalls[0].resumeSessionID)
        XCTAssertTrue(grok.askCalls[0].prompt.contains("Earlier in this conversation:"))
    }

    func testToolEventsProduceSingleSearchStep() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Search question")

        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
        await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
        await pushGrok(grok, event: .toolCompleted(title: "WebFetch", failed: false))
        await pushGrok(grok, event: .text(delta: "Found it."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }

        let searchSteps = controller.run?.steps.filter { $0.kind == .search } ?? []
        XCTAssertEqual(searchSteps.count, 1)
        XCTAssertEqual(searchSteps[0].state, .completed)
    }

    func testRouterPrefersWarmWhenHealthy() async {
        let warm = FakeGrokClient()
        let oneShot = FakeGrokClient()
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)

        let request = GrokAskRequest(
            prompt: "Warm path",
            model: AskGrokModel.grok45.rawValue,
            effort: "low",
            systemPrompt: AskPromptPolicy.systemInstructions
        )
        try? await router.ask(request)

        XCTAssertEqual(warm.askCalls.count, 1)
        XCTAssertTrue(oneShot.askCalls.isEmpty)
    }

    func testPrewarmRoutesBySelectedBackend() async {
        let codex = FakeCodexClient()
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(codex: codex, grok: grok)

        controller.backend = .grok
        controller.prewarm()
        await yieldUntil { grok.prewarmCount == 1 }
        XCTAssertEqual(grok.prewarmCount, 1)
        XCTAssertEqual(codex.prewarmCount, 0)

        controller.backend = .codex
        controller.prewarm()
        await yieldUntil { codex.prewarmCount == 1 }
        XCTAssertEqual(codex.prewarmCount, 1)
        XCTAssertEqual(grok.prewarmCount, 1)
    }

    func testRouterCancelFansOut() {
        let warm = FakeGrokClient()
        let oneShot = FakeGrokClient()
        let router = GrokClientRouter(warm: warm, oneShot: oneShot)

        router.cancel()

        XCTAssertEqual(warm.cancelCount, 1)
        XCTAssertEqual(oneShot.cancelCount, 1)
    }

    // MARK: - l. Barge-in during streaming

    func testBargeInFromWorkingInterruptsAndListens() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Streaming question")

        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .turnStarted)
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: "Partial"))
        await yieldUntil { controller.run?.status == .working }

        controller.beginListening()

        XCTAssertEqual(controller.run?.status, .listening)
        XCTAssertEqual(codex.interruptCalls.count, 1)
        XCTAssertEqual(codex.interruptCalls[0].threadID, "t1")
        XCTAssertEqual(codex.interruptCalls[0].turnID, "turn1")
        XCTAssertNil(controller.run?.answerText)
        XCTAssertTrue(controller.run?.steps.isEmpty ?? false)
        XCTAssertEqual(controller.run?.codexThreadID, "t1")
        XCTAssertNil(controller.run?.codexTurnID)
    }

    func testBargeInPreservesConversationTurns() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "First question",
            answer: "First answer.",
            threadID: "t1"
        )

        controller.beginListening()
        controller.submit("Second question")

        await yieldUntil { codex.askCalls.count == 2 }
        await pushCodex(codex, turnID: "turn2", event: .turnStarted)
        await pushCodex(codex, turnID: "turn2", event: .agentMessageDelta(itemID: "msg1", delta: "Partial"))
        await yieldUntil { controller.run?.status == .working }

        controller.beginListening()

        XCTAssertEqual(controller.run?.status, .listening)
        XCTAssertEqual(controller.run?.turns.count, 1)
        XCTAssertEqual(controller.run?.turns[0].question, "First question")
        XCTAssertEqual(controller.run?.turns[0].answer, "First answer.")
    }

    func testBargeInThenSubmitContinuesThread() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Interrupted question")

        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, threadID: "t1", turnID: "turn1", event: .turnStarted)
        await pushCodex(codex, threadID: "t1", turnID: "turn1", event: .agentMessageDelta(itemID: "msg1", delta: "Partial"))
        await yieldUntil { controller.run?.status == .working }

        controller.beginListening()
        controller.submit("follow up")

        await yieldUntil { codex.askCalls.count == 2 }
        XCTAssertEqual(codex.askCalls[1].continuingThread, "t1")
    }

    // MARK: - m. Stale turn rejection

    func testStaleTurnEventRejectedOnFollowUp() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "First?",
            answer: "First answer.",
            threadID: "t1",
            turnID: "turn1"
        )

        controller.beginListening()
        controller.submit("Follow up?")

        await yieldUntil { codex.askCalls.count == 2 }
        XCTAssertNil(controller.run?.codexTurnID)

        await pushCodex(codex, threadID: "t1", turnID: "turn1", event: .agentMessageDelta(itemID: "msg1", delta: "stale"))
        await Task.yield()
        await Task.yield()

        XCTAssertNil(controller.run?.answerText)
        XCTAssertNil(controller.run?.codexTurnID)

        await pushCodex(codex, threadID: "t1", turnID: "turn2", event: .turnStarted)
        await pushCodex(codex, threadID: "t1", turnID: "turn2", event: .agentMessageDelta(itemID: "msg2", delta: "Fresh"))
        await pushCodex(codex, threadID: "t1", turnID: "turn2", event: .turnCompleted(failureMessage: nil))
        await yieldUntil { controller.run?.status == .completed }

        XCTAssertEqual(controller.run?.codexTurnID, "turn2")
        XCTAssertEqual(controller.run?.answerText, "Fresh")
    }

    // MARK: - n. Retry preserves think harder

    func testRetryPreservesThinkHarderEffort() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("think harder, why is the sky blue")

        await yieldUntil { grok.askCalls.count == 1 }
        XCTAssertEqual(grok.askCalls[0].effort, "high")
        await pushGrok(grok, event: .text(delta: "Because of Rayleigh scattering."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }

        controller.retry()

        await yieldUntil { grok.askCalls.count == 2 }
        XCTAssertEqual(grok.askCalls[1].effort, "high")
    }

    // MARK: - o. First-activity watchdog

    func testFirstActivityWatchdogDefaultsToEightSeconds() {
        let (controller, _, _) = makeController()
        XCTAssertEqual(controller.firstActivityTimeout, 8)
    }

    func testFirstActivityWatchdogFailsSilentBackend() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        controller.firstActivityTimeout = 0.05

        controller.beginListening()
        controller.submit("Silent question")

        await yieldUntil { grok.askCalls.count == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await yieldUntil { controller.run?.status == .failed }

        XCTAssertTrue(controller.run?.result?.contains("No response") == true)
    }

    func testBargeInFromGrokWorkingCancelsClient() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Grok question")

        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .thought(delta: "hmm"))
        await yieldUntil { controller.run?.status == .working }

        controller.beginListening()

        XCTAssertEqual(grok.cancelCount, 1)
        XCTAssertEqual(controller.run?.status, .listening)
    }
    // MARK: - Security: grok tool allowlist

    func testGrokNonResearchToolFailsRunAndCancels() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Do something")
        await yieldUntil { grok.askCalls.count == 1 }

        await pushGrok(grok, event: .toolStarted(title: "Bash"))

        await yieldUntil { controller.run?.status == .failed }
        XCTAssertEqual(controller.run?.result, "Ask tried to use a blocked tool and was stopped.")
        XCTAssertEqual(grok.cancelCount, 1)
    }

    func testGrokResearchToolStillMakesASearchStep() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("What is new today?")
        await yieldUntil { grok.askCalls.count == 1 }

        await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
        XCTAssertEqual(controller.run?.status, .working)
        XCTAssertEqual(controller.run?.steps.filter { $0.kind == .search }.count, 1)
    }

    // MARK: - Security: grok research tool cap

    func testGrokResearchToolCapFailsRunAfterSixthSearch() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Do exhaustive research")
        await yieldUntil { grok.askCalls.count == 1 }

        for _ in 0..<5 {
            await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
            await pushGrok(grok, event: .toolCompleted(title: "WebFetch", failed: false))
        }
        await pushGrok(grok, event: .toolStarted(title: "WebFetch"))

        await yieldUntil { controller.run?.status == .failed }
        XCTAssertEqual(controller.run?.result, "Grok kept searching without reaching an answer — try asking again.")
        XCTAssertEqual(grok.cancelCount, 1)
    }

    func testGrokResearchToolCapNotYetReachedAfterThreeSearches() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Do some research")
        await yieldUntil { grok.askCalls.count == 1 }

        for _ in 0..<3 {
            await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
            await pushGrok(grok, event: .toolCompleted(title: "WebFetch", failed: false))
        }
        await pushGrok(grok, event: .toolStarted(title: "WebFetch"))

        XCTAssertEqual(controller.run?.status, .working)
        XCTAssertNil(controller.run?.result)
    }

    func testGrokResearchToolCapResetsAcrossRuns() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Do exhaustive research")
        await yieldUntil { grok.askCalls.count == 1 }

        for _ in 0..<5 {
            await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
            await pushGrok(grok, event: .toolCompleted(title: "WebFetch", failed: false))
        }
        await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
        await yieldUntil { controller.run?.status == .failed }

        controller.beginListening()
        controller.submit("A fresh question")
        await yieldUntil { grok.askCalls.count == 2 }

        await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
        XCTAssertEqual(controller.run?.status, .working)
        XCTAssertNotEqual(controller.run?.result, "Grok kept searching without reaching an answer — try asking again.")
    }

    func testGrokResearchToolCapCompletesWithPartialAnswerWhenPresent() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("Do exhaustive research")
        await yieldUntil { grok.askCalls.count == 1 }

        for _ in 0..<5 {
            await pushGrok(grok, event: .toolStarted(title: "WebFetch"))
            await pushGrok(grok, event: .toolCompleted(title: "WebFetch", failed: false))
        }
        await pushGrok(grok, event: .text(delta: "Here is what I found so far."))
        await pushGrok(grok, event: .toolStarted(title: "WebFetch"))

        await yieldUntil { controller.run?.status == .completed }
        XCTAssertEqual(controller.run?.result, "Here is what I found so far.")
        XCTAssertEqual(grok.cancelCount, 1)
    }

    // MARK: - p. Speak answers

    func testSpeakFailureShowsTransientCaption() {
        let (controller, _, _) = makeController()

        controller.showSpeakFailureCaption()

        XCTAssertEqual(controller.transientCaption, "Couldn't speak — check voice setup in Settings")
    }

    func testSpeakFailureCaptionExpiresAfterDuration() async {
        let (controller, _, _) = makeController()

        controller.showSpeakFailureCaption(duration: 0.05)
        XCTAssertNotNil(controller.transientCaption)

        // Give the expiry task comfortably more than its duration.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(controller.transientCaption, "the caption must clear itself")
    }

    func testSpeakFailureCaptionRestartCancelsPriorExpiry() async {
        let (controller, _, _) = makeController()

        // First caption with a short fuse, then a second with a long one: the
        // first timer must NOT clip the second caption early.
        controller.showSpeakFailureCaption(duration: 0.05)
        controller.showSpeakFailureCaption(duration: 600)

        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNotNil(controller.transientCaption,
                        "a superseded expiry timer must not clear the newer caption")
    }

    func testSpeechChunksShortTextReturnsOneChunk() {
        XCTAssertEqual(AskController.speechChunks("Short answer."), ["Short answer."])
    }

    func testSpeechChunksPacksSentencesUnderLimitAndPreservesTerminators() {
        let sentence = String(repeating: "a", count: 95) + ". "
        let text = String(repeating: sentence, count: 8)

        let chunks = AskController.speechChunks(text)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 280 })
        XCTAssertEqual(chunks.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.hasSuffix(". ") })
    }

    func testSpeechChunksKeepsSingleOverlongSentenceWhole() {
        let sentence = String(repeating: "x", count: 340) + "."

        XCTAssertEqual(AskController.speechChunks(sentence), [sentence])
    }

    func testSpeechChunksFirstLimitCapsOnlyTheFirstChunk() {
        // Six ~30-char sentences. With a small firstLimit the first chunk holds
        // just the opening sentence (fast first audio); the rest pack to 280.
        let sentence = String(repeating: "a", count: 28) + ". "
        let text = String(repeating: sentence, count: 6)

        let chunks = AskController.speechChunks(text, firstLimit: 40)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, 40)
        XCTAssertGreaterThan(chunks[1].count, 40, "later chunks use the full limit, not the first cap")
        XCTAssertEqual(chunks.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSpeechChunksFirstLimitSplitsOverlongOpeningSentence() {
        let text = String(repeating: "a", count: 200) + "."
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let chunks = AskController.speechChunks(text, firstLimit: 60)

        XCTAssertLessThanOrEqual(chunks[0].count, 60)
        XCTAssertEqual(chunks.joined(), trimmed)
    }

    func testSpeechChunksFirstLimitPrefersClauseBoundary() {
        let text = "First clause here, second clause continues for a long while afterward."
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLimit = 25

        let chunks = AskController.speechChunks(text, firstLimit: firstLimit)

        XCTAssertLessThanOrEqual(chunks[0].count, firstLimit)
        XCTAssertTrue(chunks[0].hasSuffix(", "), "first chunk should split at the clause boundary")
        XCTAssertEqual(chunks.joined(), trimmed)
    }

    func testSpeechChunksFirstLimitHardSplitsUnbrokenToken() {
        let text = String(repeating: "a", count: 150) + "."
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let chunks = AskController.speechChunks(text, firstLimit: 50)

        XCTAssertEqual(chunks[0].count, 50)
        XCTAssertEqual(chunks.joined(), trimmed)
    }

    func testSpeechChunksFirstLimitKeepsShortOpeningSentenceWhole() {
        let sentence = String(repeating: "b", count: 22) + ". "
        let text = sentence + String(repeating: "c", count: 95) + "."

        let chunks = AskController.speechChunks(text, firstLimit: 40)

        XCTAssertEqual(chunks[0], sentence)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSpeakCardCommandsParse() {
        XCTAssertEqual(AskController.parseCardCommand("read that"), .speak)
        XCTAssertEqual(AskController.parseCardCommand("stop talking"), .stopSpeaking)
        XCTAssertNil(AskController.parseCardCommand("read me a poem"))
    }

    func testAnswersVoiceRosterIsBalancedKokoroSet() {
        // Eight curated Kokoro voices, balanced two-per-accent-and-gender, with
        // the grade-A flagship af_heart first (the Settings default).
        XCTAssertEqual(AnswersVoice.allCases.count, 8)
        XCTAssertEqual(AnswersVoice.allCases.first, .afHeart)
        XCTAssertEqual(AnswersVoice.afHeart.rawValue, "af_heart")

        let american = AnswersVoice.allCases.filter { !$0.rawValue.hasPrefix("b") }
        let british = AnswersVoice.allCases.filter { $0.rawValue.hasPrefix("b") }
        XCTAssertEqual(american.count, 4)
        XCTAssertEqual(british.count, 4)
    }

    func testAnswersVoiceNamesEncodeAccentButPreviewStaysBare() {
        // The picker label carries the accent; the spoken name (used when a voice
        // introduces itself in a preview) must stay a bare given name so the
        // sample never reads "(American)" aloud.
        XCTAssertEqual(AnswersVoice.afHeart.displayName, "Heart (American)")
        XCTAssertEqual(AnswersVoice.bmGeorge.displayName, "George (British)")
        XCTAssertEqual(AnswersVoice.afHeart.spokenName, "Heart")
        for voice in AnswersVoice.allCases {
            XCTAssertFalse(voice.spokenName.contains("("), "\(voice.rawValue) preview name should be bare")
        }
    }

    func testSpeakCardCommandRestoresCompletedCardAndSpeaksAnswer() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        controller.speakAvailable = true
        var spoken: [String] = []
        controller.speakAnswer = { spoken.append($0) }

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Original question",
            answer: "Previous answer."
        )

        controller.beginListening()
        controller.submit("read that")

        XCTAssertEqual(spoken, ["Previous answer."])
        XCTAssertEqual(controller.run?.status, .completed)
        XCTAssertEqual(controller.run?.rawTranscript, "Original question")
        XCTAssertEqual(controller.run?.answerText, "Previous answer.")
    }

    func testSpeakCardCommandFallsThroughWhenUnavailable() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        controller.speakAvailable = false
        var spoken: [String] = []
        controller.speakAnswer = { spoken.append($0) }

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Original question",
            answer: "Previous answer."
        )

        controller.beginListening()
        controller.submit("read that")

        await yieldUntil { codex.askCalls.count == 2 }
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertEqual(controller.run?.status, .thinking)
        XCTAssertEqual(codex.askCalls[1].transcript.contains("Question:\nread that"), true)
    }

    func testStopSpeakingCardCommandRestoresCompletedCardAndStops() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        var stopCount = 0
        controller.stopSpeaking = { stopCount += 1 }

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Original question",
            answer: "Previous answer."
        )

        controller.beginListening()
        stopCount = 0
        controller.submit("stop talking")

        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(controller.run?.status, .completed)
        XCTAssertEqual(controller.run?.answerText, "Previous answer.")
    }

    func testAutoSpeakFiresOnceWhenEnabledAndAvailable() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var spoken: [String] = []
        controller.speakAnswer = { spoken.append($0) }

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Question?",
            answer: "Answer."
        )

        XCTAssertEqual(spoken, ["Answer."])
    }

    // MARK: - Streaming TTS (grok auto-speak)

    func testGrokAutoSpeakStreamsIncrementalSpeech() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed: [(text: String, isStart: Bool)] = []
        var finishCount = 0
        var fullSpoken: [String] = []
        controller.speakStreamingText = { text, isStart in streamed.append((text, isStart)) }
        controller.finishStreamingSpeech = { finishCount += 1 }
        controller.speakAnswer = { fullSpoken.append($0) }

        controller.beginListening()
        controller.submit("Where is Paris?")
        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "Paris is nice. "))
        await pushGrok(grok, event: .text(delta: "It sits on the Seine. "))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }

        let finalAnswer = controller.run?.answerText ?? ""
        let expected = AskAnswerBlock.speakableText(from: finalAnswer)
        XCTAssertEqual(streamed.map(\.text).joined(), expected)
        XCTAssertEqual(streamed.first?.isStart, true)
        XCTAssertTrue(streamed.dropFirst().allSatisfy { !$0.isStart })
        XCTAssertEqual(finishCount, 1)
        XCTAssertTrue(fullSpoken.isEmpty)
    }

    // MARK: - Fused narration and glued deltas

    func testCompletedCardStripsFusedNarrationAndRepairsGlue() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false

        controller.beginListening()
        controller.submit("When are the next games?")
        await yieldUntil { grok.askCalls.count == 1 }

        // Narration glued straight onto the answer, missing the space after
        // the terminator — the field case.
        await pushGrok(grok, event: .text(
            delta: "I'll look up the current schedule for the next matches.Context is mid-July — checking the tournament. "
        ))
        await pushGrok(grok, event: .text(delta: "Next up: the semi-finals. The first is today."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }

        XCTAssertEqual(controller.run?.answerText, "Next up: the semi-finals. The first is today.")
        XCTAssertEqual(controller.run?.result, "Next up: the semi-finals. The first is today.")
    }

    // MARK: - Card-tap pin vs action buttons

    func testPinFromSameClickIsNotDeliberateRegardlessOfGestureOrder() {
        let (controller, _, _) = makeController()
        var now = 100.0
        controller.metricsClock = { now }

        // Gesture half of a Stop click lands BEFORE the button action: the pin
        // it just created must not read as a deliberate earlier pin.
        controller.pinFromCardTap()
        XCTAssertTrue(controller.pillPinned)
        XCTAssertFalse(controller.pillPinnedBeforeCurrentClick,
                       "a pin born from the current click must be classified as unwanted")

        // The same pin, aged past the click window, is a deliberate pin.
        now += 1.0
        XCTAssertTrue(controller.pillPinnedBeforeCurrentClick)

        // Pins from non-click paths (voice command, show-from-history) are
        // always deliberate.
        controller.pillPinned = false
        controller.pillPinned = true
        XCTAssertTrue(controller.pillPinnedBeforeCurrentClick)
    }

    func testGrokStreamingSpeechReevaluatesBoundaryOnLookaheadDelta() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed: [(text: String, isStart: Bool)] = []
        controller.speakStreamingText = { text, isStart in streamed.append((text, isStart)) }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "This is sentence one."))
        XCTAssertTrue(streamed.isEmpty)

        await pushGrok(grok, event: .text(delta: " and more words arrive"))

        XCTAssertEqual(streamed.count, 1)
        XCTAssertTrue(streamed[0].text.contains("This is sentence one."))
        XCTAssertTrue(streamed[0].isStart)
    }

    func testFirstEmissionSpeaksLeadingClauseBeforeSentenceCompletes() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed: [(text: String, isStart: Bool)] = []
        controller.speakStreamingText = { text, isStart in streamed.append((text, isStart)) }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { grok.askCalls.count == 1 }

        // 78 chars up to the comma, plain prose, lookahead present — the clause
        // gate should speak it without waiting for the sentence terminator.
        await pushGrok(grok, event: .text(
            delta: "Yes, macOS Tahoe fully supports Apple Intelligence on every M-series Mac model, and even"
        ))

        XCTAssertEqual(streamed.count, 1)
        XCTAssertTrue(streamed[0].text.hasSuffix(","), "clause emission ends at the comma: \(streamed)")
        XCTAssertTrue(streamed[0].isStart)

        // The sentence completion must extend the clause exactly (prefix rule).
        await pushGrok(grok, event: .text(delta: " older machines handle it. Next"))
        XCTAssertEqual(streamed.count, 2)
        XCTAssertFalse(streamed[1].isStart)
        XCTAssertTrue(streamed[1].text.hasPrefix(" and even"), "remainder continues the clause: \(streamed)")
    }

    func testLeadingClausePendingBoundaryFiresOnPunctuationFreeLookaheadDelta() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed: [(text: String, isStart: Bool)] = []
        controller.speakStreamingText = { text, isStart in streamed.append((text, isStart)) }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { grok.askCalls.count == 1 }

        // Delta ends exactly at the clause comma — no lookahead yet.
        await pushGrok(grok, event: .text(
            delta: "Yes, macOS Tahoe fully supports Apple Intelligence on every M-series Mac model,"
        ))
        XCTAssertTrue(streamed.isEmpty)

        // The lookahead arrives in a punctuation-free delta; the pending
        // boundary must force re-evaluation and speak the clause.
        await pushGrok(grok, event: .text(delta: " and even older machines"))
        XCTAssertEqual(streamed.count, 1)
        XCTAssertTrue(streamed[0].text.hasSuffix(","))
        XCTAssertTrue(streamed[0].isStart)
    }

    func testCodexAutoSpeakStreamsBeforeCompletionThenSpeaksRemainder() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed: [(text: String, isStart: Bool)] = []
        var finishCount = 0
        controller.speakStreamingText = { text, isStart in streamed.append((text, isStart)) }
        controller.finishStreamingSpeech = { finishCount += 1 }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: "First sentence."))
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: " Second sentence. trailing remainder"))

        XCTAssertFalse(streamed.isEmpty)
        XCTAssertEqual(streamed.first?.isStart, true)
        XCTAssertEqual(finishCount, 0)
        let countBeforeCompletion = streamed.count

        await pushCodex(codex, event: .turnCompleted(failureMessage: nil))
        await yieldUntil { controller.run?.status == .completed }

        XCTAssertEqual(streamed.count, countBeforeCompletion + 1)
        XCTAssertEqual(streamed.last?.isStart, false)
        XCTAssertTrue(streamed.last?.text.contains("trailing remainder") == true)
        XCTAssertEqual(finishCount, 1)
    }

    func testCodexNarrationDeltasNeverFeedStreamingSpeech() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed = 0
        controller.speakStreamingText = { _, _ in streamed += 1 }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .agentMessageStarted(itemID: "work1", phase: "commentary"))
        await pushCodex(codex, event: .agentMessageDelta(itemID: "work1", delta: "Searching now. More follows."))

        XCTAssertEqual(streamed, 0)
    }

    func testCodexStreamingSpeechDivergenceEndsWithoutSpeakingAuthoritativeText() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed: [(text: String, isStart: Bool)] = []
        var finishCount = 0
        controller.speakStreamingText = { text, isStart in streamed.append((text, isStart)) }
        controller.finishStreamingSpeech = { finishCount += 1 }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: "Original prefix."))
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: " lookahead"))
        XCTAssertEqual(streamed.count, 1)

        await pushCodex(codex, event: .agentMessageCompleted(itemID: "msg1", phase: "final_answer", text: "Different authoritative answer."))
        await pushCodex(codex, event: .turnCompleted(failureMessage: nil))
        await yieldUntil { controller.run?.status == .completed }

        XCTAssertEqual(streamed.count, 1)
        XCTAssertEqual(finishCount, 1)
    }

    func testFirstAnswerTokenWarmsAudioOncePerRunWhenSpeechAvailable() async {
        let codex = FakeCodexClient()
        let (codexController, _, _) = makeController(codex: codex)
        codexController.saveHistory = false
        codexController.speakAvailable = true
        var codexWarmCount = 0
        codexController.warmAudioOutput = { codexWarmCount += 1 }

        codexController.beginListening()
        codexController.submit("Codex question?")
        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: "First"))
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: " second"))
        XCTAssertEqual(codexWarmCount, 1)

        let grok = FakeGrokClient()
        let (grokController, _, _) = makeController(grok: grok)
        grokController.backend = .grok
        grokController.saveHistory = false
        grokController.speakAvailable = true
        var grokWarmCount = 0
        grokController.warmAudioOutput = { grokWarmCount += 1 }

        grokController.beginListening()
        grokController.submit("Grok question?")
        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "First"))
        await pushGrok(grok, event: .text(delta: " second"))
        XCTAssertEqual(grokWarmCount, 1)
    }

    func testFirstAnswerTokenDoesNotWarmAudioWhenSpeechUnavailable() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        controller.speakAvailable = false
        var warmCount = 0
        controller.warmAudioOutput = { warmCount += 1 }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { codex.askCalls.count == 1 }
        await pushCodex(codex, event: .agentMessageDelta(itemID: "msg1", delta: "Answer"))

        XCTAssertEqual(warmCount, 0)
    }

    func testCodexAutoSpeakUsesFullAnswerPathUnchanged() async {
        let codex = FakeCodexClient()
        let (controller, _, _) = makeController(codex: codex)
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed = 0
        var finishCount = 0
        var spoken: [String] = []
        controller.speakStreamingText = { _, _ in streamed += 1 }
        controller.finishStreamingSpeech = { finishCount += 1 }
        controller.speakAnswer = { spoken.append($0) }

        await completeCodexRun(
            controller: controller,
            codex: codex,
            question: "Question?",
            answer: "Answer."
        )

        XCTAssertEqual(streamed, 0)
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(spoken, ["Answer."])
    }

    func testGrokAutoSpeakDisabledSkipsStreaming() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        controller.autoSpeak = false
        controller.speakAvailable = true
        var streamed = 0
        var finishCount = 0
        var fullSpoken = 0
        controller.speakStreamingText = { _, _ in streamed += 1 }
        controller.finishStreamingSpeech = { finishCount += 1 }
        controller.speakAnswer = { _ in fullSpoken += 1 }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "An answer."))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .completed }

        XCTAssertEqual(streamed, 0)
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(fullSpoken, 0)
    }

    func testGrokAbortMidStreamStopsStreamingWithoutFinish() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed: [(text: String, isStart: Bool)] = []
        var finishCount = 0
        controller.speakStreamingText = { text, isStart in streamed.append((text, isStart)) }
        controller.finishStreamingSpeech = { finishCount += 1 }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "Partial answer. "))
        XCTAssertFalse(streamed.isEmpty)

        let countBeforeAbort = streamed.count
        controller.abort()
        await pushGrok(grok, event: .text(delta: "More text. "))
        await pushGrok(grok, event: .end(stopReason: "EndTurn", sessionId: nil))
        await yieldUntil { controller.run?.status == .cancelled }

        XCTAssertEqual(streamed.count, countBeforeAbort)
        XCTAssertEqual(finishCount, 0)
    }

    func testGrokStreamingSpeechThrottleRequiresSentenceTerminator() async {
        let grok = FakeGrokClient()
        let (controller, _, _) = makeController(grok: grok)
        controller.backend = .grok
        controller.saveHistory = false
        controller.autoSpeak = true
        controller.speakAvailable = true
        var streamed: [(text: String, isStart: Bool)] = []
        controller.speakStreamingText = { text, isStart in streamed.append((text, isStart)) }

        controller.beginListening()
        controller.submit("Question?")
        await yieldUntil { grok.askCalls.count == 1 }
        await pushGrok(grok, event: .text(delta: "abc"))
        await pushGrok(grok, event: .text(delta: "def"))
        XCTAssertTrue(streamed.isEmpty)

        // Terminator at the buffer end is held until more stream follows it
        // (see AskAnswerBlocksTests.testStablePrefixHoldsSentenceAtBufferEnd).
        await pushGrok(grok, event: .text(delta: "ghi. "))
        XCTAssertFalse(streamed.isEmpty)
        let expected = AskAnswerBlock.speakableText(from: "abcdefghi. ")
        XCTAssertEqual(streamed.map(\.text).joined(), expected)
        XCTAssertEqual(streamed.first?.isStart, true)
    }

    func testAutoSpeakDoesNotFireWhenDisabledOrUnavailable() async {
        let unavailableCodex = FakeCodexClient()
        let (unavailable, _, _) = makeController(codex: unavailableCodex)
        unavailable.saveHistory = false
        unavailable.autoSpeak = true
        unavailable.speakAvailable = false
        var unavailableSpoken = 0
        unavailable.speakAnswer = { _ in unavailableSpoken += 1 }

        await completeCodexRun(
            controller: unavailable,
            codex: unavailableCodex,
            question: "Question?",
            answer: "Answer."
        )
        XCTAssertEqual(unavailableSpoken, 0)

        let disabledCodex = FakeCodexClient()
        let (disabled, _, _) = makeController(codex: disabledCodex)
        disabled.saveHistory = false
        disabled.autoSpeak = false
        disabled.speakAvailable = true
        var disabledSpoken = 0
        disabled.speakAnswer = { _ in disabledSpoken += 1 }

        await completeCodexRun(
            controller: disabled,
            codex: disabledCodex,
            question: "Question?",
            answer: "Answer."
        )
        XCTAssertEqual(disabledSpoken, 0)
    }

    func testDismissAbortAndBargeInStopSpeaking() async {
        let dismissCodex = FakeCodexClient()
        let (dismissController, _, _) = makeController(codex: dismissCodex)
        dismissController.saveHistory = false
        var dismissStops = 0
        dismissController.stopSpeaking = { dismissStops += 1 }
        await completeCodexRun(
            controller: dismissController,
            codex: dismissCodex,
            question: "Question?",
            answer: "Answer."
        )
        dismissController.dismiss()
        XCTAssertEqual(dismissStops, 1)

        let abortCodex = FakeCodexClient()
        let (abortController, _, _) = makeController(codex: abortCodex)
        abortController.saveHistory = false
        var abortStops = 0
        abortController.stopSpeaking = { abortStops += 1 }
        abortController.beginListening()
        abortController.submit("Streaming question")
        await yieldUntil { abortCodex.askCalls.count == 1 }
        await pushCodex(abortCodex, event: .turnStarted)
        abortController.abort()
        XCTAssertEqual(abortStops, 1)

        let bargeCodex = FakeCodexClient()
        let (bargeController, _, _) = makeController(codex: bargeCodex)
        bargeController.saveHistory = false
        var bargeStops = 0
        bargeController.stopSpeaking = { bargeStops += 1 }
        bargeController.beginListening()
        bargeController.submit("Streaming question")
        await yieldUntil { bargeCodex.askCalls.count == 1 }
        await pushCodex(bargeCodex, event: .turnStarted)
        await pushCodex(bargeCodex, event: .agentMessageDelta(itemID: "msg1", delta: "Partial"))
        await yieldUntil { bargeController.run?.status == .working }
        bargeController.beginListening()
        XCTAssertEqual(bargeStops, 1)

        let completedCodex = FakeCodexClient()
        let (completedController, _, _) = makeController(codex: completedCodex)
        completedController.saveHistory = false
        var completedStops = 0
        completedController.stopSpeaking = { completedStops += 1 }
        await completeCodexRun(
            controller: completedController,
            codex: completedCodex,
            question: "Original question",
            answer: "Previous answer."
        )
        completedController.beginListening()
        XCTAssertEqual(completedStops, 1)
    }

}

// MARK: - TTS first-chunk pad

final class FirstChunkPadMsTests: XCTestCase {
    func testBuiltInRecentOutputGetsShortPad() {
        XCTAssertEqual(
            AppDelegate.firstChunkPadMs(isBuiltInOutput: true, secondsSinceLastOutput: 5.0),
            80
        )
    }

    func testBuiltInStaleOutputGetsFullPad() {
        XCTAssertEqual(
            AppDelegate.firstChunkPadMs(isBuiltInOutput: true, secondsSinceLastOutput: 15.0),
            280
        )
    }

    func testBuiltInNoPriorOutputGetsFullPad() {
        XCTAssertEqual(
            AppDelegate.firstChunkPadMs(isBuiltInOutput: true, secondsSinceLastOutput: nil),
            280
        )
    }

    func testNonBuiltInRecentOutputStillGetsFullPad() {
        XCTAssertEqual(
            AppDelegate.firstChunkPadMs(isBuiltInOutput: false, secondsSinceLastOutput: 5.0),
            280
        )
    }
}
