//
//  ParakeetTranscriptionService.swift
//  Yappy
//

import Foundation
import FluidAudio
import CryptoKit
import os

/// Local speech-to-text via a FluidAudio CoreML model (Apple Neural Engine).
///
/// This is the single app-facing transcription service. It can run either of two
/// models, chosen by `activeModel`:
///   - `.parakeet`: English-only Parakeet TDT (~443 MB), the default.
///   - `.nemotron`: NVIDIA Nemotron multilingual (~670 MB).
/// Both transcribe in batch on hotkey release. The model is downloaded once to
/// ~/Library/Application Support/FluidAudio/Models and loaded at app start (or on
/// switch) so transcription is immediate.
@MainActor
final class ParakeetTranscriptionService: ObservableObject {
    enum ModelState: Equatable {
        case notLoaded
        /// `progress` is nil when the backend exposes no granular progress
        /// (Nemotron) — the UI shows an indeterminate spinner instead of a percent.
        case downloading(progress: Double?)
        case loading
        case ready
        case failed(String)

        var statusDescription: String {
            switch self {
            case .notLoaded: return "Model not loaded"
            case .downloading(let progress):
                if let progress { return "Downloading model… \(Int(progress * 100))%" }
                return "Downloading model…"
            case .loading: return "Loading model…"
            case .ready: return "Ready"
            case .failed(let message): return "Model failed: \(message)"
            }
        }
    }

    @Published private(set) var modelState: ModelState = .notLoaded {
        didSet {
            Self.logger.info("Model state: \(self.modelState.statusDescription, privacy: .public)")
        }
    }

    /// Which model dictation uses. Set by `AppDelegate` from `settings.transcriptionModel`
    /// before warm-up, and updated when the user changes the setting. Switching to a
    /// different model unloads the previous one and resets `modelState` to `.notLoaded`
    /// so the next `warmUp()` (re)loads the now-active model lazily.
    var activeModel: TranscriptionModel = .parakeet {
        didSet {
            guard activeModel != oldValue else { return }
            Self.logger.info("Active model -> \(self.activeModel.rawValue, privacy: .public)")
            // Drop the previously-loaded engine; the FluidAudio cache keeps both
            // models on disk, so re-selecting one later reloads (no re-download).
            asrManager = nil
            nemotronManager = nil
            modelState = .notLoaded
        }
    }

    nonisolated private static let logger = Logger(subsystem: "com.yappy.app", category: "transcription")

    // Parakeet (TDT) backing state.
    private var asrManager: AsrManager?
    private var decoderLayers: Int = 2

    // Download stall supervision (see warmUp).
    private var warmUpTask: Task<Void, Never>?
    private var downloadStalled = false
    private var lastDownloadAdvance = Date()
    private var lastDownloadFraction: Double = -1

    /// English-only Parakeet — same model variant Spokenly uses.
    nonisolated private static let modelVersion: AsrModelVersion = .v2

    /// Public zip for the exact Parakeet v2 CoreML model from the `models-1`
    /// GitHub release. Seeding FluidAudio's cache from this keeps first run off
    /// HuggingFace when the hosted artifact is healthy.
    nonisolated private static let selfHostedParakeetZipURLString =
        "https://github.com/superluis0/Yappy/releases/download/models-1/parakeet-tdt-0.6b-v2-coreml.zip"

    /// SHA-256 for the `models-1` GitHub release zip.
    nonisolated private static let selfHostedParakeetZipSHA256 =
        "d1cbd181e0d5f3c47e477dba6bea91baf6a16322ca7d540df5edf300a6bec982"

    /// Top-level folder inside the `models-1` GitHub release zip.
    nonisolated private static let selfHostedParakeetFolderName =
        "parakeet-tdt-0.6b-v2-coreml"

    /// FluidAudio cache entries expected inside the `models-1` GitHub release zip.
    nonisolated private static let selfHostedParakeetRequiredEntries = [
        "Decoder.mlmodelc",
        "Encoder.mlmodelc",
        "JointDecision.mlmodelc",
        "Preprocessor.mlmodelc",
        "config.json",
        "parakeet_vocab.json"
    ]

