//
//  TTSSpeakClient.swift
//  Yappy
//

import Darwin
import Foundation

final class TTSSpeakClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case pythonNotFound
        case helperNotFound
        case notRunning
        case busy
        case timeout(String)
        case helperLoad(String)
        case synthesis(String)
        case invalidReply
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .pythonNotFound: "Python with mlx-audio was not found."
            case .helperNotFound: "The Yappy TTS helper was not found in the app bundle."
            case .notRunning: "The TTS helper is not running."
            case .busy: "The TTS helper is already synthesizing."
            case .timeout(let message): message
            case .helperLoad(let message): message
            case .synthesis(let message): message
            case .invalidReply: "The TTS helper returned an invalid response."
            case .outputMissing: "The TTS helper did not create an audio file."
            }
        }
    }

    private static let modelID = "mlx-community/Kokoro-82M-8bit"
    private static let readinessLock = NSLock()
    private static var readinessCache: Bool?

    static var cachedReady: Bool? {
        get { readinessLock.withLock { readinessCache } }
        set { readinessLock.withLock { readinessCache = newValue } }
    }

    var onPhaseChange: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private let ioLock = NSLock()
    private let serialGate = TTSRequestSerialGate()

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var readyTask: Task<Void, Error>?
    private var readyToken: UUID?
    private var pendingReady: CheckedContinuation<Double, Error>?
    private var pendingReply: CheckedContinuation<[String: Any], Error>?
    private var ready = false
    private var loadSecs: Double?
    private(set) var isDownloadingModel = false
    private var outputCounter: UInt64 = 0

    init() {
        try? purgeSessionOutputs()
    }

    // MARK: - Readiness probe

    static func probeReadiness() async -> Bool {
        if let cachedReady { return cachedReady }
        return await refreshReadiness()
    }

    static func refreshReadiness() async -> Bool {
        let result: Bool? = await Task.detached(priority: .utility) {
            guard let python = resolvedPythonPath() else { return false }
            return runImportProbe(python: python)
        }.value
        // A timed-out probe is indeterminate (nil), not a definitive "not
        // installed": leaving the cache unresolved means the next availability
        // check re-probes instead of latching the Speak button off after one
        // slow cold start. A clean import failure caches a real `false`.
        cachedReady = result
        return result ?? false
    }

    private static func pythonCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "\(home)/.local/bin/python3",
            "/usr/bin/python3"
        ]
    }

    private static func resolvedPythonPath() -> String? {
        pythonCandidates().first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func minimalEnvironment() -> [String: String] {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "HOME": realHome,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "\(realHome)/.local/bin:\(realHome)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]
    }

    /// Returns true if the runtime imports cleanly, false on a definitive import
    /// failure, and nil if the probe timed out (indeterminate — the caller should
    /// not latch this as "not installed").
    private static func runImportProbe(python: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        // Constructing misaki's English G2P is the honest readiness gate: it
        // imports mlx_audio + misaki[en] and calls spacy.load("en_core_web_sm"),
        // so it fails exactly when a hard requirement is missing. A missing
        // espeak-ng only degrades out-of-dictionary coverage (misaki catches it),
        // so it correctly does not fail the probe.
        process.arguments = ["-c", "import mlx_audio; from misaki import en; en.G2P()"]
        process.environment = minimalEnvironment()

        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        process.standardOutput = devNull
        process.standardError = devNull

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        // The probe loads spacy's en_core_web_sm, so allow more headroom than a
        // bare import would need — cold starts can take a couple of seconds.
        if done.wait(timeout: .now() + 6) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil // indeterminate — a slow cold start, not "not installed"
        }

        return process.terminationStatus == 0
    }

    // MARK: - Lifecycle

    /// Fire-and-forget warmup: spawn the helper and load the model ahead of the
    /// first synthesis (e.g. on Fn-down while the model is still answering), so
    /// speech starts right after the answer instead of paying a cold load then.
    /// Cheap when already warm; errors are swallowed. The idle timer still bounds
    /// residency, so this never keeps the helper resident for long.
    func prewarm() {
        Task { [weak self] in try? await self?.ensureReady() }
    }

    func ensureReady() async throws {
        cancelIdleShutdown()

        let (task, token): (Task<Void, Error>, UUID) = lock.withLock {
            if let readyTask, let readyToken {
                return (readyTask, readyToken)
            }
            // Only a genuinely cold start announces itself — the warm path must
            // not flash "loading" on every chunk.
            firePhase("loading")
            let token = UUID()
            let t = Task {
                try self.start()
                let downloader = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.markDownloadingModel()
                }
                defer { downloader.cancel() }
                let loadSecs = try await self.waitForReady(timeout: 90)
                self.lock.withLock {
                    self.loadSecs = loadSecs
                    self.isDownloadingModel = false
                }
                VLog.tts("load_secs=\(Self.format(loadSecs))")
                self.firePhase("ready")
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

    func synthesize(
        text: String,
        voice: String,
        speed: Double = 1.0,
        padStartMs: Int = 0
    ) async throws -> URL {
        cancelIdleShutdown()
        try await ensureReady()

        await serialGate.enter()
        do {
            let url = try await synthesizeSerial(
                text: text, voice: voice, speed: speed, padStartMs: padStartMs)
            await serialGate.leave()
            return url
        } catch {
            await serialGate.leave()
            throw error
        }
    }

    func noteIdle() {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        lock.withLock {
            idleTask?.cancel()
            idleTask = task
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        stderrTask?.cancel()
        stderrTask = nil

        let child = process
        child?.terminate()

        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil

        let pending: (CheckedContinuation<Double, Error>?, CheckedContinuation<[String: Any], Error>?) = lock.withLock {
            idleTask?.cancel()
            idleTask = nil
            readyTask = nil
            readyToken = nil
            ready = false
            isDownloadingModel = false
            let readyContinuation = pendingReady
            let replyContinuation = pendingReply
            pendingReady = nil
            pendingReply = nil
            return (readyContinuation, replyContinuation)
        }

        pending.0?.resume(throwing: ClientError.notRunning)
        pending.1?.resume(throwing: ClientError.notRunning)

        if let child {
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func start() throws {
        if process?.isRunning == true { return }
        guard let python = Self.resolvedPythonPath() else { throw ClientError.pythonNotFound }
        guard let script = Bundle.main.url(forResource: "yappy-tts-helper", withExtension: "py") else {
            throw ClientError.helperNotFound
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = [script.path, Self.modelID]
        child.environment = Self.minimalEnvironment()
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = errorPipe
        child.terminationHandler = { [weak self] proc in
            VLog.tts("helper exited status=\(proc.terminationStatus)")
            self?.handleTermination(proc)
        }

        try child.run()
        VLog.tts("helper spawned pid=\(child.processIdentifier)")

        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.process = child
        lock.withLock {
            ready = false
            isDownloadingModel = false
        }
        startReader(outputPipe.fileHandleForReading)
        startStderrDrain(errorPipe.fileHandleForReading)
    }

    private func handleTermination(_ child: Process) {
        let pending: (CheckedContinuation<Double, Error>?, CheckedContinuation<[String: Any], Error>?) = lock.withLock {
            guard process === child || process == nil else { return (nil, nil) }
            process = nil
            inputPipe = nil
            outputPipe = nil
            errorPipe = nil
            readyTask = nil
            readyToken = nil
            ready = false
            isDownloadingModel = false
            let readyContinuation = pendingReady
            let replyContinuation = pendingReply
            pendingReady = nil
            pendingReply = nil
            return (readyContinuation, replyContinuation)
        }
        pending.0?.resume(throwing: ClientError.notRunning)
        pending.1?.resume(throwing: ClientError.notRunning)
    }

    private func waitForReady(timeout: TimeInterval) async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            var immediate: Result<Double, Error>?
            lock.lock()
            if ready {
                immediate = .success(loadSecs ?? 0)
            } else if pendingReady != nil {
                immediate = .failure(ClientError.busy)
            } else {
                pendingReady = continuation
            }
            lock.unlock()

            if let immediate {
                continuation.resume(with: immediate)
                return
            }

            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                let timedOut = self.lock.withLock {
                    let pending = self.pendingReady
                    self.pendingReady = nil
                    return pending
                }
                if let timedOut {
                    self.stop()
                    timedOut.resume(throwing: ClientError.timeout("Timed out loading the TTS voice."))
                }
            }
        }
    }

    private func synthesizeSerial(
        text: String,
        voice: String,
        speed: Double,
        padStartMs: Int
    ) async throws -> URL {
        let outputURL = try nextOutputURL()
        let request: [String: Any] = [
            "text": text,
            "voice": voice,
            "speed": speed,
            "out": outputURL.path,
            "pad_ms": padStartMs
        ]

        let timeout = max(20, Double(text.count) * 0.06)
        let reply = try await sendSynthesisRequest(request, timeout: timeout)
        guard let ok = reply["ok"] as? Bool else { throw ClientError.invalidReply }

        if !ok {
            // The helper's error strings are exception type + shape info from
            // our own script, never transcript content — safe to log.
            let message = reply["error"] as? String ?? "TTS synthesis failed."
            VLog.tts("synthesis failed: \(message.prefix(120))")
            throw ClientError.synthesis(message)
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ClientError.outputMissing
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)

        let secs = (reply["secs"] as? NSNumber)?.doubleValue ?? reply["secs"] as? Double ?? 0
        let duration = (reply["duration"] as? NSNumber)?.doubleValue ?? reply["duration"] as? Double ?? 0
        let loadSecs = lock.withLock { self.loadSecs ?? 0 }
        VLog.tts("chars=\(text.count) secs=\(Self.format(secs)) duration=\(Self.format(duration)) load_secs=\(Self.format(loadSecs))")
        return outputURL
    }

    private func sendSynthesisRequest(_ object: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if pendingReply != nil {
                lock.unlock()
                continuation.resume(throwing: ClientError.busy)
                return
            }
            pendingReply = continuation
            lock.unlock()

            do {
                try sendRaw(object)
            } catch {
                let pending = lock.withLock {
                    let reply = pendingReply
                    pendingReply = nil
                    return reply
                }
                pending?.resume(throwing: error)
                return
            }

            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                let timedOut = self.lock.withLock {
                    let pending = self.pendingReply
                    self.pendingReply = nil
                    return pending
                }
                if let timedOut {
                    self.stop()
                    timedOut.resume(throwing: ClientError.timeout("Timed out synthesizing speech."))
                }
            }
        }
    }

    private func sendRaw(_ object: [String: Any]) throws {
        guard let input = inputPipe?.fileHandleForWriting else {
            throw ClientError.notRunning
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        ioLock.withLock {
            input.write(data + Data("\n".utf8))
        }
    }

    // MARK: - Output files

    private func nextOutputURL() throws -> URL {
        let dir = try outputDirectory()
        let counter = lock.withLock {
            outputCounter += 1
            return outputCounter
        }
        return dir.appendingPathComponent("answer-\(counter).wav")
    }

    private func outputDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yappy", isDirectory: true)
        let dir = base.appendingPathComponent("tts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private func purgeSessionOutputs() throws {
        let dir = try outputDirectory()
        for url in try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Readers

    private func startReader(_ handle: FileHandle) {
        readTask?.cancel()
        readTask = makeLineReader(handle) { [weak self] line in
            self?.handleLine(line)
        }
    }

    private func startStderrDrain(_ handle: FileHandle) {
        stderrTask?.cancel()
        stderrTask = makeStderrDrain(handle) { line in
            if VLog.contentLoggingEnabled,
               let text = String(data: line, encoding: .utf8), !text.isEmpty {
                VLog.tts("helper stderr: \(text.prefix(300))")
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if object["ready"] != nil {
            handleReadyReply(object)
        } else if object["ok"] != nil {
            handleSynthesisReply(object)
        }
    }

    private func handleReadyReply(_ object: [String: Any]) {
        let result: Result<Double, Error>
        if object["ready"] as? Bool == true {
            let secs = (object["load_secs"] as? NSNumber)?.doubleValue ?? object["load_secs"] as? Double ?? 0
            result = .success(secs)
        } else {
            let message = object["error"] as? String ?? "TTS helper failed to load."
            result = .failure(ClientError.helperLoad(message))
        }

        let pending = lock.withLock {
            if case .success(let secs) = result {
                ready = true
                loadSecs = secs
            }
            let continuation = pendingReady
            pendingReady = nil
            return continuation
        }
        pending?.resume(with: result)
    }

    private func handleSynthesisReply(_ object: [String: Any]) {
        let pending = lock.withLock {
            let continuation = pendingReply
            pendingReply = nil
            return continuation
        }
        pending?.resume(returning: object)
    }

    // MARK: - Helpers

    private func cancelIdleShutdown() {
        lock.withLock {
            idleTask?.cancel()
            idleTask = nil
        }
    }

    private func markDownloadingModel() {
        let shouldFire = lock.withLock {
            guard pendingReady != nil, !isDownloadingModel else { return false }
            isDownloadingModel = true
            return true
        }
        if shouldFire {
            firePhase("downloading")
        }
    }

    private func firePhase(_ phase: String) {
        onPhaseChange?(phase)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

actor TTSRequestSerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

protocol AnswerSpeaking: AnyObject {
    var onPhaseChange: (@Sendable (String) -> Void)? { get set }
    func synthesize(text: String, voice: String, speed: Double, padStartMs: Int) async throws -> URL
    func noteIdle()
    func stop()
}

extension TTSSpeakClient: AnswerSpeaking {}
