//
//  ParakeetTranscriptionService.swift
//  Yappy
//

import Foundation
import FluidAudio
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

    private static let logger = Logger(subsystem: "com.yappy.app", category: "transcription")

    // Parakeet (TDT) backing state.
    private var asrManager: AsrManager?
    private var decoderLayers: Int = 2

    /// English-only Parakeet — same model variant Spokenly uses.
    private static let modelVersion: AsrModelVersion = .v2

    // Nemotron (multilingual) backing state.
    private var nemotronManager: StreamingNemotronMultilingualAsrManager?

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
    func warmUp() async {
        guard modelState == .notLoaded || isFailed else { return }

        switch activeModel {
        case .parakeet:
            await warmUpParakeet()
        case .nemotron:
            await warmUpNemotron()
        }
    }

    /// Loads the Parakeet models and pre-warms the ANE.
    private func warmUpParakeet() async {
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
        return text
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
