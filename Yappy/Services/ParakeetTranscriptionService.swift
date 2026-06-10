//
//  ParakeetTranscriptionService.swift
//  Yappy
//

import AVFoundation
import Foundation
import FluidAudio
import os

/// Local speech-to-text via the Parakeet TDT model (FluidAudio, CoreML, Apple Neural Engine).
/// The model is downloaded once (~443 MB) to ~/Library/Application Support/FluidAudio/Models
/// and loaded at app start so transcription on hotkey release is immediate.
@MainActor
final class ParakeetTranscriptionService: ObservableObject {
    enum ModelState: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case failed(String)

        var statusDescription: String {
            switch self {
            case .notLoaded: return "Model not loaded"
            case .downloading(let progress): return "Downloading model… \(Int(progress * 100))%"
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

    /// Whether the custom-dictionary CTC model is downloading (~97 MB, first use).
    @Published private(set) var dictionaryDownloading = false

    private static let logger = Logger(subsystem: "com.yappy.app", category: "transcription")
    private var asrManager: AsrManager?
    private var loadedModels: AsrModels?
    private var decoderLayers: Int = 2

    // Streaming / dictionary path (isolated from the batch path).
    private var slidingManager: SlidingWindowAsrManager?
    private var streamingUpdateTask: Task<Void, Never>?
    private var bufferFeedTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var ctcModels: CtcModels?

    /// English-only Parakeet — same model variant Spokenly uses.
    private static let modelVersion: AsrModelVersion = .v2

    // MARK: - Lifecycle

    /// Loads (downloading first if necessary) the Parakeet models and pre-warms the ANE.
    /// Safe to call again after a failure.
    func warmUp() async {
        guard modelState == .notLoaded || isFailed else { return }

        let cacheDir = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
        let cached = AsrModels.modelsExist(at: cacheDir, version: Self.modelVersion)
        modelState = cached ? .loading : .downloading(progress: 0)

        do {
            let models = try await AsrModels.downloadAndLoad(
                version: Self.modelVersion,
                progressHandler: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.modelState else { return }
                        self.modelState = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )

            modelState = .loading
            decoderLayers = models.version.decoderLayers
            loadedModels = models

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
            modelState = .failed(error.localizedDescription)
        }
    }

    private var isFailed: Bool {
        if case .failed = modelState { return true }
        return false
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

    /// Transcribes 16 kHz mono Float32 samples. Returns "" for clips too short to contain speech.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asrManager, modelState == .ready else {
            throw TranscriptionError.modelNotReady
        }

        // Below ~0.3 s there is nothing meaningful to transcribe.
        guard samples.count >= 4800 else { return "" }

        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asrManager.transcribe(samples, decoderState: &state)
        Self.logger.info("Transcribed \(samples.count) samples in \(result.processingTime, format: .fixed(precision: 2))s")

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || Self.acceptsTranscript(confidence: result.confidence) else {
            Self.logger.warning(
                "Discarding low-confidence transcript (\(result.confidence, format: .fixed(precision: 2))): \(text.count) chars")
            return ""
        }
        return text
    }

    /// Whether a batch result clears the confidence floor. Low-confidence
    /// output is usually the model decoding noise into filler text.
    nonisolated static func acceptsTranscript(confidence: Float) -> Bool {
        confidence >= Constants.transcriptionConfidenceFloor
    }

    // MARK: - Streaming + Custom Dictionary

    /// Starts a live streaming session on a fresh sliding-window manager (so any
    /// previous vocabulary boosting is cleared). Custom-dictionary terms, when
    /// provided, download/attach the CTC model. Returns false if unavailable;
    /// partial transcripts are delivered via `onPartial`.
    func startStreamingSession(
        dictionaryTerms: [String],
        onPartial: @escaping (String) -> Void
    ) async -> Bool {
        guard modelState == .ready, let models = loadedModels else { return false }

        // `.streaming` emits ~1 s hypothesis updates for a live caption; the
        // default config only produces output after 15 s of audio.
        let manager = SlidingWindowAsrManager(config: .streaming)
        do {
            try await manager.loadModels(models)

            if !dictionaryTerms.isEmpty, let ctc = await ensureCtcModels() {
                let context = CustomVocabularyContext(
                    terms: dictionaryTerms.map { CustomVocabularyTerm(text: $0) }
                )
                try await manager.configureVocabularyBoosting(vocabulary: context, ctcModels: ctc)
            }

            try await manager.startStreaming(source: .microphone)
            Self.logger.info("Streaming session started (\(dictionaryTerms.count) dictionary terms)")
        } catch {
            Self.logger.error("Streaming start failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        slidingManager = manager

        // Feed buffers through an owned stream so order is preserved across the
        // hop into the manager actor.
        let (bufferStream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        bufferContinuation = continuation
        bufferFeedTask = Task {
            for await buffer in bufferStream {
                await manager.streamAudio(buffer)
            }
        }

        streamingUpdateTask = Task {
            var confirmed = ""
            var loggedFirst = false
            let updates = await manager.transcriptionUpdates
            for await update in updates {
                if !loggedFirst {
                    loggedFirst = true
                    Self.logger.info("First streaming partial: \(update.text.count) chars")
                }
                if update.isConfirmed {
                    confirmed += (confirmed.isEmpty ? "" : " ") + update.text
                    let snapshot = confirmed
                    await MainActor.run { onPartial(snapshot) }
                } else {
                    let display = confirmed.isEmpty ? update.text : confirmed + " " + update.text
                    await MainActor.run { onPartial(display) }
                }
                if Task.isCancelled { break }
            }
        }
        return true
    }

    /// Pre-downloads the CTC dictionary model so the first dictionary-boosted
    /// dictation doesn't stall. Safe to call repeatedly.
    func prewarmDictionary() async {
        _ = await ensureCtcModels()
    }

    func streamBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferContinuation?.yield(buffer)
    }

    /// Ends the session and returns the final transcript.
    func finishStreamingSession() async -> String {
        guard let manager = slidingManager else { return "" }
        defer { teardownStreaming() }
        do {
            return try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Self.logger.error("Streaming finish failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    func cancelStreamingSession() async {
        if let manager = slidingManager {
            await manager.cancel()
        }
        teardownStreaming()
    }

    private func teardownStreaming() {
        bufferContinuation?.finish()
        bufferContinuation = nil
        bufferFeedTask?.cancel()
        bufferFeedTask = nil
        streamingUpdateTask?.cancel()
        streamingUpdateTask = nil
        slidingManager = nil
    }

    /// Lazily downloads (~97 MB, first use) and loads the CTC model used for
    /// vocabulary boosting. Returns nil on failure.
    private func ensureCtcModels() async -> CtcModels? {
        if let ctcModels { return ctcModels }
        dictionaryDownloading = true
        defer { dictionaryDownloading = false }
        do {
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            ctcModels = models
            return models
        } catch {
            Self.logger.error("CTC model load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
