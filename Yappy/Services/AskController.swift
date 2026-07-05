//
//  AskController.swift
//  Yappy
//
//  Orchestrates one Ask run: takes a transcribed question, dispatches it to the
//  selected backend (Codex gpt-5.5 or Grok), and streams the answer + research
//  steps into `run` for the pill. Adapted from VoiceAgent's store, stripped to
//  the question-answering path — no audio/STT (Yappy owns capture), no MCP
//  bridge, no computer tools, no approval.
//

import Foundation
import Combine
import QuartzCore

/// Which CLI answers an Ask question.
enum AskBackend: String, CaseIterable, Identifiable, Sendable {
    case codex
    case grok

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .codex: "Codex (gpt-5.5)"
        case .grok: "Grok"
        }
    }
}

/// Which xAI model answers when the Grok backend is selected. Always passed
/// explicitly via `-m` — the CLI's own default has changed between releases
/// (composer-2.5-fast → grok-build), so relying on it would silently reroute.
enum AskGrokModel: String, CaseIterable, Identifiable, Sendable {
    case composerFast = "grok-composer-2.5-fast"
    case build = "grok-build"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .composerFast: "Composer 2.5 Fast"
        case .build: "Grok Build"
        }
    }
}

/// The curated Kokoro voice roster Yappy exposes for reading Answers aloud.
/// Balanced across American and British accents (two female, two male each),
/// with `af_heart` (Kokoro's grade-A flagship) as the default. Every voice here
/// synthesizes cleanly at nominal speed; the helper's speed-jitter retry is the
/// safety net for the rare vocoder length glitch. Raw values are Kokoro voice
/// pack IDs (a=American, b=British; f=female, m=male).
enum AnswersVoice: String, CaseIterable, Identifiable, Sendable {
    case afHeart = "af_heart"
    case afBella = "af_bella"
    case amFenrir = "am_fenrir"
    case amPuck = "am_puck"
    case bfEmma = "bf_emma"
    case bfIsabella = "bf_isabella"
    case bmGeorge = "bm_george"
    case bmFable = "bm_fable"

    var id: String { rawValue }

    /// The bare given name, used when the voice introduces itself in a preview.
    var spokenName: String {
        switch self {
        case .afHeart: "Heart"
        case .afBella: "Bella"
        case .amFenrir: "Fenrir"
        case .amPuck: "Puck"
        case .bfEmma: "Emma"
        case .bfIsabella: "Isabella"
        case .bmGeorge: "George"
        case .bmFable: "Fable"
        }
    }

    /// Name plus accent, shown in the Settings picker.
    var displayName: String {
        let accent = rawValue.hasPrefix("b") ? "British" : "American"
        return "\(spokenName) (\(accent))"
    }
}

enum AskCardCommand: Equatable {
    case copy
    case insert
    case dismiss
    case retry
    case pin
    case speak
    case stopSpeaking

    private static let phrases: [String: AskCardCommand] = [
        "copy that": .copy,
        "copy it": .copy,
        "copy the answer": .copy,
        "insert that": .insert,
        "insert it": .insert,
        "insert the answer": .insert,
        "type that": .insert,
        "dismiss": .dismiss,
        "close": .dismiss,
        "dismiss that": .dismiss,
        "close that": .dismiss,
        "try again": .retry,
        "ask again": .retry,
        "retry": .retry,
        "pin that": .pin,
        "pin it": .pin,
        "keep that": .pin,
        "speak that": .speak,
        "read that": .speak,
        "read it": .speak,
        "read that aloud": .speak,
        "say it aloud": .speak,
        "read the answer": .speak,
        "stop talking": .stopSpeaking,
        "stop reading": .stopSpeaking,
        "stop speaking": .stopSpeaking,
    ]

    static func parse(_ transcript: String) -> AskCardCommand? {
        phrases[normalize(transcript)]
    }

    private static func normalize(_ transcript: String) -> String {
        var normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.last == "." || normalized.last == "!" {
            normalized.removeLast()
        }
        return normalized
    }
}

enum AskSpeakingPhase: Equatable {
    case idle
    case synthesizing
    case speaking
}

@MainActor
final class AskController: ObservableObject {
    /// The active run — drives the pill. Nil when idle.
    @Published private(set) var run: AskRun?
    @Published private(set) var speakingPhase: AskSpeakingPhase = .idle
    /// Rolling microphone amplitude ring for the listening waveform. AppDelegate
    /// pushes real levels during capture.
    @Published var audioLevels: [Double] = Array(repeating: 0.18, count: 16)
    /// True while the cursor is over the pill — auto-dismiss waits for the user
    /// to leave so an answer is never yanked away mid-read or mid-copy.
    @Published var pillHovered = false
    /// True once the user clicks into the answer (or re-summons one) — the pill
    /// then stays until explicitly dismissed (✕ / Escape / next Ask).
    @Published var pillPinned = false

    /// Completed Q&A pairs, persisted so answers can be re-read after the pill
    /// dismisses (main window → Ask, menu bar → Show Last Answer).
    let history: AskHistoryStore

