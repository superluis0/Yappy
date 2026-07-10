//
//  CodexAskClient.swift
//  Yappy
//
//  Answers an Ask question through the Codex app-server (`codex app-server
//  --stdio`), gpt-5.5, using the model's native web search. Ported from
//  VoiceAgent's CodexAppServerClient and stripped of the computer-use MCP
//  bridge — Ask is a research assistant, not a computer-use agent.
//
//  ## Isolated CODEX_HOME (the "no CUA" + speed guarantee)
//  The user's global ~/.codex enables ~18 plugins including computer-use and
//  browser control, at `sandbox_mode = "danger-full-access"`. We never touch it.
//  The app-server runs with CODEX_HOME pointed at a private directory whose
//  config enables ONLY web search, disables computer-use / browser, and pins
//  `sandbox_mode = "read-only"` so the model cannot act on the machine. Verified:
//  in this isolated home the model has web.run + a read-only shell and NO
//  computer-use / screenshot / click / browser-control tools. auth.json is copied
//  fresh (never symlinked) so a token refresh here can't clobber the real login.
//
//  ## Warm-thread prewarm
//  `prewarm()` spawns the server, initializes, and pre-creates a thread. Called
//  at launch and on every Fn press while the user is still speaking, so by
//  release only `turn/start` stands between the transcript and the first token.
//
//  ## Server→client requests
//  The app-server sends JSON-RPC *requests* to us (id + method). These MUST be
//  answered or the turn deadlocks. With no MCP bridge and approval_policy=never
//  we decline every elicitation/approval defensively and error on the unknown.
//

import Foundation

struct CodexRunStart: Sendable {
    let threadID: String
    let turnID: String?
    let turnStarted: Bool
}

