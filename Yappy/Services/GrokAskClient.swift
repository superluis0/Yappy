//
//  GrokAskClient.swift
//  Yappy
//
//  Answers an Ask question through the Grok Build CLI as an alternative brain
//  to the Codex app-server. Runs in `--permission-mode plan` — read-only, so
//  Grok can web-search and cite sources but cannot modify files or take actions
//  (verified: plan mode still performs web search). Ported from VoiceAgent's
//  GrokCLIClient, stripped of the MCP bridge.
//
//  ## Why the isolated Grok home
//  Grok merges the user's global ~/.grok — dozens of plugin MCP servers that
//  cold-load on every spawn (10–12s, several failing on auth). Ask needs only
//  Grok's built-in web search. So every turn runs with HOME pointed at a private
//  directory whose .grok holds an empty config + a fresh copy of auth.json
//  (copied, never symlinked, so a token refresh here can't clobber the real
//  credentials). No plugins load; the user's global setup is never touched.
//

import Foundation
import QuartzCore

final class GrokAskClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case grokNotFound
        case notLoggedIn

        var errorDescription: String? {
            switch self {
            case .grokNotFound:
                "The Grok CLI was not found. Install it and sign in with `grok login`."
            case .notLoggedIn:
                "Grok is not signed in. Run `grok login` in a terminal."
            }
        }
    }

    var onEvent: (@Sendable (GrokEvent) -> Void)?

    private let lock = NSLock()
    private var process: Process?

    // MARK: - Discovery

    static var resolvedGrokPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.grok/bin/grok",
            "\(home)/.npm-global/bin/grok",
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { resolvedGrokPath != nil }

    /// The user has signed in at least once (`grok login`).
    static var isSignedIn: Bool {
        FileManager.default.fileExists(atPath: realAuthURL.path)
    }

    /// Real `~/.grok/auth.json`, the source of the login token. Read-only for us.
    private static var realAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    // MARK: - Isolated Grok home

    /// Serializes concurrent home preparation — the remove-then-copy auth
    /// refresh is not atomic, and overlapping prewarm/spawn paths collided on
    /// it in practice ("auth.json couldn't be copied … already exists").
    private static let homeLock = NSLock()

    /// The private Grok home's path, creating the directory tree if needed —
    /// NO config or auth side effects. For callers that only need the cwd
    /// (e.g. session/new on an already-spawned agent); the spawn paths use
    /// `prepareGrokHome()` so a per-session call can never clobber a fresher
    /// CLI-refreshed token with a stale recopy.
    static func grokHomeURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let home = base.appendingPathComponent("Yappy/GrokHome", isDirectory: true)
        let dotGrok = home.appendingPathComponent(".grok", isDirectory: true)
        try FileManager.default.createDirectory(at: dotGrok, withIntermediateDirectories: true)
        return home
    }

    /// Creates/refreshes the private Grok home and returns its path. The home's
    /// `.grok/config.toml` is empty (no MCP servers, no plugins); `auth.json` is
    /// copied fresh from the real login at spawn.
    static func prepareGrokHome() throws -> URL {
        try homeLock.withLock {
            let home = try grokHomeURL()
            let dotGrok = home.appendingPathComponent(".grok", isDirectory: true)

            // Empty config — no plugins, no MCP servers. Grok's built-in web search
            // is all Ask needs.
            let config = "# Yappy Ask — isolated Grok home. No plugins, no MCP servers.\n[cli]\nauto_update = false\n"
            let configFile = dotGrok.appendingPathComponent("config.toml")
            if (try? String(contentsOf: configFile, encoding: .utf8)) != config {
                try config.write(to: configFile, atomically: true, encoding: .utf8)
            }

            guard FileManager.default.fileExists(atPath: realAuthURL.path) else {
                throw ClientError.notLoggedIn
            }
            let authCopy = dotGrok.appendingPathComponent("auth.json")
            try? FileManager.default.removeItem(at: authCopy)
            try FileManager.default.copyItem(at: realAuthURL, to: authCopy)

            // Owner-only, always: the home holds a login token and, briefly,
            // the spoken question (prompt file).
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dotGrok.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authCopy.path)

            return home
        }
    }

    // MARK: - Turns

    /// Whether attempt 0 should be retried with legacy CLI flags.
    /// True only on a quick, silent failure (non-zero exit, no events, <5s, not cancelled).
    static func shouldRetryWithLegacyArgs(
        exitStatus: Int32,
        sawAnyEvent: Bool,
        elapsed: Double,
        wasCancelled: Bool
    ) -> Bool {
        exitStatus != 0 && !sawAnyEvent && elapsed < 5.0 && !wasCancelled
    }

    /// Starts a research turn. `--permission-mode plan` keeps it read-only:
    /// web search + citation, no file or system mutation.
    /// The caller supplies the user prompt and optional system override separately.
    func ask(_ request: GrokAskRequest) async throws {
        try Task.checkCancellation()
        guard let grokPath = Self.resolvedGrokPath else { throw ClientError.grokNotFound }
        let home = try Self.prepareGrokHome()
        let trimmedModel = request.model.trimmingCharacters(in: .whitespacesAndNewlines)

        // The spoken question must never ride in argv (process arguments are
        // visible to every local process while the turn runs) - it goes
        // through a 0600 file inside the private home instead.
        let promptFile = home.appendingPathComponent(".grok/ask-prompt.txt")
        try request.prompt.write(to: promptFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptFile.path)
        defer { try? FileManager.default.removeItem(at: promptFile) }

        for attempt in 0..<2 {
            if attempt == 1 {
                VLog.grok("arg fallback — retrying with legacy flags")
            }
            cancel()

            let result = await spawnAndRead(
                grokPath: grokPath,
                home: home,
                request: request,
                promptFile: promptFile,
                trimmedModel: trimmedModel,
                legacy: attempt == 1
            )

            if attempt == 0,
               Self.shouldRetryWithLegacyArgs(
                   exitStatus: result.exitStatus,
                   sawAnyEvent: result.sawAnyEvent,
                   elapsed: result.elapsed,
                   wasCancelled: result.wasCancelled
               ) {
                continue
            }

            if !result.sawEnd && !result.wasCancelled {
                onEvent?(.error(message: "Grok exited (status \(result.exitStatus)) without finishing. Check `grok login` and connectivity."))
            }
            return
        }
    }

    func cancel() {
        lock.lock(); let running = process; process = nil; lock.unlock()
        if let running, running.isRunning {
            VLog.grok("turn cancelled — terminating process")
            running.terminate()
        }
    }

    /// `cancel()` + bounded wait for actual child exit, so a purge that
    /// follows cannot race the child's sqlite WAL checkpoint. Safe on main
    /// thread for timeouts <= 2s (termination is near-instant); returns
    /// early on exit.
    func stopAndWait(timeout: TimeInterval) {
        let running = lock.withLock { process }
        cancel()
        ProcessExitWaiter.waitForExit(running, timeout: timeout)
    }

    // MARK: - Spawn + stream reading

    /// Pure builder for the turn's spawn environment, isolated from
    /// `spawnAndRead` so isolation-pin tests can characterize it without
    /// spawning a real process. HOME is pinned to the private Grok home —
    /// Grok's filesystem isolation hangs entirely on this.
    static func spawnEnvironment(home: URL) -> [String: String] {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "HOME": home.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "\(realHome)/.local/bin:\(realHome)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]
    }

    private struct TurnResult {
        var sawAnyEvent: Bool
        var exitStatus: Int32
        var wasCancelled: Bool
        var sawEnd: Bool
        var elapsed: Double
    }

    private func spawnAndRead(
        grokPath: String,
        home: URL,
        request: GrokAskRequest,
        promptFile: URL,
        trimmedModel: String,
        legacy: Bool
    ) async -> TurnResult {
        var arguments: [String]
        if legacy {
            arguments = [
                "--prompt-file", promptFile.path,
                "--output-format", "streaming-json",
                "--cwd", home.path,
                "--permission-mode", "plan",
            ]
        } else {
            arguments = [
                "--prompt-file", promptFile.path,
                "--output-format", "streaming-json",
                "--cwd", home.path,
                "--permission-mode", "plan",
                "--effort", request.effort,
                "--no-plan", "--no-subagents", "--no-memory",
            ]
            if let sys = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sys.isEmpty {
                arguments += ["--system-prompt-override", sys]
            }
        }
        if !trimmedModel.isEmpty { arguments += ["-m", trimmedModel] }
        if let sid = request.resumeSessionID {
            arguments += ["--resume", sid]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: grokPath)
        process.arguments = arguments
        process.currentDirectoryURL = home

        // Minimal, fixed environment: the child gets exactly what it needs and
        // nothing the app process happened to inherit. ~/.local/bin comes first
        // in PATH: that's where node lives, and the npm shim needs it.
        process.environment = Self.spawnEnvironment(home: home)

        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let spawnedAt = CACurrentMediaTime()
        VLog.grok("ask start — model=\(trimmedModel.isEmpty ? "default" : trimmedModel) home=\(home.lastPathComponent) legacy=\(legacy)")
        do {
            try process.run()
        } catch {
            VLog.grok("process.run failed: \(error.localizedDescription)")
            return TurnResult(sawAnyEvent: false, exitStatus: -1, wasCancelled: false, sawEnd: false, elapsed: CACurrentMediaTime() - spawnedAt)
        }
        startStderrDrain(stderr.fileHandleForReading)

        lock.withLock { self.process = process }

        return await readEvents(from: stdout.fileHandleForReading, process: process, spawnedAt: spawnedAt)
    }

    /// Grok logs to stderr. Drain it (an undrained 64 KB pipe blocks the child)
    /// and surface it for diagnostics.
    private func startStderrDrain(_ handle: FileHandle) {
        // Fire-and-forget (no stored task): this client has no cancel path for the
        // drain; the loop ends when the pipe closes (availableData empty).
        _ = makeStderrDrain(handle) { line in
            if VLog.contentLoggingEnabled,
               let text = String(data: line, encoding: .utf8), !text.isEmpty {
                VLog.grok("stderr: \(text.prefix(300))")
            }
        }
    }

    private func readEvents(from handle: FileHandle, process: Process, spawnedAt: Double) async -> TurnResult {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                var buffer = Data()
                var sawEnd = false
                var sawAnyEvent = false
                var loggedFirstEvent = false
                var loggedFirstText = false
                var thoughtCount = 0
                var textChars = 0

                func ms(_ from: Double) -> Int { Int((CACurrentMediaTime() - from) * 1000) }

                func emit(_ event: GrokEvent) {
                    sawAnyEvent = true
                    if !loggedFirstEvent {
                        loggedFirstEvent = true
                        VLog.grok("first event at +\(ms(spawnedAt))ms (startup)")
                    }
                    switch event {
                    case .thought:
                        thoughtCount += 1
                    case .text(let d):
                        textChars += d.count
                        if !loggedFirstText {
                            loggedFirstText = true
                            VLog.grok("first answer token at +\(ms(spawnedAt))ms")
                        }
                    case .end(let reason, _):
                        sawEnd = true
                        VLog.grok("end (\(reason ?? "?")) at +\(ms(spawnedAt))ms — thoughts=\(thoughtCount) answerChars=\(textChars)")
                    case .toolStarted(let title):
                        VLog.grok("tool started: \(title)")
                    case .toolCompleted(let title, let failed):
                        VLog.grok("tool completed: \(title) failed=\(failed)")
                    case .error(let m):
                        VLog.grok("error event: \(m)")
                    case .ignored(let t):
                        VLog.grok("ignored event type=\(t)")
                    }
                    self?.onEvent?(event)
                }

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if let line = String(data: lineData, encoding: .utf8),
                           let event = GrokEvent.parse(line: line) {
                            emit(event)
                        }
                    }
                }
                if let line = String(data: buffer, encoding: .utf8),
                   let event = GrokEvent.parse(line: line) {
                    emit(event)
                }

                process.waitUntilExit()
                guard let self else {
                    continuation.resume(returning: TurnResult(
                        sawAnyEvent: sawAnyEvent,
                        exitStatus: process.terminationStatus,
                        wasCancelled: false,
                        sawEnd: sawEnd,
                        elapsed: CACurrentMediaTime() - spawnedAt
                    ))
                    return
                }

                let wasCancelled = self.lock.withLock {
                    self.process == nil || self.process !== process
                }
                let elapsed = CACurrentMediaTime() - spawnedAt
                VLog.grok("process exited status=\(process.terminationStatus) at +\(ms(spawnedAt))ms sawEnd=\(sawEnd) cancelled=\(wasCancelled)")

                self.lock.withLock {
                    if self.process === process { self.process = nil }
                }

                continuation.resume(returning: TurnResult(
                    sawAnyEvent: sawAnyEvent,
                    exitStatus: process.terminationStatus,
                    wasCancelled: wasCancelled,
                    sawEnd: sawEnd,
                    elapsed: elapsed
                ))
            }
        }
    }
}