    /// Selected backend for the NEXT question. Set by AppDelegate from the
    /// `askBackend` setting. The active run keeps its own snapshot
    /// (`activeBackend`) so flipping the picker mid-run can't strand the run's
    /// event stream or misroute its abort.
    var backend: AskBackend = .codex
    /// Whether a backend can answer right now. Set by AppDelegate from cheap
    /// client probes so submit() can fall back without re-probing on the hot path.
    var backendUsable: (AskBackend) -> Bool = { _ in true }
    /// Injected by AppDelegate; routes through the same TextInserter dictation uses.
    var insertText: (String) -> Void = { _ in }
    /// Injected by AppDelegate; keeps pasteboard writes out of this Foundation-only service.
    var copyText: (String) -> Void = { _ in }
    /// Published so the answer card's Speak button appears the moment TTS becomes
    /// available — the readiness probe resolves asynchronously, so a plain var
    /// would leave an already-visible card without the button.
    @Published var speakAvailable = false
    var autoSpeak = false
    var speakAnswer: (String) -> Void = { _ in }
    var stopSpeaking: () -> Void = { }
    /// The voice rawValue currently being previewed in Settings (synthesizing or
    /// playing), else nil. Drives the preview button's play/stop state.
    @Published var previewingVoice: String?
    /// Injected by AppDelegate; synthesizes and plays a short sample in a voice.
    var startVoicePreview: (String) -> Void = { _ in }
    /// Injected by AppDelegate; stops any voice preview in progress.
    var stopVoicePreview: () -> Void = { }
    /// Which xAI model the Grok backend uses. Set by AppDelegate from settings.
    var grokModel: AskGrokModel = .composerFast
    /// Whether completed runs are persisted to Ask history. Mirrors
    /// `settings.askSaveHistoryEnabled`; set by AppDelegate.
    var saveHistory = true
    /// The backend the current run was dispatched to, snapshotted at submit().
    private var activeBackend: AskBackend = .codex

    struct AskRunMetrics {
        var dispatchedAt: Double?
        var firstEventAt: Double?
        var firstAnswerTokenAt: Double?
        var completedAt: Double?
    }
    private(set) var lastRunMetrics = AskRunMetrics()
    var metricsClock: () -> Double = { CACurrentMediaTime() }

    private let codexClient: any CodexAsking
    private let grokClient: any GrokAsking
    /// The in-flight codex dispatch (awaiting turn/start), retained so abort()
    /// can cancel it and the post-await path can clean up an orphaned turn.
    private var dispatchTask: Task<Void, Never>?
    /// Turn IDs cleared for a continuation — stray events from the prior turn
    /// must not be adopted as the new turn's ID.
    private var rejectedTurnIDs: Set<String> = []
    private var activityWatchdog: Task<Void, Never>?
    /// Seconds to wait for the first backend event before failing the run.
    var firstActivityTimeout: TimeInterval = 20

    /// agentMessage item IDs whose phase marks them as working narration
    /// (preamble/plan text) rather than the final answer — kept out of the answer.
    private var narrationItemIDs: Set<String> = []
    /// True when the current capture started from a completed card, so a whole
    /// utterance can target that visible answer instead of becoming a follow-up.
    private var capturedOverCompletedCard = false
    private var thinkingTitle = "Thinking"
    private var thoughtTitle = "Thought"

    nonisolated static func parseCardCommand(_ transcript: String) -> AskCardCommand? {
        AskCardCommand.parse(transcript)
    }

    nonisolated static func extractThinkHarder(_ transcript: String) -> (question: String, thinkHarder: Bool) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        for marker in ["think harder", "think hard"] {
            guard lowercased == marker || lowercased.hasPrefix(marker) else { continue }

            let markerEnd = trimmed.index(trimmed.startIndex, offsetBy: marker.count)
            var remainder = String(trimmed[markerEnd...])
            let lowerRemainder = remainder.lowercased()

            if lowerRemainder.hasPrefix(",") || lowerRemainder.hasPrefix(".") {
                remainder.removeFirst()
            } else if lowerRemainder.hasPrefix(" and") {
                remainder.removeFirst(" and".count)
            } else if lowerRemainder.hasPrefix(" about") {
                remainder.removeFirst(" about".count)
            } else if lowerRemainder.first?.isWhitespace == true {
                // The modifier phrase can be spoken without punctuation.
            } else if remainder.isEmpty {
                return (trimmed, false)
            } else {
                continue
            }

            let question = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            return question.isEmpty ? (trimmed, false) : (question, true)
        }

