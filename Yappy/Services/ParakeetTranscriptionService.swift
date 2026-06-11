//
//  ParakeetTranscriptionService.swift
//  Yappy
//

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

    private static let logger = Logger(subsystem: "com.yappy.app", category: "transcription")
    private var asrManager: AsrManager?
    private var decoderLayers: Int = 2

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
}
