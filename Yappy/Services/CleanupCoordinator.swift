//
//  CleanupCoordinator.swift
//  Yappy
//

import Foundation

/// A backend that cleans up Yappy's dictation transcripts. Implemented on-device
/// by Apple Foundation Models (macOS 26+). Best-effort: on any failure it returns
/// the input unchanged so dictation never breaks.
protocol CleanupProvider: AnyObject {
    /// Short label for the Settings UI (e.g. "Apple Intelligence").
    var displayName: String { get }

    /// Whether the provider can serve a request right now (model loaded / reachable).
    func isAvailable() async -> Bool

    /// Cleans a dictation transcript. The caller has already decided cleanup should
    /// run (enabled, non-verbatim tone). Returns the original text on any failure.
    /// `intensity` selects the instruction variant (standard vs conservative).
    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool, intensity: CleanupIntensity) async -> String

    /// Cleans several dictated lines in a SINGLE call and returns one cleaned string
    /// per input line (same order and count), or `nil` if the result can't be trusted
    /// to map 1:1 back onto the input lines. Lets the coordinator clean a multi-line
    /// dictation in one model round-trip instead of one call per line, falling back to
    /// the per-line path when this returns `nil`. Default: `nil` (no batching).
    func cleanupBatched(lines: [String], tone: ToneStyle, backtrack: Bool, intensity: CleanupIntensity) async -> [String]?

    /// Asks the provider to load its model into memory ahead of use, so the first
    /// real request doesn't pay a cold-start. Best-effort and idempotent.
    func prewarm() async

    /// Pre-creates/warms the exact session the next cleanup will use, so its setup
    /// (system-prompt prefill) overlaps transcription instead of delaying the cleanup
    /// that follows. Best-effort; default no-op.
    func prepareSession() async
}

extension CleanupProvider {
    /// Default: no batching — the coordinator falls back to the per-line path.
    func cleanupBatched(lines: [String], tone: ToneStyle, backtrack: Bool, intensity: CleanupIntensity) async -> [String]? { nil }

    /// Default: nothing to warm up.
    func prewarm() async {}

    /// Default: nothing to pre-create.
    func prepareSession() async {}
}

/// Routes the app's transcript-cleanup calls to the on-device AI provider (Apple
/// Intelligence). When no provider is available (older macOS or AI disabled),
/// cleanup degrades to a no-op so dictation never breaks.
@MainActor
final class CleanupCoordinator {
    private let settings: Settings
    /// The on-device AI provider (Apple Intelligence). `nil` when none is wired,
    /// in which case cleanup degrades to returning its input unchanged.
    private let provider: CleanupProvider?

    init(settings: Settings, provider: CleanupProvider? = nil) {
        self.settings = settings
        self.provider = provider
    }

    // MARK: - Public API

    /// Cleans a transcript with the on-device provider, applying the same
    /// enable/tone gates the provider would apply internally. Returns the input
    /// unchanged when cleanup is off, the tone is verbatim, or no provider exists.
    /// Intensity comes from `settings.cleanupIntensity` unless overridden.
    func cleanup(
        _ text: String,
        tone: ToneStyle,
        backtrack: Bool,
        cleanupEnabled: Bool?,
        intensity: CleanupIntensity? = nil
    ) async -> String {
        guard (cleanupEnabled ?? settings.cleanupEnabled), !text.isEmpty else { return text }
        guard tone != .verbatim else { return text }

        // Tiny, structurally simple utterances have nothing useful for the model
        // to repair. Keep every deterministic transform, including tone shaping,
        // while skipping only the dominant provider round-trip. Sentence-case
        // deterministically first — the model's one real contribution on these
        // inputs is capitalization + a terminal period (eval cases short-01/02,
        // num-03), and skipping must not regress the rubric's gold outputs.
        if Self.shouldSkipModelCleanup(text: text, tone: tone, backtrack: backtrack) {
            return tone.apply(to: Self.sentenceCased(text))
        }
        guard let provider else { return text }

        let resolvedIntensity = intensity ?? settings.cleanupIntensity
        let cleaned = await cleanWithProvider(
            text, provider: provider, tone: tone, backtrack: backtrack, intensity: resolvedIntensity
        )

        // Apply the DETERMINISTIC tone transform to the final cleaned string. The
        // model's cleanup instructions stay register-neutral (prompt-level tone hints
        // broke intent-safety on-device); tone is enforced here by pure text rules
        // instead. The transform self-guards: `casualize` only touches short single-line
        // sentences (a multi-line block passes through), `formalize` expands whitelisted
        // contractions throughout and ensures terminal punctuation. `.verbatim` already
        // returned above, so this only runs for `.formal`/`.casual`.
        return tone.apply(to: cleaned)
    }