        return (trimmed, false)
    }

    /// Splits speakable text into synthesis chunks. `firstLimit` (when smaller
    /// than `limit`) caps the FIRST chunk so first audio arrives sooner — the
    /// opening sentence synthesizes fast while the rest render during playback.
    nonisolated static func speechChunks(_ text: String, limit: Int = 280, firstLimit: Int? = nil) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var sentences: [String] = []
        var start = text.startIndex
        var index = text.startIndex

        func appendSentence(upTo end: String.Index) {
            let sentence = String(text[start..<end])
            if !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(sentence)
            }
            start = end
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" {
                appendSentence(upTo: next)
                index = start
                continue
            }
            if character == "." || character == "!" || character == "?",
               next < text.endIndex,
               text[next] == " " {
                appendSentence(upTo: text.index(after: next))
                index = start
                continue
            }
            index = next
        }
        appendSentence(upTo: text.endIndex)

        let limit = max(1, limit)
        let firstCap = max(1, firstLimit ?? limit)
        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            // The first emitted chunk uses the smaller cap; every chunk after it
            // uses the full limit.
            let cap = chunks.isEmpty ? firstCap : limit
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count <= cap {
                current += sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    init(
        codexClient: any CodexAsking = CodexAskClient(),
        grokClient: any GrokAsking = GrokAskClient(),
        history: AskHistoryStore? = nil
    ) {
        self.codexClient = codexClient
        self.grokClient = grokClient
        self.history = history ?? AskHistoryStore()
        codexClient.onNotification = { [weak self] envelope in
            Task { @MainActor [weak self] in self?.handleCodexEvent(envelope) }
        }
        grokClient.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleGrokEvent(event) }
        }
    }

    // MARK: - Coarse state (for AppDelegate wiring)

    var status: AskRunStatus { run?.status ?? .idle }
    /// Busy from the moment the Fn key goes down until the run is terminal —
    /// blocks dictation / scratchpad while Ask owns the shared audio engine.
    var isBusy: Bool {
        guard let s = run?.status else { return false }
        return !s.isTerminal
    }
    var isListening: Bool { run?.status == .listening }
    var isExecuting: Bool { run?.status == .thinking || run?.status == .working }

    // MARK: - Lifecycle (driven by AppDelegate's capture path)

    /// Warms the selected backend so a spoken question streams without setup
    /// latency. Cheap when already warm (Codex thread or Grok agent session).
    func prewarm() {
        switch backend {
        case .codex: Task { await codexClient.prewarm() }
        case .grok:  Task { await grokClient.prewarm() }
        }
    }

    func shutdown() {
        codexClient.stop()
        grokClient.stop()
    }

    /// One resident helper at a time: tears down the warm client of whichever
    /// backend is NOT selected (prewarm() (re)warms the selected one).
    func shutdownDeselectedBackend() {
        switch backend {
        case .codex: grokClient.stop()
        case .grok: codexClient.stop()
        }
    }

    /// Fn pressed while the speech model is still loading — show the pill in a
    /// compact "Getting ready…" state; recording begins when the model is ready.
    func beginPreparing() {
        rejectedTurnIDs.removeAll()
        run = AskRun(rawTranscript: "", status: .preparing)
        audioLevels = Array(repeating: 0.18, count: 16)
        pillPinned = false
        capturedOverCompletedCard = false
        prewarm()
    }

    /// Fn pressed — begin a run and warm the backend while the user speaks.
    func beginListening() {
        if var r = run, r.status == .preparing {
            try? r.transition(to: .listening)
            run = r
            return
        }
        if var r = run, r.status == .thinking || r.status == .working {
            // Barge-in: interrupt the turn, keep the conversation.
            stopSpeaking()
            dispatchTask?.cancel()
            switch activeBackend {
            case .codex:
                if let thread = r.codexThreadID, let turn = r.codexTurnID {
                    codexClient.interrupt(threadID: thread, turnID: turn)
                }
            case .grok:
                grokClient.cancel()
            }
            VLog.store("barge-in — interrupted \(activeBackend.rawValue) run \(r.id)")
            r.rawTranscript = ""
            r.steps.removeAll()
            r.answerText = nil
            r.result = nil
            if let t = r.codexTurnID { rejectedTurnIDs.insert(t) }
            r.codexTurnID = nil
            r.completedAt = nil
            try? r.transition(to: .listening)
            run = r
            narrationItemIDs.removeAll()
            audioLevels = Array(repeating: 0.18, count: 16)
            pillPinned = false
            capturedOverCompletedCard = false
            prewarm()
            return
        }
        if var r = run, r.status == .completed {
            stopSpeaking()
            capturedOverCompletedCard = true
            r.turns.append(AskTurn(question: r.rawTranscript, answer: r.result ?? r.answerText ?? ""))
            r.rawTranscript = ""
            r.steps.removeAll()
            r.answerText = nil
            r.result = nil
            if let t = r.codexTurnID { rejectedTurnIDs.insert(t) }
            r.codexTurnID = nil
            r.completedAt = nil
            try? r.transition(to: .listening)
            run = r
            narrationItemIDs.removeAll()
            audioLevels = Array(repeating: 0.18, count: 16)
            pillPinned = false
            prewarm()
            return
        }
        capturedOverCompletedCard = false
        rejectedTurnIDs.removeAll()
        run = AskRun(rawTranscript: "", status: .listening)
        audioLevels = Array(repeating: 0.18, count: 16)
        pillPinned = false
        prewarm()
    }

    func pushAudioLevel(_ level: Double) {
        let clamped = max(0.12, min(1.0, level))
        audioLevels.append(clamped)
        if audioLevels.count > 16 {
            audioLevels.removeFirst(audioLevels.count - 16)
        }
    }

    /// STT started (Fn released, samples captured).
    func markTranscribing() {
        guard var r = run, r.status == .listening else { return }
        try? r.transition(to: .transcribing)
        run = r
    }

    /// Hand the transcribed question to the backend.
    func submit(_ transcript: String) {
        guard var r = run else { return }
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { cancelCapture(); return }

        if capturedOverCompletedCard {
            if let command = Self.parseCardCommand(question) {
                if command == .speak, !speakAvailable {
                    capturedOverCompletedCard = false
                } else {
                    performCardCommand(command)
                    return
                }
            } else {
                capturedOverCompletedCard = false
            }
        }

        let extracted = Self.extractThinkHarder(question)
        configureThinkingTitles(thinkHarder: extracted.thinkHarder)

        r.rawTranscript = extracted.question
        r.thinkHarder = extracted.thinkHarder
        if r.status == .listening { try? r.transition(to: .transcribing) }
        try? r.transition(to: .thinking)
        run = r
        dispatch(question: extracted.question, runID: r.id, thinkHarder: extracted.thinkHarder)
    }

    /// Re-ask the current question as a fresh run (new thread, steps reset).
    func retry() {
        guard let r = run, r.status.isTerminal else { return }
        let question = r.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        pillPinned = false
        narrationItemIDs.removeAll()
        let thinkHarder = r.thinkHarder
        configureThinkingTitles(thinkHarder: thinkHarder)
        let fresh = AskRun(rawTranscript: question, status: .thinking, thinkHarder: thinkHarder)
        run = fresh
        dispatch(question: question, runID: fresh.id, thinkHarder: thinkHarder)
    }

    func insertAnswer() {
        guard let r = run, r.status == .completed else { return }
        let answer = r.result ?? r.answerText ?? ""
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = AskAnswerBlock.plainText(from: answer)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        insertText(text)
        dismiss()
    }

    func setSpeakingPhase(_ phase: AskSpeakingPhase) {
        speakingPhase = phase
    }

    func speakCurrentAnswer() {
        guard let r = run, r.status == .completed else { return }
        let answer = r.result ?? r.answerText ?? ""
        guard speakAvailable, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speakAnswer(answer)
    }

    func stopSpeakingNow() {
        stopSpeaking()
    }

    /// Fn released before anything was said, or a keyboard chord (fn+arrow) was
    /// detected while listening — discard the capture cleanly. Nothing was
    /// asked, so nothing lingers: a follow-up capture gives back the completed
    /// card it borrowed; a fresh capture just fades out. (A `.cancelled` run
    /// here would park a near-empty "Done." card on screen.)
    func cancelCapture() {
        capturedOverCompletedCard = false
        guard let r = run, r.status == .listening || r.status == .transcribing || r.status == .preparing else { return }
        narrationItemIDs.removeAll()
        if r.turns.isEmpty {
            run = nil
        } else {
            _ = restoreCompletedCard()
        }
    }

    /// Stop button / Escape — interrupt an in-flight turn. Dispatches on the
    /// run's snapshotted backend (not the live picker value). If codex is still
    /// awaiting turn/start, the dispatch task's post-await cleanup interrupts
    /// the orphaned turn as soon as its IDs are known.
    func abort() {
        abort(stopSpeech: true)
    }

    private func abort(stopSpeech: Bool) {
        guard let r = run, !r.status.isTerminal else { return }
        if stopSpeech { stopSpeaking() }
        // During capture nothing has been dispatched — there is no turn to
        // interrupt and no partial answer worth keeping. Discard like any
        // empty capture instead of parking a "Stopped." card.
        if r.status == .preparing || r.status == .listening || r.status == .transcribing {
            cancelCapture()
            return
        }
        capturedOverCompletedCard = false
        cancelActivityWatchdog()
        VLog.store("abort — interrupting \(activeBackend.rawValue) run \(r.id)")
        dispatchTask?.cancel()
        switch activeBackend {
        case .codex:
            if let thread = r.codexThreadID, let turn = r.codexTurnID {
                codexClient.interrupt(threadID: thread, turnID: turn)
            }
        case .grok:
            grokClient.cancel()
        }
        var run = r
        run.result = run.answerText ?? "Stopped."
        try? run.transition(to: .cancelled)
        self.run = run
        narrationItemIDs.removeAll()
        scheduleAutoDismiss(run)
    }

    /// Pill ✕ — clear immediately (aborts first if still running).
    func dismiss() {
        stopSpeaking()
        if let r = run, !r.status.isTerminal { abort(stopSpeech: false) }
        cancelActivityWatchdog()
        rejectedTurnIDs.removeAll()
        run = nil
        pillPinned = false
        capturedOverCompletedCard = false
    }

    /// Re-summons the most recent completed answer into the pill, pinned (no
    /// auto-dismiss). Menu bar → "Show Last Answer".
    func showLastAnswer() {
        guard let entry = history.last else { return }
        showEntry(entry)
    }

    /// Re-summons a specific history entry into the pill, pinned.
    func showEntry(_ entry: AskHistoryEntry) {
        guard !isBusy else { return }
        pillPinned = true
        run = AskRun(
            rawTranscript: entry.question,
            status: .completed,
            answerText: entry.answer,
            result: entry.answer,
            modelLabel: entry.modelLabel,
            createdAt: entry.date,
            completedAt: entry.date
        )
    }

    // MARK: - Backend dispatch

    private func performCardCommand(_ command: AskCardCommand) {
        switch command {
        case .copy:
            guard let answer = restoreCompletedCard() else { return }
            copyText(answer)

        case .insert:
            guard let answer = restoreCompletedCard() else { return }
            let text = AskAnswerBlock.plainText(from: answer)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            insertText(text)
            dismiss()

        case .dismiss:
            _ = restoreCompletedCard()
            dismiss()

        case .retry:
            guard restoreCompletedCard() != nil else { return }
            retry()

        case .pin:
            guard restoreCompletedCard() != nil else { return }
            pillPinned = true

        case .speak:
            guard speakAvailable else { return }
            guard restoreCompletedCard() != nil else { return }
            speakCurrentAnswer()

        case .stopSpeaking:
            guard restoreCompletedCard() != nil else { return }
            stopSpeakingNow()
        }
    }

    private func restoreCompletedCard() -> String? {
        capturedOverCompletedCard = false
        guard var current = run, let turn = current.turns.popLast() else { return nil }
        let restored = AskRun(
            rawTranscript: turn.question,
            status: .completed,
            turns: current.turns,
            answerText: turn.answer,
            result: turn.answer,
            codexThreadID: current.codexThreadID,
            grokSessionID: current.grokSessionID,
            modelLabel: current.modelLabel,
            createdAt: current.createdAt,
            completedAt: Date()
        )
        run = restored
        // The rebuilt run has a fresh id, so the popped run's linger timer died
        // with it — re-arm the countdown or a "copy that" card lingers forever.
        // (Pin loops the timer; retry/insert/dismiss replace or clear the run,
        // whose id guards make this timer a no-op.)
        scheduleAutoDismiss(restored)
        return turn.answer
    }

    private func configureThinkingTitles(thinkHarder: Bool) {
        thinkingTitle = thinkHarder ? "Thinking harder" : "Thinking"
        thoughtTitle = thinkHarder ? "Thought hard" : "Thought"
    }

    private func dispatch(question: String, runID: UUID, thinkHarder: Bool) {
        // Fall back to the other backend when the selected one isn't usable but
        // the other is — persist the switch so the next question keeps it.
        var backendForRun = backend
        let other: AskBackend = backendForRun == .codex ? .grok : .codex
        if !backendUsable(backendForRun), backendUsable(other) {
            VLog.store("backend fallback — \(backendForRun.rawValue) unusable, using \(other.rawValue)")
            backendForRun = other
            backend = other
        }
        // Snapshot the backend for this run — the live `backend` may change
        // mid-run (Settings picker) and must only affect the NEXT question.
        activeBackend = backendForRun
        if var r = run, r.id == runID {
            r.modelLabel = modelLabel(for: activeBackend)
            upsertStep(kind: .generic, title: "Asking \(modelLabel(for: activeBackend))", in: &r)
            run = r
        }
        lastRunMetrics = AskRunMetrics(dispatchedAt: metricsClock())
        VLog.store("dispatch — backend=\(activeBackend.rawValue) chars=\(question.count)")

        armActivityWatchdog(runID: runID)

        switch activeBackend {
        case .codex: dispatchCodex(question, runID: runID, thinkHarder: thinkHarder)
        case .grok: dispatchGrok(question, runID: runID, thinkHarder: thinkHarder)
        }
    }

    private func armActivityWatchdog(runID: UUID) {
        activityWatchdog?.cancel()
        let timeout = firstActivityTimeout
        let modelSnapshot = run?.modelLabel ?? modelLabel(for: activeBackend)
        activityWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard let r = self.run, r.id == runID,
                  r.status == .thinking || r.status == .working,
                  self.lastRunMetrics.firstEventAt == nil else { return }
            self.dispatchTask?.cancel()
            switch self.activeBackend {
            case .codex:
                if let thread = r.codexThreadID, let turn = r.codexTurnID {
                    self.codexClient.interrupt(threadID: thread, turnID: turn)
                }
            case .grok:
                self.grokClient.cancel()
            }
            self.fail(runID: runID, message: "No response from \(modelSnapshot) — try again.")
        }
    }

    private func cancelActivityWatchdog() {
        activityWatchdog?.cancel()
        activityWatchdog = nil
    }

    private func dispatchCodex(_ question: String, runID: UUID, thinkHarder: Bool) {
        let continuingThreadID = (run?.id == runID) ? run?.codexThreadID : nil
        // A follow-up with turns but NO codex thread (the conversation started
        // on grok) still deserves its context — send the prior turns inline;
        // the thread's developer instructions already carry the answer
        // contract, so only the context block is added.
        let priorTurns = (run?.id == runID) ? (run?.turns ?? []) : []
        let transcript = AskPromptPolicy.contextPrefix(
            question: question,
            priorTurns: priorTurns.map { (question: $0.question, answer: $0.answer) })
        dispatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.dispatchTask = nil }
            do {
                let start = try await self.codexClient.ask(
                    transcript: transcript,
                    continuingThread: continuingThreadID,
                    effort: thinkHarder ? "high" : "low"
                )
                guard var r = self.run, r.id == runID, !r.status.isTerminal, !Task.isCancelled else {
                    // Aborted while turn/start was in flight — the turn is now
                    // running server-side with nobody watching. Kill it.
                    if let turnID = start.turnID {
                        self.codexClient.interrupt(threadID: start.threadID, turnID: turnID)
                    }
                    return
                }
                r.codexThreadID = start.threadID
                if let turnID = start.turnID, !self.rejectedTurnIDs.contains(turnID) {
                    r.codexTurnID = turnID
                }
                self.run = r
            } catch {
                VLog.codex("codex ask failed: \(error.localizedDescription)")
                self.fail(runID: runID, message: self.friendly(error))
            }
        }
    }

    private func dispatchGrok(_ question: String, runID: UUID, thinkHarder: Bool) {
        let resume = (run?.id == runID) ? run?.grokSessionID : nil
        let prompt: String
        if resume != nil {
            prompt = AskPromptPolicy.contextPrefix(question: question, priorTurns: [])
        } else {
            let priorTurns = (run?.id == runID) ? (run?.turns ?? []) : []
            prompt = AskPromptPolicy.contextPrefix(
                question: question,
                priorTurns: priorTurns.map { (question: $0.question, answer: $0.answer) }
            )
        }
        let request = GrokAskRequest(
            prompt: prompt,
            model: grokModel.rawValue,
            effort: thinkHarder ? "high" : "low",
            systemPrompt: AskPromptPolicy.systemInstructions,
            resumeSessionID: resume
        )
        dispatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.dispatchTask = nil }
            do {
                try await self.grokClient.ask(request)
            } catch {
                VLog.grok("grok ask failed: \(error.localizedDescription)")
                self.fail(runID: runID, message: self.friendly(error))
            }
        }
    }

    private func friendly(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Model badge label snapshotted at dispatch — not read from live settings later.
    private func modelLabel(for backend: AskBackend) -> String {
        switch backend {
        case .codex: "gpt-5.5"
        case .grok: grokModel.displayName
        }
    }

    // MARK: - Codex event handling
    //
    // Two channels are kept strictly separate: the ANSWER (agentMessage items whose phase
    // is the final answer) accumulates into `run.answerText`; allowed research steps
    // (reasoning / web search / preamble narration) become kind-tagged steps for the
    // pill. Command and MCP tool events are not on the Ask allowlist and fail the run
    // at the controller. Item IDs never leak into either.

    private func handleCodexEvent(_ envelope: CodexEventEnvelope) {
        guard var r = run, activeBackend == .codex, !r.status.isTerminal,
              r.status == .thinking || r.status == .working else { return }
        // Ignore stray events from a stale (prewarm/previous) thread.
        if let threadID = r.codexThreadID, let evThread = envelope.threadID, evThread != threadID {
            return
        }
        if let evTurn = envelope.turnID, rejectedTurnIDs.contains(evTurn) { return }
        if r.codexThreadID == nil { r.codexThreadID = envelope.threadID }
        if r.codexTurnID == nil,
           let evTurn = envelope.turnID,
           !rejectedTurnIDs.contains(evTurn) {
            r.codexTurnID = evTurn
        }

        if lastRunMetrics.firstEventAt == nil {
            lastRunMetrics.firstEventAt = metricsClock()
            completeStep(kind: .generic, title: "Asking \(modelLabel(for: activeBackend))", in: &r)
        }

        func markWorking(_ r: inout AskRun) {
            if r.status == .thinking { try? r.transition(to: .working) }
        }

        switch envelope.event {
        case .turnStarted:
            if let evTurn = envelope.turnID, !rejectedTurnIDs.contains(evTurn) {
                r.codexTurnID = evTurn
            }

        case .agentMessageStarted(let itemID, let phase):
            guard !itemID.isEmpty else { break }
            if let phase, phase != "final_answer" {
                narrationItemIDs.insert(itemID)
            }

        case .agentMessageDelta(let itemID, let delta):
            markWorking(&r)
            if let itemID, narrationItemIDs.contains(itemID) {
                appendNarration(delta, in: &r)
            } else {
                if lastRunMetrics.firstAnswerTokenAt == nil {
                    lastRunMetrics.firstAnswerTokenAt = metricsClock()
                }
                r.answerText = (r.answerText ?? "") + delta
            }

        case .agentMessageCompleted(let itemID, let phase, let text):
            let isNarration = (itemID.map(narrationItemIDs.contains) ?? false)
                || (phase != nil && phase != "final_answer")
            if isNarration {
                completeNarration(with: text, in: &r)
            } else if !text.isEmpty {
                // Authoritative full text replaces streamed deltas so the answer
                // can never duplicate itself.
                r.answerText = text
            }

        case .reasoningStarted:
            markWorking(&r)
            upsertStep(kind: .thinking, title: thinkingTitle, in: &r)

        case .reasoningCompleted:
            // Deliberately no summary text — the pill keeps one quiet row, and
            // the view animates the running state (cycling words).
            completeStep(kind: .thinking, title: thoughtTitle, in: &r)

        case .webSearchStarted:
            markWorking(&r)
            upsertStep(kind: .search, title: "Searching the web", in: &r)

        case .webSearchCompleted:
            // No query echo — a plain "searched" row; details stay out of view.
            completeStep(kind: .search, title: "Searched the web", in: &r)

        case .toolCallStarted(let name):
            VLog.codex("warning: blocked tool call\(name.map { " (\($0))" } ?? "")")
            if let thread = r.codexThreadID, let turn = r.codexTurnID {
                codexClient.interrupt(threadID: thread, turnID: turn)
            }
            r.result = "Ask tried to use a blocked tool and was stopped."
            failRunningSteps(in: &r)
            try? r.transition(to: .failed)
            run = r
            finish(r)
            return

        case .toolCallProgress, .toolCallCompleted:
            return

        case .commandStarted(let command):
            VLog.codex("warning: blocked command\(command.map { " (\($0))" } ?? "")")
            if let thread = r.codexThreadID, let turn = r.codexTurnID {
                codexClient.interrupt(threadID: thread, turnID: turn)
            }
            r.result = "Ask tried to use a blocked tool and was stopped."
            failRunningSteps(in: &r)
            try? r.transition(to: .failed)
            run = r
            finish(r)
            return

        case .commandCompleted:
            return

        case .turnCompleted(let failureMessage):
            if let failureMessage {
                r.result = failureMessage
                failRunningSteps(in: &r)
                try? r.transition(to: .failed)
            } else {
                r.result = r.answerText ?? "Done."
                completeRunningSteps(in: &r)
                try? r.transition(to: .completed)
            }
            run = r
            finish(r)
            return

        case .serverError(let message):
            r.result = message
            failRunningSteps(in: &r)
            try? r.transition(to: .failed)
            run = r
            finish(r)
            return

        case .ignored:
            return
        }

        run = r
    }

    // MARK: - Grok event handling
    //
    // Grok's stream is simpler: `thought` deltas (a pulsing "Thinking…" step),
    // `text` deltas (the answer), then `end`.

    private func handleGrokEvent(_ event: GrokEvent) {
        guard var r = run, activeBackend == .grok, !r.status.isTerminal,
              r.status == .thinking || r.status == .working else { return }

        if lastRunMetrics.firstEventAt == nil {
            lastRunMetrics.firstEventAt = metricsClock()
            completeStep(kind: .generic, title: "Asking \(modelLabel(for: activeBackend))", in: &r)
        }

        func markWorking(_ r: inout AskRun) {
            if r.status == .thinking { try? r.transition(to: .working) }
        }

        switch event {
        case .thought:
            markWorking(&r)
            upsertStep(kind: .thinking, title: thinkingTitle, in: &r)

        case .text(let delta):
            markWorking(&r)
            completeStep(kind: .thinking, title: thoughtTitle, in: &r)
            if lastRunMetrics.firstAnswerTokenAt == nil {
                lastRunMetrics.firstAnswerTokenAt = metricsClock()
            }
            r.answerText = (r.answerText ?? "") + delta

        case .toolStarted(let title):
            // Grok's plan mode already refuses mutating tools; this is the same
            // belt-and-braces the codex path has - anything that is not
            // research (web search / fetch) ends the turn on the spot.
            guard Self.isResearchTool(title) else {
                VLog.grok("warning: blocked grok tool (\(title))")
                grokClient.cancel()
                r.result = "Ask tried to use a blocked tool and was stopped."
                failRunningSteps(in: &r)
                try? r.transition(to: .failed)
                run = r
                finish(r)
                return
            }
            markWorking(&r)
            let (kind, displayTitle) = Self.grokToolStep(title: title, completed: false)
            upsertStep(kind: kind, title: displayTitle, in: &r)

        case .toolCompleted(let title, let failed):
            let (kind, displayTitle) = Self.grokToolStep(title: title, completed: true)
            completeStep(kind: kind, title: displayTitle, failed: failed, in: &r)

        case .end(let stopReason, let sessionId):
            r.grokSessionID = sessionId ?? r.grokSessionID
            r.result = r.answerText ?? "Done."
            completeRunningSteps(in: &r)
            _ = stopReason
            try? r.transition(to: .completed)
            run = r
            finish(r)
            return

        case .error(let message):
            r.result = message
            failRunningSteps(in: &r)
            try? r.transition(to: .failed)
            run = r
            finish(r)
            return

        case .ignored:
            return
        }

        run = r
    }

    // MARK: - Step helpers

    /// Research-only allowlist for grok tool activity - web search and page
    /// fetches are the only tools an Ask turn is allowed to touch.
    nonisolated private static func isResearchTool(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.contains("web") || lowered.contains("search") || lowered.contains("fetch")
    }

    private static func grokToolStep(title: String, completed: Bool) -> (AskRunStepKind, String) {
        let lower = title.lowercased()
        let isSearch = lower.contains("web") || lower.contains("search") || lower.contains("fetch")
        if isSearch {
            return (.search, completed ? "Searched the web" : "Searching the web")
        }
        return (.tool, title)
    }

    private func upsertStep(kind: AskRunStepKind, title: String, in r: inout AskRun) {
        if let index = r.steps.lastIndex(where: { $0.kind == kind && $0.state == .running }) {
            r.steps[index].title = title
            return
        }
        // Thinking and search are ONE persistent row each per run: models emit
        // many short reasoning bursts and repeated searches, and a fresh row
        // per burst stacks identical lines in the pill. Re-activate the
        // existing row instead.
        if kind == .thinking || kind == .search,
           let index = r.steps.lastIndex(where: { $0.kind == kind }) {
            r.steps[index].title = title
            r.steps[index].state = .running
            return
        }
        r.appendStep(title, state: .running, kind: kind)
    }

    private func completeStep(kind: AskRunStepKind, title: String, failed: Bool = false, in r: inout AskRun) {
        if let index = r.steps.lastIndex(where: { $0.kind == kind && $0.state == .running }) {
            r.steps[index].title = title
            r.steps[index].state = failed ? .failed : .completed
            return
        }
        // Same single-row rule as upsertStep: completing thinking/search
        // repeatedly (e.g. once per streamed delta) must never stack rows.
        if kind == .thinking || kind == .search,
           let index = r.steps.lastIndex(where: { $0.kind == kind }) {
            r.steps[index].title = title
            r.steps[index].state = failed ? .failed : .completed
            return
        }
        r.appendStep(title, state: failed ? .failed : .completed, kind: kind)
    }

    private func setRunningStepDetail(kind: AskRunStepKind, detail: String, in r: inout AskRun) {
        if let index = r.steps.lastIndex(where: { $0.kind == kind && $0.state == .running }) {
            r.steps[index].detail = detail
        }
    }

    private func completeRunningSteps(in r: inout AskRun) {
        for index in r.steps.indices where r.steps[index].state == .running {
            if r.steps[index].kind == .thinking {
                r.steps[index].title = thoughtTitle
            }
            r.steps[index].state = .completed
        }
    }

    private func failRunningSteps(in r: inout AskRun) {
        for index in r.steps.indices where r.steps[index].state == .running {
            r.steps[index].state = .failed
        }
    }

    private func appendNarration(_ delta: String, in r: inout AskRun) {
        if let index = r.steps.lastIndex(where: { $0.kind == .narration && $0.state == .running }) {
            r.steps[index].title = Self.oneLine(r.steps[index].title + delta)
        } else {
            r.appendStep(Self.oneLine(delta), state: .running, kind: .narration)
        }
    }

    private func completeNarration(with fullText: String, in r: inout AskRun) {
        if let index = r.steps.lastIndex(where: { $0.kind == .narration && $0.state == .running }) {
            if !fullText.isEmpty { r.steps[index].title = Self.oneLine(fullText) }
            r.steps[index].state = .completed
        } else if !fullText.isEmpty {
            r.appendStep(Self.oneLine(fullText), state: .completed, kind: .narration)
        }
    }

    private static func oneLine(_ text: String, limit: Int = 140) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    private static func shortCommand(_ command: String, limit: Int = 48) -> String {
        "\u{201C}\(oneLine(command, limit: limit))\u{201D}"
    }

    // MARK: - Completion

    private func fail(runID: UUID, message: String) {
        guard var r = run, r.id == runID, !r.status.isTerminal else { return }
        r.result = message
        failRunningSteps(in: &r)
        // .failed isn't reachable from every state (e.g. .listening) — fall back
        // to .cancelled rather than silently stranding the run non-terminal.
        if (try? r.transition(to: .failed)) == nil {
            try? r.transition(to: .cancelled)
        }
        run = r
        finish(r)
    }

    private func finish(_ finished: AskRun) {
        cancelActivityWatchdog()
        lastRunMetrics.completedAt = metricsClock()
        if finished.status == .completed,
           let dispatched = lastRunMetrics.dispatchedAt,
           let completed = lastRunMetrics.completedAt {
            let rounded = ((completed - dispatched) * 10).rounded() / 10
            if var r = run, r.id == finished.id {
                r.latencySeconds = rounded
                run = r
            }
        }
        if let dispatched = lastRunMetrics.dispatchedAt {
            let ttfe = lastRunMetrics.firstEventAt.map { Int(($0 - dispatched) * 1000) }
            let ttft = lastRunMetrics.firstAnswerTokenAt.map { Int(($0 - dispatched) * 1000) }
            let total = Int((lastRunMetrics.completedAt! - dispatched) * 1000)
            VLog.store("metrics backend=\(activeBackend.rawValue) model=\(finished.modelLabel ?? "?") ttfe_ms=\(ttfe.map(String.init) ?? "-") ttft_ms=\(ttft.map(String.init) ?? "-") total_ms=\(total)")
        }
        narrationItemIDs.removeAll()
        if saveHistory,
           finished.status == .completed, let answer = finished.result ?? finished.answerText {
            history.add(
                question: finished.rawTranscript,
                answer: AskAnswerBlock.strippingLeadingNarration(answer),
                backend: activeBackend.rawValue,
                modelLabel: finished.modelLabel
            )
        }
        if finished.status == .completed, autoSpeak, speakAvailable {
            speakCurrentAnswer()
        }
        scheduleAutoDismiss(finished)
    }

    /// Returns the pill to idle after long enough to actually READ the answer:
    /// the linger scales with content length (~200 wpm + a floor), and never
    /// counts down while the user hovers or after they've clicked in (pinned).
    private func scheduleAutoDismiss(_ finished: AskRun) {
        let seconds: Double
        if finished.status == .completed {
            let length = (finished.result ?? finished.answerText ?? "").count
            seconds = min(90, 10 + Double(length) * 0.045)
        } else {
            seconds = 6  // cancelled / failed: enough to register, then gone
        }
        Task { @MainActor [weak self, runID = finished.id] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            while let self, self.run?.id == runID, self.pillHovered || self.pillPinned {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, self.run?.id == runID, self.run?.status.isTerminal == true else { return }
            self.run = nil
        }
    }
}