final class CodexAskClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case codexNotFound
        case notLoggedIn
        case notRunning
        case malformedResponse(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .codexNotFound:
                "Codex CLI was not found."
            case .notLoggedIn:
                "Codex is not signed in. Run `codex login` in a terminal."
            case .notRunning:
                "Codex app-server is not running."
            case .malformedResponse(let message):
                "Malformed Codex response: \(message)"
            case .server(let message):
                "Codex app-server error: \(message)"
            }
        }
    }

    var onNotification: (@Sendable (CodexEventEnvelope) -> Void)?

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
    /// A thread created ahead of need so a voice turn only pays for `turn/start`.
    private var warmThreadID: String?
    private var readyTask: Task<Void, Error>?
    private var readyToken: UUID?

    static var resolvedCodexPath: String { resolveCodexPath() }

    // MARK: - Readiness (drives the Settings "green light")

    /// A usable codex binary exists somewhere we know to look.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: resolveCodexPath())
    }

    /// The user has signed in at least once (`codex login`) — the same
    /// `~/.codex/auth.json` this client copies into its isolated home.
    static var isSignedIn: Bool {
        FileManager.default.fileExists(atPath: realAuthURL.path)
    }

    // MARK: - Isolated Codex home

    /// Real `~/.codex/auth.json`, the source of the login token. Read-only for us.
    private static var realAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    private static func appSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Yappy", isDirectory: true)
    }

    /// Scratch cwd for codex turns, outside the isolated home so codex never
    /// mistakes its own config directory for the workspace.
    static func workspaceDirectory() throws -> URL {
        let workspace = try appSupportDirectory().appendingPathComponent("CodexWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    /// Creates/refreshes the private Codex home. The config enables web search,
    /// disables computer-use / browser, pins a read-only sandbox, and registers
    /// NO MCP servers. `auth.json` is copied fresh from the real login on each
    /// spawn (copied, not symlinked).
    ///
    /// Research MCP/plugins (github, pdf, documents) are intentionally NOT
    /// enabled here: in codex 0.142 their tools are deferred behind tool-search
    /// and the marketplace source paths are machine-specific. Web search already
    /// covers "find sources"; enabling them is a localized follow-up (add
    /// `[plugins."…"]` + `[marketplaces.…]` blocks below) once their tool
    /// surfacing is validated for voice Q&A.
    private static func prepareCodexHome(workspace: URL) throws -> URL {
        let home = try appSupportDirectory().appendingPathComponent("CodexAskHome", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let config = """
        model = "\(CodexModel.id)"
        model_reasoning_effort = "low"
        approval_policy = "never"
        sandbox_mode = "read-only"

        [tools]
        web_search = true

        [features]
        computer_use = false
        browser_use = false
        in_app_browser = false

        [projects."\(workspace.path)"]
        trust_level = "trusted"
        """
        let configFile = home.appendingPathComponent("config.toml")
        if (try? String(contentsOf: configFile, encoding: .utf8)) != config {
            try config.write(to: configFile, atomically: true, encoding: .utf8)
        }

        guard FileManager.default.fileExists(atPath: realAuthURL.path) else {
            throw ClientError.notLoggedIn
        }
        let authCopy = home.appendingPathComponent("auth.json")
        try? FileManager.default.removeItem(at: authCopy)
        try FileManager.default.copyItem(at: realAuthURL, to: authCopy)

        // Owner-only, always: the home holds a login token.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authCopy.path)

        return home
    }

    // MARK: - Lifecycle

    func start() throws {
        if process?.isRunning == true { return }
        let codexPath = Self.resolveCodexPath()
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            throw ClientError.codexNotFound
        }

        let workspace = try Self.workspaceDirectory()
        let home = try Self.prepareCodexHome(workspace: workspace)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = workspace

        // Minimal, fixed environment: the child gets exactly what it needs and
        // nothing the app process happened to inherit. PATH covers the places
        // node + dev tools actually live so a node-shim codex still runs.
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = [
            "CODEX_HOME": home.path,
            "HOME": realHome,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "\(realHome)/.local/bin:\(realHome)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { proc in
            VLog.codex("app-server exited status=\(proc.terminationStatus)")
        }
        try process.run()
        VLog.codex("app-server spawned pid=\(process.processIdentifier) path=\(codexPath) home=\(home.lastPathComponent)")

        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.process = process
        startReader(outputPipe.fileHandleForReading)
        startStderrDrain(errorPipe.fileHandleForReading)
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
        let continuations = pending.values
        pending.removeAll()
        warmThreadID = nil
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: ClientError.notRunning)
        }
    }

    private func ensureReady() async throws {
        let (task, token): (Task<Void, Error>, UUID) = lock.withLock {
            if let readyTask, let readyToken {
                return (readyTask, readyToken)
            }
            let token = UUID()
            let t = Task {
                try self.start()
                try await self.initializeIfNeeded()
            }
            readyTask = t
            readyToken = token
            return (t, token)
        }
        do {
            try await task.value
        } catch {
            lock.withLock {
                if readyToken == token {
                    readyTask = nil
                    readyToken = nil
                }
            }
            throw error
        }
    }

    // MARK: - Turns

    private static let developerInstructions = AskPromptPolicy.systemInstructions

    /// Spawns the app-server, initializes, and pre-creates a thread. Called at
    /// launch and on every Fn press — cheap when already warm, and the reason a
    /// spoken question starts streaming without setup latency.
    func prewarm() async {
        do {
            try await ensureReady()
            let alreadyWarm = lock.withLock { warmThreadID != nil }
            guard !alreadyWarm else { return }
            let threadID = try await createThread()
            lock.withLock { warmThreadID = threadID }
            VLog.codex("prewarmed thread \(threadID)")
        } catch {
            VLog.codex("prewarm failed: \(error.localizedDescription)")
        }
    }

    /// Starts a research turn for `transcript`, continuing an existing thread
    /// when supplied or otherwise reusing the warm thread and refilling the warm
    /// slot so the next fresh question is just as fast.
    func ask(transcript: String, continuingThread: String? = nil, effort: String = "low") async throws -> CodexRunStart {
        let startedAt = Date()
        try await ensureReady()

        let reusedThreadID: String? = continuingThread == nil
            ? lock.withLock {
                let id = warmThreadID
                warmThreadID = nil
                return id
            }
            : nil
        var threadID: String
        if let continuingThread {
            threadID = continuingThread
        } else if let reusedThreadID {
            threadID = reusedThreadID
        } else {
            threadID = try await createThread()
        }

        let turnParams: (String) -> [String: Any] = { thread in
            [
                "threadId": thread,
                "input": [["type": "text", "text": transcript]],
                "model": CodexModel.id,
                "effort": effort
            ]
        }

        let turnResponse: [String: Any]
        do {
            turnResponse = try await request(method: "turn/start", params: turnParams(threadID))
        } catch where continuingThread != nil || reusedThreadID != nil {
            // The warm or continued thread went stale (server restart, expiry)
            // — fall back to a fresh one rather than failing the user's question.
            VLog.codex("\(continuingThread != nil ? "continued" : "warm") thread rejected — retrying on a fresh thread")
            threadID = try await createThread()
            turnResponse = try await request(method: "turn/start", params: turnParams(threadID))
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        VLog.codex("turn accepted in \(elapsedMs)ms (warmThread=\(reusedThreadID != nil), continuingThread=\(continuingThread != nil))")

        if continuingThread == nil {
            // Refill the warm slot so the next fresh question is just as fast.
            Task { [weak self] in
                await self?.prewarm()
            }
        }

        return CodexRunStart(threadID: threadID, turnID: Self.turnID(in: turnResponse), turnStarted: true)
    }

    /// Interrupts an in-flight turn (Stop button / Escape). Best-effort.
    func interrupt(threadID: String, turnID: String) {
        Task { [weak self] in
            do {
                _ = try await self?.request(
                    method: "turn/interrupt",
                    params: ["threadId": threadID, "turnId": turnID]
                )
                VLog.codex("turn/interrupt sent for \(turnID)")
            } catch {
                VLog.codex("interrupt failed: \(error.localizedDescription)")
            }
        }
    }

    private func createThread() async throws -> String {
        let workspace = try Self.workspaceDirectory()
        let threadResponse = try await request(
            method: "thread/start",
            params: [
                "model": CodexModel.id,
                "cwd": workspace.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "ephemeral": true,
                "threadSource": "yappy",
                "developerInstructions": Self.developerInstructions
            ]
        )

        guard let result = threadResponse["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw ClientError.malformedResponse("thread/start did not return result.thread.id")
        }
        return threadID
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": ["name": "Yappy", "version": "1.0.0"],
                "capabilities": NSNull()
            ]
        )
        initialized = true
    }

    // MARK: - JSON-RPC plumbing

    /// All requests here are fast control-plane calls (initialize, thread/start,
    /// turn/start, turn/interrupt) — answers stream separately as notifications.
    /// The timeout guards against a wedged app-server: without it, one stuck
    /// request would hang its caller forever AND poison every later Ask, because
    /// start() sees the zombie process as healthy and reuses its jammed pipes.
    private static let requestTimeout: TimeInterval = 30

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
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
            lock.unlock()

            // Watchdog: if the response never comes, fail this request and tear
            // the client down so the NEXT attempt respawns a fresh app-server.
            // If the response arrives first, the pending slot is already empty
            // and this expires as a no-op.
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
                guard let self else { return }
                let stuck: CheckedContinuation<[String: Any], Error>? = self.lock.withLock {
                    self.pending.removeValue(forKey: id)
                }
                guard let stuck else { return }
                VLog.codex("\(method) timed out after \(Int(Self.requestTimeout))s — restarting app-server")
                stuck.resume(throwing: ClientError.server("Codex did not respond in \(Int(Self.requestTimeout))s."))
                DispatchQueue.main.async { self.stop() }
            }

            let object: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            ]
            do {
                try sendRaw(object)
            } catch {
                lock.lock()
                let mine = pending.removeValue(forKey: id)
                lock.unlock()
                // The watchdog may have already claimed the slot; resume once.
                mine?.resume(throwing: error)
            }
        }
    }

    private func sendRaw(_ object: [String: Any]) throws {
        guard let input = inputPipe?.fileHandleForWriting else {
            throw ClientError.notRunning
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        ioLock.withLock {
            input.write(data + Data("\n".utf8))
        }
    }

    private func startReader(_ handle: FileHandle) {
        readTask?.cancel()
        readTask = makeLineReader(handle) { [weak self] line in
            self?.handleLine(line)
        }
    }

    /// The app-server logs to stderr. Drain it (an undrained 64 KB pipe blocks
    /// the child) and surface it for diagnostics.
    private func startStderrDrain(_ handle: FileHandle) {
        stderrTask?.cancel()
        stderrTask = makeStderrDrain(handle) { line in
            if VLog.contentLoggingEnabled,
               let text = String(data: line, encoding: .utf8), !text.isEmpty {
                VLog.codex("stderr: \(text.prefix(300))")
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
            // Server→client REQUEST — must be answered or the turn deadlocks.
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
        } else {
            guard let envelope = CodexEventEnvelope(jsonObject: object) else { return }
            if case .ignored = envelope.event { return }   // bookkeeping traffic
            onNotification?(envelope)
        }
    }

    /// Answers app-server→client requests. With no MCP bridge and
    /// approval_policy=never, every elicitation/approval is declined; unknown
    /// requests get a JSON-RPC error so codex fails fast instead of hanging.
    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "mcpServer/elicitation/request":
            VLog.codex("declining elicitation (no bridge in Ask mode)")
            respond(id: id, result: ["action": "decline"])
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            VLog.codex("declining \(method)")
            respond(id: id, result: ["decision": "decline"])
        case "execCommandApproval", "applyPatchApproval":
            VLog.codex("denying legacy \(method)")
            respond(id: id, result: ["decision": "denied"])
        default:
            VLog.codex("unsupported server request \(method) — answering with error")
            respondError(id: id, code: -32601, message: "Yappy Ask does not support \(method).")
        }
    }

    private func respond(id: Any, result: [String: Any]) {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        do {
            try sendRaw(object)
        } catch {
            VLog.codex("failed to answer server request: \(error.localizedDescription)")
        }
    }

    private func respondError(id: Any, code: Int, message: String) {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
        do {
            try sendRaw(object)
        } catch {
            VLog.codex("failed to answer server request: \(error.localizedDescription)")
        }
    }

    private func jsonID(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func resolveCodexPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The Codex.app binary comes FIRST: it's a self-contained Mach-O, while
        // the npm shim is a `#!/usr/bin/env node` script — GUI-launched apps get
        // a minimal PATH without node, so the shim dies with
        // "env: node: No such file or directory" (seen in the field).
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/codex"
    }

    private static func turnID(in response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any] else { return nil }
        // Confirmed schema path: result.turn.id (TurnStartResponse → Turn.id).
        if let turn = result["turn"] as? [String: Any] {
            if let id = stringValue(turn["id"]) { return id }
        }
        return stringValue(result["turnId"]) ?? stringValue(result["turn_id"])
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