    /// Deterministic stand-in for what the model does to trivial utterances:
    /// capitalize the first letter and close with a period. Existing terminal
    /// punctuation (!, ?, …) is respected; interior text is never touched.
    nonisolated static func sentenceCased(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let first = trimmed.first, first.isLowercase {
            trimmed = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
        if let last = trimmed.last, !".!?…".contains(last) {
            trimmed += "."
        }
        return trimmed
    }

    /// Conservative fast-path gate for trivial utterances. A self-correction is
    /// considered only when backtracking is enabled, matching the provider's own
    /// routing; list-shaped and question-shaped text always keeps model cleanup.
    nonisolated static func shouldSkipModelCleanup(
        text: String, tone: ToneStyle, backtrack: Bool
    ) -> Bool {
        guard tone != .verbatim else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("?") else { return false }
        guard !trimmed.contains("\n") && !trimmed.contains("\r") else { return false }
        guard trimmed.split(whereSeparator: { $0.isWhitespace }).count <= 3 else { return false }
        if backtrack {
            let lower = trimmed.lowercased()
            let hasDeleteSignal = lower == "delete that" || lower.hasPrefix("delete that ")
            if hasDeleteSignal || FoundationModelsCleanupProvider.hasCorrectionSignal(trimmed) {
                return false
            }
        }

        // Markers at the start of any line: bullets, dashes, or common ordered
        // list forms ("1." / "1)"). Avoid treating an ordinary interior hyphen
        // as list structure.
        for line in trimmed.components(separatedBy: .newlines) {
            let start = line.trimmingCharacters(in: .whitespaces)
            if start.hasPrefix("- ") || start.hasPrefix("* ") || start.hasPrefix("• ") {
                return false
            }
            if let markerEnd = start.firstIndex(where: { !$0.isNumber }),
               markerEnd != start.startIndex,
               start[markerEnd] == "." || start[markerEnd] == ")" {
                let after = start.index(after: markerEnd)
                if after == start.endIndex || start[after].isWhitespace { return false }
            }
        }
        return true
    }

    /// Whether a post-insert "Polished — click to use your exact words" caption
    /// should show. Pure / unit-tested.
    ///
    /// - Cleanup must have actually run (not skipped / not verbatim tone / not
    ///   secure-input bypass).
    /// - After trim, raw and final must differ. Punctuation-only and casing-only
    ///   changes still count (simple inequality) — the caption is honest about
    ///   any polish the model applied.
    static func shouldShowDiffCaption(
        raw: String,
        final: String,
        cleanupRan: Bool,
        captionEnabled: Bool
    ) -> Bool {
        guard captionEnabled, cleanupRan else { return false }
        let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = final.trimmingCharacters(in: .whitespacesAndNewlines)
        return a != b
    }

    /// Runs the provider's model cleanup over `text`, preserving its exact "\n"
    /// structure, and returns the cleaned string. No tone transform is applied here —
    /// that is layered on by `cleanup` over the whole final result.
    private func cleanWithProvider(
        _ text: String,
        provider: CleanupProvider,
        tone: ToneStyle,
        backtrack: Bool,
        intensity: CleanupIntensity
    ) async -> String {
        // Clean each line independently so spoken "new line" / "next line" breaks
        // survive. Given the whole block, the on-device model reflows them — turning a
        // single break into a paragraph break, or dropping a trailing one — even though
        // the prompt says to keep them. We split on "\n" and rejoin on "\n" so the exact
        // structure (blank lines and a trailing break included) is preserved because the
        // model never sees the breaks. Single-line dictations keep the fast one-call path.
        guard text.contains("\n") else {
            return await provider.cleanup(text, tone: tone, backtrack: backtrack, intensity: intensity)
        }

        let rawLines = text.components(separatedBy: "\n")
        // Indices of the lines we actually clean (blank lines are passed through as-is).
        let contentIndices = rawLines.indices.filter {
            !rawLines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }

        // Fast path: clean every content line in ONE model call. The provider returns
        // cleaned lines only if it can trust them to map 1:1 back (same count, no
        // reflow/merge/drop); otherwise nil, and we fall through to the per-line loop.
        // This preserves the exact "\n" structure either way — we only ever substitute
        // content lines back into their original slots.
        if contentIndices.count >= 2 {
            let contentLines = contentIndices.map { rawLines[$0] }
            if let batched = await provider.cleanupBatched(
                lines: contentLines, tone: tone, backtrack: backtrack, intensity: intensity
            ), batched.count == contentIndices.count {
                var merged = rawLines
                for (slot, cleaned) in zip(contentIndices, batched) {
                    merged[slot] = cleaned
                }
                return merged.joined(separator: "\n")
            }
        }

        // Fallback: one call per non-blank line (correctness-preserving safety net).
        var cleanedLines: [String] = []
        for line in rawLines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                cleanedLines.append(line)
            } else {
                cleanedLines.append(
                    await provider.cleanup(line, tone: tone, backtrack: backtrack, intensity: intensity)
                )
            }
        }
        return cleanedLines.joined(separator: "\n")
    }

    /// Warms up the on-device model so the first cleanup doesn't pay the
    /// multi-second cold start of loading it into memory. Fire-and-forget and
    /// cheap once warm. No-op when cleanup is off or no provider exists.
    ///
    /// Call this at the start of each dictation: the model loads in the background
    /// while the user speaks, so it's hot by the time the transcript is ready.
    func prewarm() {
        guard settings.cleanupEnabled, let provider else { return }
        // Fire-and-forget on the provider's own executor (off the main thread).
        // No isAvailable() gate: that check is itself costly (it decodes the model
        // manifest), and prewarm() is a cheap no-op when the model can't load.
        // IMPORTANT: only call this when no dictation is recording — warming the
        // model loads it on a background thread, and doing so while the audio
        // engine is being torn down races CoreAudio and crashes. Callers warm only
        // at audio-idle moments (enabling cleanup; after a cleanup completes).
        Task { [provider] in
            await provider.prewarm()
        }
    }

    /// Pre-creates and warms the session the next cleanup will use, so its setup runs
    /// while the transcript is still being produced and the cleanup itself starts
    /// generating sooner. Fire-and-forget. No-op when cleanup is off or no provider
    /// exists.
    ///
    /// Call at the start of transcription. Like `prewarm`, this loads model resources
    /// on a background thread, so it must only run at an audio-idle moment — by the
    /// time transcription begins the audio engine has already stopped.
    func prepareSession() {
        guard settings.cleanupEnabled, let provider else { return }
        Task { [provider] in
            await provider.prepareSession()
        }
    }
}
