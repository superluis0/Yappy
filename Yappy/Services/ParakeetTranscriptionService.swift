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
