//
//  GrokAgentClient.swift
//  Yappy
//
//  Answers an Ask question through a persistent `grok agent stdio` process —
//  prewarmed at launch / Fn-down so questions pay only `session/prompt` on the
//  hot path. Falls back to GrokAskClient (one-shot CLI) via GrokClientRouter
//  when the warm process can't serve the request (model switch, think-harder).
//
//  ## Isolated Grok home
//  Same private HOME as GrokAskClient (empty .grok config, fresh auth.json copy).
//  See GrokAskClient.prepareGrokHome().
//

import Foundation
import QuartzCore

final class GrokAgentClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case grokNotFound
        case notLoggedIn
        case notRunning
        case notWarm
        case malformedResponse(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .grokNotFound:
                "The Grok CLI was not found. Install it and sign in with `grok login`."
            case .notLoggedIn:
                "Grok is not signed in. Run `grok login` in a terminal."
            case .notRunning:
                "Grok agent is not running."
            case .notWarm:
                "Grok warm client cannot serve this request."
            case .malformedResponse(let message):
                "Malformed Grok response: \(message)"
            case .server(let message):
                "Grok agent error: \(message)"
            }
        }
    }

    var onEvent: (@Sendable (GrokEvent) -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private let lock = NSLock()
    private let ioLock = NSLock()
    private var nextID = 1
    private var initialized = false
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    private var spawnedModel: String?
    private var warmSessionID: String?
    private var lastCompletedSessionID: String?
    private var activeSessionID: String?
    private var activePromptRequestID: Int?
    private var isStreaming = false
    private var lastActivityAt: CFTimeInterval = 0
    private var eventGeneration = 0
    private var loggedNotificationKinds: Set<String> = []
    private var readyTask: Task<Void, Error>?
    private var readyToken: UUID?
    private var readyModel: String?

    /// Default model for prewarm spawn — matches AskController's default picker.
    private static let defaultWarmModel = AskGrokModel.grok45.rawValue
    private static let defaultSystemPrompt = AskPromptPolicy.systemInstructions

    // MARK: - Readiness

    var isWarmAndIdle: Bool {
        lock.withLock {
            process?.isRunning == true
                && initialized
                && warmSessionID != nil
                && activeSessionID == nil
                && !isStreaming
        }
    }

    // MARK: - Lifecycle

    func prewarm() async {
        do {
            try await ensureReady(model: spawnedModel ?? Self.defaultWarmModel)
            try await ensureWarmSession()
            VLog.grok("agent prewarmed session=\(lock.withLock { warmSessionID ?? "?" })")
        } catch {
            VLog.grok("agent prewarm failed: \(error.localizedDescription)")
        }
    }

    func ask(_ askRequest: GrokAskRequest) async throws {
        try validateWarmRequest(askRequest)

        let trimmedModel = askRequest.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = trimmedModel.isEmpty ? Self.defaultWarmModel : trimmedModel

        try await ensureReady(model: model)

        let sessionID: String
        if let resume = askRequest.resumeSessionID {
            let lastCompleted = lock.withLock { lastCompletedSessionID }
            guard resume == lastCompleted else {
                throw ClientError.notWarm
            }
            sessionID = resume
        } else if let warm = lock.withLock({ () -> String? in
            let id = warmSessionID
            warmSessionID = nil
            return id
        }) {
            sessionID = warm
        } else {
            sessionID = try await createSession()
        }

        let generation = lock.withLock {
            eventGeneration += 1
            activeSessionID = sessionID
            isStreaming = true
            return eventGeneration
        }

        defer {
            lock.withLock {
                if activeSessionID == sessionID { activeSessionID = nil }
                isStreaming = false
            }
            Task { await self.refillWarmSession() }
        }

        // `grok agent stdio` has no --system-prompt-override (verified live: exit 2,
        // "unexpected argument") — the answer contract rides the FIRST prompt of each
        // session instead. Resumed sessions already carry it from their first turn.
        let promptText: String
        if askRequest.resumeSessionID != nil {
            promptText = askRequest.prompt
        } else {
            let systemPrompt = askRequest.systemPrompt ?? Self.defaultSystemPrompt
            promptText = systemPrompt + "\n\n" + askRequest.prompt
        }

        let response = try await self.request(
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": promptText]],
            ],
            resetsOnActivity: true
        )

        guard lock.withLock({ eventGeneration == generation }) else { return }

        let stopReason = Self.stopReason(in: response)
        lock.withLock { lastCompletedSessionID = sessionID }
        onEvent?(.end(stopReason: stopReason, sessionId: sessionID))
    }

    func cancel() {
        let snapshot: (sessionID: String?, generation: Int, wasStreaming: Bool, promptID: Int?) = lock.withLock {
            eventGeneration += 1
            let sessionID = activeSessionID
            let wasStreaming = isStreaming
            let promptID = activePromptRequestID
            activeSessionID = nil
            isStreaming = false
            return (sessionID, eventGeneration, wasStreaming, promptID)
        }

        guard let sessionID = snapshot.sessionID, snapshot.wasStreaming,
              process?.isRunning == true else { return }

        VLog.grok("cancel — sending session/cancel for \(sessionID)")
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": ["sessionId": sessionID],
        ]
        do {
            try sendRaw(notification)
        } catch {
            VLog.grok("cancel notification failed: \(error.localizedDescription)")
        }

        let generationAtCancel = snapshot.generation
        let promptID = snapshot.promptID
        // If the cancelled turn's session/prompt continuation is still pending after
        // session/cancel, tear down the agent. Abort if a newer turn advanced generation.
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            let stillStuck: Bool = self.lock.withLock {
                guard self.eventGeneration == generationAtCancel,
                      let promptID = promptID else { return false }
                return self.pending[promptID] != nil
            }
            guard stillStuck else { return }
            VLog.grok("cancel — session/prompt still pending after 300ms, terminating agent")
            DispatchQueue.main.async { self.stop() }
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        process?.terminate()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        initialized = false

        lock.lock()
        readyTask = nil
        readyToken = nil
        readyModel = nil
        let continuations = pending.values
        pending.removeAll()
        warmSessionID = nil
        lastCompletedSessionID = nil
        activeSessionID = nil
        activePromptRequestID = nil
        isStreaming = false
        spawnedModel = nil
        lock.unlock()

        for continuation in continuations {
            continuation.resume(throwing: ClientError.notRunning)
        }
    }

    private func ensureReady(model: String) async throws {
        let shouldStop: Bool = lock.withLock {
            guard let readyModel, readyModel != model else { return false }
            readyTask = nil
            readyToken = nil
            self.readyModel = nil
            return true
        }
        if shouldStop { stop() }

        let (task, token): (Task<Void, Error>, UUID) = lock.withLock {
            if let readyTask, let readyToken, readyModel == model {
                return (readyTask, readyToken)
            }
            let token = UUID()
            let m = model
            let t = Task {
                try self.start(model: m)
                try await self.initializeIfNeeded()
            }
            readyTask = t
            readyToken = token
            readyModel = m
            return (t, token)
        }
        do {
            try await task.value
        } catch {
            lock.withLock {
                if readyToken == token {
                    readyTask = nil
                    readyToken = nil
                    readyModel = nil
                }
            }
            throw error
        }
    }

    // MARK: - Warm validation

    private func validateWarmRequest(_ request: GrokAskRequest) throws {
        if request.effort == "high" { throw ClientError.notWarm }

        // Model switches are handled by ensureReady's stop-and-respawn logic; the first
        // ask after a switch pays one warm-agent spawn instead of permanently falling
        // back to the slower one-shot cold path (nothing else respawns the warm agent).
    }

    // MARK: - Spawn

    private func start(model: String) throws {
        let needsRespawn: Bool = lock.withLock {
            guard process?.isRunning == true else { return true }
            return spawnedModel != model
        }
        if needsRespawn {
            stop()
        }
        if self.process?.isRunning == true { return }

        guard let grokPath = GrokAskClient.resolvedGrokPath else {
            throw ClientError.grokNotFound
        }
        let home = try GrokAskClient.prepareGrokHome()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: grokPath)

        child.arguments = ["agent", "-m", model, "--reasoning-effort", "low", "stdio"]
        child.currentDirectoryURL = home

        // Minimal, fixed environment (see GrokAskClient - same rationale).
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        child.environment = [
            "HOME": home.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "\(realHome)/.local/bin:\(realHome)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]

        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = errorPipe
        child.terminationHandler = { proc in
            VLog.grok("agent exited status=\(proc.terminationStatus)")
        }
        try child.run()
        VLog.grok("agent spawned pid=\(child.processIdentifier) model=\(model) home=\(home.lastPathComponent)")

        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.process = child
        lock.withLock {
            spawnedModel = model
            loggedNotificationKinds.removeAll()
        }
        startReader(outputPipe.fileHandleForReading)
        startStderrDrain(errorPipe.fileHandleForReading)
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        _ = try await request(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [:] as [String: Any],
            ]
        )
        initialized = true
    }

    /// True while a warm-session fill is in flight — the check-create-store
    /// sequence spans an await, so concurrent prewarms would otherwise each
    /// create a session and orphan all but the last.
    private var fillingWarmSession = false

    private func ensureWarmSession() async throws {
        let shouldFill = lock.withLock {
            guard warmSessionID == nil, !fillingWarmSession else { return false }
            fillingWarmSession = true
            return true
        }
        guard shouldFill else { return }
        defer { lock.withLock { fillingWarmSession = false } }
        let sessionID = try await createSession()
        lock.withLock { warmSessionID = sessionID }
    }

    private func refillWarmSession() async {
        do {
            guard process?.isRunning == true else { return }
            try await initializeIfNeeded()
            let shouldFill = lock.withLock {
                guard warmSessionID == nil, activeSessionID == nil, !fillingWarmSession else { return false }
                fillingWarmSession = true
                return true
            }
            guard shouldFill else { return }
            defer { lock.withLock { fillingWarmSession = false } }
            let sessionID = try await createSession()
            lock.withLock { warmSessionID = sessionID }
            VLog.grok("agent refilled warm session \(sessionID)")
        } catch {
            VLog.grok("agent refill failed: \(error.localizedDescription)")
        }
    }

    private func createSession() async throws -> String {
        // Path only — auth was copied at spawn; a per-session recopy could
        // clobber a token the CLI refreshed mid-run (and raced concurrent
        // prewarms in practice).
        let home = try GrokAskClient.grokHomeURL()
        let response = try await request(
            method: "session/new",
            params: [
                "cwd": home.path,
                "mcpServers": [] as [Any],
            ]
        )
        guard let result = response["result"] as? [String: Any],
              let sessionID = result["sessionId"] as? String else {
            throw ClientError.malformedResponse("session/new did not return result.sessionId")
        }
        if let currentModel = (result["models"] as? [String: Any])?["currentModelId"] as? String {
            VLog.grok("session/new model=\(currentModel)")
        }
        return sessionID
    }

    // MARK: - JSON-RPC plumbing

    // Fast RPCs use a flat timeout; session/prompt uses this as an inactivity watchdog.
    private static let requestTimeout: TimeInterval = 30

    private func request(method: String, params: [String: Any], resetsOnActivity: Bool = false) async throws -> [String: Any] {
        guard process?.isRunning == true else {
            throw ClientError.notRunning
        }

        let id: Int = lock.withLock {
            let id = nextID
            nextID += 1
            return id
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            if resetsOnActivity {
                activePromptRequestID = id
                lastActivityAt = CACurrentMediaTime()
            }
            lock.unlock()

            Task.detached(priority: .utility) { [weak self] in
                if resetsOnActivity {
                    var sleepSeconds = Self.requestTimeout
                    while true {
                        try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                        guard let self else { return }
                        var nextSleep: TimeInterval?
                        let stuck: CheckedContinuation<[String: Any], Error>? = self.lock.withLock {
                            guard self.pending[id] != nil else { return nil }
                            let idle = CACurrentMediaTime() - self.lastActivityAt
                            if idle < Self.requestTimeout {
                                nextSleep = Self.requestTimeout - idle
                                return nil
                            }
                            return self.pending.removeValue(forKey: id)
                        }
                        guard let stuck else {
                            guard let nextSleep else { return }
                            sleepSeconds = nextSleep
                            continue
                        }
                        VLog.grok("\(method) stalled — no activity for \(Int(Self.requestTimeout))s — restarting agent")
                        stuck.resume(throwing: ClientError.server("Grok made no progress for \(Int(Self.requestTimeout))s."))
                        DispatchQueue.main.async { self.stop() }
                        return
                    }
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
                    guard let self else { return }
                    let stuck: CheckedContinuation<[String: Any], Error>? = self.lock.withLock {
                        self.pending.removeValue(forKey: id)
                    }
                    guard let stuck else { return }
                    VLog.grok("\(method) timed out after \(Int(Self.requestTimeout))s — restarting agent")
                    stuck.resume(throwing: ClientError.server("Grok did not respond in \(Int(Self.requestTimeout))s."))
                    DispatchQueue.main.async { self.stop() }
                }
            }

            let object: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params,
            ]
            do {
                try sendRaw(object)
            } catch {
                lock.lock()
                let mine = pending.removeValue(forKey: id)
                lock.unlock()
                mine?.resume(throwing: error)
            }
        }
    }

    private func sendRaw(_ object: [String: Any]) throws {
        guard let input = inputPipe?.fileHandleForWriting else {
            throw ClientError.notRunning
        }
        // .withoutEscapingSlashes is load-bearing: the agent's parser wants method
        // names as borrowed strings, and an escaped "session\/new" can't be
        // borrowed — it rejects the frame (verified live: "invalid type: string").
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        ioLock.withLock {
            input.write(data + Data("\n".utf8))
        }
    }

    private func startReader(_ handle: FileHandle) {
        readTask?.cancel()
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !line.isEmpty else { continue }
                    self?.handleLine(line)
                }
            }
        }
    }

    private func startStderrDrain(_ handle: FileHandle) {
        stderrTask?.cancel()
        stderrTask = Task.detached(priority: .utility) { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if VLog.contentLoggingEnabled,
                       let text = String(data: line, encoding: .utf8), !text.isEmpty {
                        VLog.grok("agent stderr: \(text.prefix(300))")
                    }
                }
                _ = self
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let method = object["method"] as? String
        let hasID = object["id"] != nil

        if let method, hasID {
            handleServerRequest(id: object["id"]!, method: method, params: object["params"] as? [String: Any] ?? [:])
        } else if hasID, let id = jsonID(object["id"]) {
            lock.lock()
            let continuation = pending.removeValue(forKey: id)
            lock.unlock()

            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                continuation?.resume(throwing: ClientError.server(message))
            } else {
                continuation?.resume(returning: object)
            }
        } else if let method {
            handleNotification(method: method, params: object["params"] as? [String: Any] ?? [:])
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        lock.withLock {
            if (params["sessionId"] as? String) == activeSessionID {
                lastActivityAt = CACurrentMediaTime()
            }
        }

        let ignoredKinds = [
            "_x.ai/queue/changed",
            "_x.ai/session/prompt_complete",
            "pending_interaction",
            "interaction_resolved",
        ]
        if ignoredKinds.contains(method) {
            logNotificationOnce(method)
            return
        }

        guard shouldEmitNotification(params: params) else { return }

        if let event = GrokEvent.fromSessionUpdate(method: method, params: params) {
            onEvent?(event)
        }
    }

    private func shouldEmitNotification(params: [String: Any]) -> Bool {
        let frameSession = params["sessionId"] as? String
        let (active, generation): (String?, Int) = lock.withLock {
            (activeSessionID, eventGeneration)
        }
        guard let active else { return false }
        if let frameSession, frameSession != active { return false }
        _ = generation
        return true
    }

    private func logNotificationOnce(_ kind: String) {
        let shouldLog: Bool = lock.withLock {
            guard !loggedNotificationKinds.contains(kind) else { return false }
            loggedNotificationKinds.insert(kind)
            return true
        }
        if shouldLog {
            VLog.grok("ignored notification \(kind)")
        }
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        lock.withLock {
            lastActivityAt = CACurrentMediaTime()
        }
        _ = params
        if method.localizedCaseInsensitiveContains("permission")
            || method.localizedCaseInsensitiveContains("request_permission") {
            VLog.grok("declining permission request \(method)")
            respondError(id: id, code: -32601, message: "Yappy Ask declined \(method).")
            return
        }
        VLog.grok("unsupported server request \(method) — answering with error")
        respondError(id: id, code: -32601, message: "Method not supported")
    }

    private func respond(id: Any, result: [String: Any]) {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        do {
            try sendRaw(object)
        } catch {
            VLog.grok("failed to answer server request: \(error.localizedDescription)")
        }
    }

    private func respondError(id: Any, code: Int, message: String) {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
        do {
            try sendRaw(object)
        } catch {
            VLog.grok("failed to answer server request: \(error.localizedDescription)")
        }
    }

    private func jsonID(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func stopReason(in response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any] else { return nil }
        return result["stopReason"] as? String
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