    // Nemotron (multilingual) backing state.
    private var nemotronManager: StreamingNemotronMultilingualAsrManager?

    // MARK: - Vocabulary-boosting state (Parakeet/English only)

    /// FluidAudio's CTC custom-vocabulary rescoring pipeline, configured lazily by
    /// `configureVocabularyBoosting(terms:)` and consulted after each Parakeet
    /// transcribe. All three are non-nil together (a configured session) or all nil
    /// (torn down). Never touched on the Nemotron path.
    private var vocabularySpotter: CtcKeywordSpotter?
    private var vocabularyRescorer: VocabularyRescorer?
    private var vocabularyContext: CustomVocabularyContext?

    /// `downloadVariant` arguments mirroring the `nemotron-multilingual-transcribe`
    /// CLI: the full multilingual ship ("auto") at the balanced 2240 ms chunk tier.
    private static let nemotronLanguageCode = "auto"
    private static let nemotronChunkMs = 2240

    /// Block size for feeding the recorded buffer into the Nemotron manager
    /// (~2 s at 16 kHz). The manager re-chunks internally to its own chunk size;
    /// this only bounds the per-call append cost over a whole dictation.
    private static let nemotronFeedBlockSamples = 32_000

    // MARK: - Lifecycle

    /// Loads (downloading first if necessary) the active model and pre-warms it.
    /// Safe to call again after a failure, or after `activeModel` changes.
    ///
    /// The download leg is watchdogged: FluidAudio's per-request timeout is 30
    /// minutes, so a silently stalled connection would otherwise pin the app at
    /// "Downloading…" with a frozen bar. If byte progress stops advancing for
    /// 60s the in-flight attempt is cancelled (URLSession's async download
    /// honors Task cancellation) and retried, twice, before failing honestly.
    func warmUp() async {
        guard modelState == .notLoaded || isFailed else { return }

        var attemptsLeft = 3
        repeat {
            attemptsLeft -= 1
            downloadStalled = false
            lastDownloadAdvance = Date()
            lastDownloadFraction = -1

            let attempt = Task { [weak self] in
                guard let self else { return }
                switch self.activeModel {
                case .parakeet: await self.warmUpParakeet()
                case .nemotron: await self.warmUpNemotron()
                }
            }
            warmUpTask = attempt
            // Nemotron's download reports no granular progress, so a byte-advance
            // watchdog can only supervise Parakeet.
            let watchdog = activeModel == .parakeet ? startDownloadStallWatchdog(cancelling: attempt) : nil
            await attempt.value
            watchdog?.cancel()
            warmUpTask = nil

            if downloadStalled, attemptsLeft > 0 {
                Self.logger.warning("Model download stalled — retrying (\(attemptsLeft) attempts left)")
                modelState = .notLoaded
            }
        } while downloadStalled && attemptsLeft > 0 && modelState == .notLoaded
    }

    /// Cancels the running warm-up attempt when byte progress stops advancing.
    private func startDownloadStallWatchdog(cancelling attempt: Task<Void, Never>) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                // Only the download leg can stall silently; loading/compiling is
                // local work that legitimately reports nothing for a while.
                guard case .downloading = self.modelState else { continue }
                if Date().timeIntervalSince(self.lastDownloadAdvance) > 60 {
                    self.downloadStalled = true
                    attempt.cancel()
                    return
                }
            }
        }
    }

    /// Loads the Parakeet models and pre-warms the ANE.
    private func warmUpParakeet() async {
        let cacheDir = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
        let cached = AsrModels.modelsExist(at: cacheDir, version: Self.modelVersion)
        modelState = cached ? .loading : .downloading(progress: 0)

        if !cached {
            let installedSelfHostedModel = await installSelfHostedParakeetIfPossible()
            if !installedSelfHostedModel && !Task.isCancelled {
                lastDownloadFraction = -1
                lastDownloadAdvance = Date()
                modelState = .downloading(progress: 0)
            }
        }

        do {
            let models = try await AsrModels.downloadAndLoad(
                version: Self.modelVersion,
                progressHandler: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.modelState else { return }
                        let fraction = progress.fractionCompleted
                        // Feed the stall watchdog: only genuine forward motion counts.
                        if fraction > self.lastDownloadFraction + 0.0005 {
                            self.lastDownloadFraction = fraction
                            self.lastDownloadAdvance = Date()
                        }
                        self.modelState = .downloading(progress: fraction)
                    }
                }
            )

            modelState = .loading
            decoderLayers = models.version.decoderLayers

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager

            // Run a short silent clip through the pipeline so the first real
            // dictation doesn't pay the ANE compilation cost.
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            _ = try? await manager.transcribe(
                [Float](repeating: 0, count: 16000), decoderState: &state)

            modelState = .ready
        } catch {
            asrManager = nil
            // A watchdog cancellation is a stall, not a real error — report it in
            // words a user can act on (warmUp may retry before this ever shows).
            if downloadStalled || error is CancellationError {
                modelState = .failed("The model download stalled. Check your internet connection and try again.")
            } else {
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    /// Best-effort cache seeding from Yappy's hosted Parakeet zip.
    ///
    /// This never becomes a correctness dependency: all errors are contained and
    /// the caller always falls through to FluidAudio's existing download/load path.
    /// Heavy work runs in nonisolated helpers; this actor-isolated wrapper only
    /// feeds the same progress state the stall watchdog already supervises.
    private func installSelfHostedParakeetIfPossible() async -> Bool {
        await Self.installSelfHostedParakeetIfPossible(
            progressHandler: { [weak self] fraction in
                await MainActor.run { [weak self] in
                    guard let self, case .downloading = self.modelState else { return }
                    if fraction > self.lastDownloadFraction + 0.0005 {
                        self.lastDownloadFraction = fraction
                        self.lastDownloadAdvance = Date()
                    }
                    self.modelState = .downloading(progress: fraction)
                }
            },
            loadingHandler: { [weak self] in
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.modelState = .loading
                }
            }
        )
    }

    private enum SelfHostedParakeetInstallError: Error {
        case invalidURL
        case nonHTTPResponse
        case httpStatus(Int)
        case missingContentLength
        case zipFileCreationFailed
        case checksumMismatch
        case dittoFailed(Int32)
        case stagedModelInvalid(missingCount: Int)
        case cacheValidationFailed

        var logMessage: String {
            switch self {
            case .invalidURL:
                return "Self-hosted Parakeet install failed: invalid release URL"
            case .nonHTTPResponse:
                return "Self-hosted Parakeet install failed: non-HTTP response"
            case .httpStatus(let status):
                return "Self-hosted Parakeet install failed: HTTP status \(status)"
            case .missingContentLength:
                return "Self-hosted Parakeet install failed: missing content length"
            case .zipFileCreationFailed:
                return "Self-hosted Parakeet install failed: temporary zip creation failed"
            case .checksumMismatch:
                return "Self-hosted Parakeet install failed: checksum mismatch"
            case .dittoFailed(let status):
                return "Self-hosted Parakeet install failed: ditto exited with status \(status)"
            case .stagedModelInvalid(let missingCount):
                return "Self-hosted Parakeet install failed: staged model missing \(missingCount) required item(s)"
            case .cacheValidationFailed:
                return "Self-hosted Parakeet install failed: cache validation failed"
            }
        }
    }

    /// Performs the self-hosted install off the main actor, reporting only coarse
    /// progress back to the caller. Returning `false` is intentionally silent to
    /// users: FluidAudio's HuggingFace-backed path remains the fallback for every
    /// failure mode, including cancellation by the stall watchdog.
    nonisolated private static func installSelfHostedParakeetIfPossible(
        progressHandler: (Double) async -> Void,
        loadingHandler: () async -> Void
    ) async -> Bool {
        do {
            try Task.checkCancellation()

            guard let url = URL(string: selfHostedParakeetZipURLString) else {
                throw SelfHostedParakeetInstallError.invalidURL
            }

            let fileManager = FileManager.default
            let downloadDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("YappyParakeetDownload-\(UUID().uuidString)", isDirectory: true)
            let stagingDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("YappyParakeetStaging-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? fileManager.removeItem(at: downloadDirectory)
                try? fileManager.removeItem(at: stagingDirectory)
            }

            try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

            let zipURL = downloadDirectory.appendingPathComponent("parakeet.zip", isDirectory: false)
            try await downloadSelfHostedParakeetZip(from: url, to: zipURL, progressHandler: progressHandler)
            try Task.checkCancellation()

            let digest = try await sha256HexDigest(of: zipURL) { fraction in
                await progressHandler(0.85 + (fraction * 0.05))
            }
            guard digest == selfHostedParakeetZipSHA256 else {
                throw SelfHostedParakeetInstallError.checksumMismatch
            }
            await progressHandler(0.90)
            try Task.checkCancellation()

            try await unzipSelfHostedParakeet(zipURL: zipURL, to: stagingDirectory)
            await progressHandler(0.96)
            try Task.checkCancellation()

            let stagedModelDirectory = stagingDirectory
                .appendingPathComponent(selfHostedParakeetFolderName, isDirectory: true)
            let missingEntries = missingRequiredModelEntries(
                in: stagedModelDirectory,
                requiredEntries: selfHostedParakeetRequiredEntries,
                fileManager: fileManager
            )
            guard missingEntries.isEmpty else {
                throw SelfHostedParakeetInstallError.stagedModelInvalid(missingCount: missingEntries.count)
            }
            await progressHandler(0.99)
            try Task.checkCancellation()

            let cacheDirectory = AsrModels.defaultCacheDirectory(for: modelVersion)
            let cacheParent = cacheDirectory.deletingLastPathComponent()
            try fileManager.createDirectory(at: cacheParent, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.removeItem(at: cacheDirectory)
            }

            try fileManager.moveItem(at: stagedModelDirectory, to: cacheDirectory)
            guard AsrModels.modelsExist(at: cacheDirectory, version: modelVersion) else {
                throw SelfHostedParakeetInstallError.cacheValidationFailed
            }

            await loadingHandler()
            Self.logger.info("Self-hosted Parakeet install completed")
            return true
        } catch is CancellationError {
            Self.logger.warning("Self-hosted Parakeet install cancelled")
            return false
        } catch let error as SelfHostedParakeetInstallError {
            Self.logger.warning("\(error.logMessage, privacy: .public)")
            return false
        } catch {
            Self.logger.warning("Self-hosted Parakeet install failed: unexpected local or network error")
            return false
        }
    }

    nonisolated private static func downloadSelfHostedParakeetZip(
        from url: URL,
        to destinationURL: URL,
        progressHandler: (Double) async -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SelfHostedParakeetInstallError.nonHTTPResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SelfHostedParakeetInstallError.httpStatus(httpResponse.statusCode)
        }
        guard response.expectedContentLength > 0 else {
            throw SelfHostedParakeetInstallError.missingContentLength
        }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw SelfHostedParakeetInstallError.zipFileCreationFailed
        }

        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }

        let totalBytes = Double(response.expectedContentLength)
        let chunkSize = 1_048_576
        var pending = Data()
        pending.reserveCapacity(chunkSize)
        var bytesReceived = 0
        var bytesAtLastReport = 0

        for try await byte in bytes {
            if Task.isCancelled {
                throw CancellationError()
            }

            pending.append(byte)
            if pending.count >= chunkSize {
                try fileHandle.write(contentsOf: pending)
                bytesReceived += pending.count
                pending.removeAll(keepingCapacity: true)

                if bytesReceived - bytesAtLastReport >= chunkSize {
                    bytesAtLastReport = bytesReceived
                    await progressHandler((Double(bytesReceived) / totalBytes) * 0.85)
                }
            }
        }

        if !pending.isEmpty {
            try fileHandle.write(contentsOf: pending)
            bytesReceived += pending.count
        }
        await progressHandler(0.85)
    }

    nonisolated private static func sha256HexDigest(
        of fileURL: URL,
        progressHandler: (Double) async -> Void
    ) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        let totalBytes = Double((try fileHandle.seekToEnd()))
        try fileHandle.seek(toOffset: 0)

        var hasher = SHA256()
        let chunkSize = 1_048_576
        var bytesRead = 0
        var bytesAtLastReport = 0

        while true {
            if Task.isCancelled {
                throw CancellationError()
            }

            guard let data = try fileHandle.read(upToCount: chunkSize), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
            bytesRead += data.count

            if totalBytes > 0, bytesRead - bytesAtLastReport >= chunkSize {
                bytesAtLastReport = bytesRead
                await progressHandler(Double(bytesRead) / totalBytes)
            }
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func unzipSelfHostedParakeet(zipURL: URL, to stagingDirectory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, stagingDirectory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let terminationStatus = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminatedProcess in
                    continuation.resume(returning: terminatedProcess.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        guard terminationStatus == 0 else {
            throw SelfHostedParakeetInstallError.dittoFailed(terminationStatus)
        }
    }

    nonisolated static func modelDirectoryContainsRequiredEntries(
        presentEntries: Set<String>,
        requiredEntries: [String]
    ) -> Bool {
        requiredEntries.allSatisfy { presentEntries.contains($0) }
    }

    nonisolated private static func missingRequiredModelEntries(
        in directoryURL: URL,
        requiredEntries: [String],
        fileManager: FileManager
    ) -> [String] {
        let presentEntries = Set(
            requiredEntries.filter { entry in
                fileManager.fileExists(atPath: directoryURL.appendingPathComponent(entry).path)
            }
        )

        guard modelDirectoryContainsRequiredEntries(
            presentEntries: presentEntries,
            requiredEntries: requiredEntries
        ) else {
            return requiredEntries.filter { !presentEntries.contains($0) }
        }
        return []
    }

    /// Downloads (if needed) and loads the Nemotron multilingual model.
    /// `downloadVariant` exposes no granular progress for the multilingual ship,
    /// so the download is represented as indeterminate (`.downloading(progress: nil)`).
    private func warmUpNemotron() async {
        modelState = .downloading(progress: nil)

        do {
            let modelDir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: Self.nemotronLanguageCode,
                chunkMs: Self.nemotronChunkMs
            )

            modelState = .loading

            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: modelDir)
            nemotronManager = manager

            // Pre-warm: push a short silent clip through and finish, so the first
            // real dictation doesn't pay the ANE compilation cost. Reset after so
            // no warm-up audio leaks into the first transcript.
            _ = try? await manager.process(samples: [Float](repeating: 0, count: 16000))
            _ = try? await manager.finish()
            await manager.reset()

            modelState = .ready
        } catch {
            nemotronManager = nil
            modelState = .failed(error.localizedDescription)
        }
    }

    private var isFailed: Bool {
        if case .failed = modelState { return true }
        return false
    }

    // MARK: - Vocabulary Boosting

    /// A bounded, tokenization-ready dictionary term: canonical spelling plus the
    /// alternative spellings the model tends to produce. Deliberately free of
    /// FluidAudio types so the term-list builder is unit-testable without any
    /// model download.
    struct BoostTerm: Equatable {
        let text: String
        let aliases: [String]
    }

    /// Bounds on what we hand the CTC vocabulary pipeline. Terms shorter than
    /// `minTermLength` are dropped (matches FluidAudio's own `minTermLength`
    /// guardrail — short words like "or" trigger false positives), and the list is
    /// capped so a huge dictionary can't blow up the per-dictation rescoring cost.
    nonisolated static let vocabularyMinTermLength = 3
    nonisolated static let vocabularyMaxTermCount = 200

    /// Maps the user's dictionary into the bounded `[BoostTerm]` the CTC pipeline
    /// tokenizes. Pure and side-effect-free (no model access, `nonisolated` like
    /// `acceptsTranscript`) so it can be tested in isolation: drops terms under
    /// `vocabularyMinTermLength` characters, keeps the first `vocabularyMaxTermCount`
    /// in dictionary order, and folds each term's manual + learned aliases into the
    /// boost term's alias list.
    nonisolated static func buildBoostTerms(from terms: [DictionaryTerm]) -> [BoostTerm] {
        terms
            .filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= vocabularyMinTermLength }
            .prefix(vocabularyMaxTermCount)
            .map { BoostTerm(text: $0.text, aliases: $0.allAliases) }
    }

    /// A boost replacement is only trusted when the replaced word could plausibly
    /// be a *mishearing of the term* — i.e. it is textually close to the term or
    /// one of its aliases ("terra form" -> "Terraform", "harkonen" -> "Harkonnen").
    /// The CTC rescorer matches on acoustics alone and can false-positive on real
    /// words (field case: every spoken "error" was rewritten to "Terraform");
    /// text similarity is the cheap, deterministic backstop the acoustic match
    /// lacks. Below this normalized-edit-distance similarity, the whole rescue is
    /// rejected and the plain transcript kept.
    ///
    /// 0.6, not 0.5: a short word EMBEDDED in a term scores deceptively high on
    /// pure edit distance — "error" is a subsequence of "t-err-af-or-m", distance
    /// 4/9 = 0.56 similarity — and embedded words are exactly how the acoustic
    /// false positive arises. Genuine mishearings score 0.78+ ("harkonen" 0.89,
    /// "and tropic" -> "anthropic" 0.78, space-stripped aliases 1.0), and
    /// phonetically-distant mishearings are covered by their trained aliases in
    /// the candidate set, so 0.6 rejects the trap without losing real fixes.
    nonisolated static let boostReplacementMinSimilarity = 0.6

    /// Normalized edit-distance similarity in [0, 1]: 1 = identical, 0 = nothing
    /// shared. Case-insensitive. Pure and `nonisolated` for direct unit testing.
    nonisolated static func editSimilarity(_ a: String, _ b: String) -> Double {
        let s = Array(a.lowercased()), t = Array(b.lowercased())
        if s.isEmpty || t.isEmpty { return s.isEmpty && t.isEmpty ? 1 : 0 }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        let distance = prev[t.count]
        return 1.0 - Double(distance) / Double(max(s.count, t.count))
    }

    /// Whether replacing `original` with `term` is plausible as a mishearing fix:
    /// the original must be textually similar to the term or one of its aliases,
    /// compared both as-spoken and with spaces stripped (so the multi-word alias
    /// "terra form" matches "Terraform"). Pure; see `boostReplacementMinSimilarity`.
    nonisolated static func plausibleBoostReplacement(original: String, term: String, aliases: [String]) -> Bool {
        let strippedOriginal = original.replacingOccurrences(of: " ", with: "")
        for candidate in [term] + aliases {
            let strippedCandidate = candidate.replacingOccurrences(of: " ", with: "")
            if editSimilarity(original, candidate) >= boostReplacementMinSimilarity { return true }
            if editSimilarity(strippedOriginal, strippedCandidate) >= boostReplacementMinSimilarity { return true }
        }
        return false
    }

    /// Configures (or tears down) speech-model vocabulary biasing from the user's
    /// dictionary. Loading the auxiliary CTC model, tokenizer, and rescorer is
    /// expensive, so ALL of it happens here — never on the dictation path.
    ///
    /// CRITICAL INVARIANT: this must only be called at audio-idle moments
    /// (warm-up, a settings-toggle change, or a dictionary edit), never during
    /// audio-engine start/stop. Loading a CoreML/ANE model while the audio engine
    /// is spinning up or tearing down races CoreAudio and has crashed the app
    /// before (the same reason the cleanup model isn't warmed on the dictation
    /// path). AppDelegate is the sole caller and keeps to that contract.
    ///
    /// Passing an empty `terms` (boosting off, or an empty dictionary) tears the
    /// biasing state down. Any failure logs and leaves boosting disabled — it must
    /// never surface to the user or block dictation.
    func configureVocabularyBoosting(terms: [DictionaryTerm]) async {
        let boostTerms = Self.buildBoostTerms(from: terms)
        guard !boostTerms.isEmpty else {
            teardownVocabularyBoosting()
            return
        }

        do {
            // The ctc110m model is cached on disk after the first download (~98 MB),
            // arriving via FluidAudio's own DownloadUtils — the app's only permitted
            // network path, identical to how every other model here is fetched.
            let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let ctcModelDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: ctcModelDir)

            let vocabularyTerms: [CustomVocabularyTerm] = boostTerms.compactMap { term in
                let ctcTokenIds = tokenizer.encode(term.text)
                guard !ctcTokenIds.isEmpty else { return nil }
                return CustomVocabularyTerm(
                    text: term.text,
                    aliases: term.aliases.isEmpty ? nil : term.aliases,
                    tokenIds: nil,
                    ctcTokenIds: ctcTokenIds
                )
            }
            guard !vocabularyTerms.isEmpty else {
                teardownVocabularyBoosting()
                return
            }

            let context = CustomVocabularyContext(terms: vocabularyTerms)
            let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: context,
                config: .default,
                ctcModelDirectory: ctcModelDir
            )

            vocabularySpotter = spotter
            vocabularyRescorer = rescorer
            vocabularyContext = context
            Self.logger.info("Vocabulary boosting configured with \(vocabularyTerms.count, privacy: .public) term(s)")
        } catch {
            teardownVocabularyBoosting()
            Self.logger.error("Vocabulary boosting configuration failed, boosting disabled: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func teardownVocabularyBoosting() {
        vocabularySpotter = nil
        vocabularyRescorer = nil
        vocabularyContext = nil
    }

    // MARK: - Transcription

    enum TranscriptionError: LocalizedError {
        case modelNotReady

        var errorDescription: String? {
            switch self {
            case .modelNotReady:
                return "The speech model isn't loaded yet. Check the model status in Yappy's settings."
            }
        }
    }

    /// Transcribes 16 kHz mono Float32 samples with the active model.
    /// Returns "" for clips too short to contain speech.
    func transcribe(_ samples: [Float]) async throws -> String {
        // Below ~0.3 s there is nothing meaningful to transcribe.
        guard samples.count >= 4800 else { return "" }

        switch activeModel {
        case .parakeet:
            return try await transcribeParakeet(samples)
        case .nemotron:
            return try await transcribeNemotron(samples)
        }
    }

    private func transcribeParakeet(_ samples: [Float]) async throws -> String {
        guard let asrManager, modelState == .ready else {
            throw TranscriptionError.modelNotReady
        }

        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asrManager.transcribe(samples, decoderState: &state)
        Self.logger.info("Transcribed \(samples.count, privacy: .public) samples in \(result.processingTime, format: .fixed(precision: 2))s model=parakeet")

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || Self.acceptsTranscript(confidence: result.confidence) else {
            Self.logger.warning(
                "Discarding low-confidence transcript — confidence=\(result.confidence, format: .fixed(precision: 3), privacy: .public)")
            return ""
        }

        // Bias toward the user's dictionary terms, if boosting is configured. This
        // is a best-effort refinement on top of a valid transcript: it runs one
        // extra CTC pass over the recorded buffer and returns the rescored text
        // only when the model actually preferred a dictionary term.
        return await rescoredForVocabulary(text, samples: samples, result: result)
    }

    /// Runs the CTC custom-vocabulary rescoring pass over an already-transcribed
    /// Parakeet result, returning the biased text when the rescorer made a
    /// replacement and `text` otherwise.
    ///
    /// Boosting is a pure accuracy refinement, never a correctness dependency:
    /// ANY failure (or a missing configuration, absent token timings, or empty
    /// log-probs) logs and falls back to the unmodified transcript. Dictation
    /// must never break because of biasing.
    private func rescoredForVocabulary(
        _ text: String, samples: [Float], result: ASRResult
    ) async -> String {
        guard let spotter = vocabularySpotter,
              let rescorer = vocabularyRescorer,
              let vocabulary = vocabularyContext,
              !text.isEmpty else {
            return text
        }

        // The rescorer needs token-level timings to locate each transcript word in
        // the CTC frames. The batch transcribe above populates them; if a future
        // FluidAudio overload doesn't, skip rescoring rather than fail.
        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            Self.logger.info("Vocabulary boosting skipped — no token timings on this transcript")
            return text
        }

        do {
            let spotResult = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: vocabulary,
                minScore: nil
            )
            guard !spotResult.logProbs.isEmpty else {
                Self.logger.info("Vocabulary boosting skipped — spotter produced no log-probs")
                return text
            }

            // Vocabulary-size-aware defaults, mirroring the FluidAudio CLI exactly.
            let vocabConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
            let rescoreOutput = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spotResult.logProbs,
                frameDuration: spotResult.frameDuration,
                cbw: vocabConfig.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: vocabConfig.minSimilarity
            )

            guard rescoreOutput.wasModified else { return text }

            // Plausibility guard: only accept the rescue when every applied
            // replacement is textually close to its term (or an alias) — the
            // signature of a real mishearing. The acoustic match alone can
            // false-positive on genuine words (field case: "error" rewritten to
            // "Terraform"); one implausible replacement rejects the whole rescue
            // and the plain transcript ships instead. Notice-level (persisted)
            // so a rejected rescue is diagnosable in the field — counts only.
            for replacement in rescoreOutput.replacements where replacement.shouldReplace {
                guard let term = replacement.replacementWord else { continue }
                let aliases = vocabulary.terms.first {
                    $0.textLowercased == term.lowercased()
                }?.aliases ?? []
                guard Self.plausibleBoostReplacement(original: replacement.originalWord,
                                                     term: term, aliases: aliases) else {
                    Self.logger.notice("Vocabulary boosting rejected an implausible replacement; keeping the plain transcript")
                    return text
                }
            }

            Self.logger.info("Vocabulary boosting applied \(rescoreOutput.replacements.count, privacy: .public) replacement(s)")
            return rescoreOutput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Self.logger.error("Vocabulary boosting failed, using unbiased transcript: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    /// Batch transcribe via the streaming Nemotron manager, mirroring the
    /// `nemotron-multilingual-transcribe` CLI: feed the buffer in blocks, take the
    /// final text from `finish()`, then reset for the next dictation. The manager
    /// is an actor, so it's always reset even on a thrown error.
    private func transcribeNemotron(_ samples: [Float]) async throws -> String {
        guard let nemotronManager, modelState == .ready else {
            throw TranscriptionError.modelNotReady
        }

        do {
            var offset = 0
            while offset < samples.count {
                let end = min(offset + Self.nemotronFeedBlockSamples, samples.count)
                _ = try await nemotronManager.process(samples: Array(samples[offset..<end]))
                offset = end
            }
            let raw = try await nemotronManager.finish()
            await nemotronManager.reset()
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text
        } catch {
            // Clear partial state so a failed dictation can't poison the next one.
            await nemotronManager.reset()
            throw error
        }
    }

    /// Whether a batch result clears the confidence floor. Low-confidence
    /// output is usually the model decoding noise into filler text.
    nonisolated static func acceptsTranscript(confidence: Float) -> Bool {
        confidence >= Constants.transcriptionConfidenceFloor
    }
}
