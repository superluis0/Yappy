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
    /// `knownTerms` are the user's own vocabulary present in the text (canonical
    /// spelling), passed to the model so it preserves their exact casing.
    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool, intensity: CleanupIntensity, knownTerms: [String]) async -> String

    /// Cleans several dictated lines in a SINGLE call and returns one cleaned string
    /// per input line (same order and count), or `nil` if the result can't be trusted
    /// to map 1:1 back onto the input lines. Lets the coordinator clean a multi-line
    /// dictation in one model round-trip instead of one call per line, falling back to
    /// the per-line path when this returns `nil`. Default: `nil` (no batching).
    func cleanupBatched(lines: [String], tone: ToneStyle, backtrack: Bool, intensity: CleanupIntensity, knownTerms: [String]) async -> [String]?

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
    func cleanupBatched(lines: [String], tone: ToneStyle, backtrack: Bool, intensity: CleanupIntensity, knownTerms: [String]) async -> [String]? { nil }

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
        intensity: CleanupIntensity? = nil,
        knownTerms: [String] = []
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
            text, provider: provider, tone: tone, backtrack: backtrack,
            intensity: resolvedIntensity, knownTerms: knownTerms
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

    /// Names what the polish changed between the raw transcript and the final
    /// text, for the diff caption: "punctuation", "capitalization",
    /// "filler words", "spacing" / "formatting", a two-class combination like
    /// "punctuation and filler words", or "several fixes" when three or more
    /// classes changed. Returns `nil` when the change can't be confidently
    /// named (word rewrites, added words, removed non-filler words) so the
    /// caption falls back to the generic wording rather than over-claiming.
    /// Pure, deterministic, and cheap — token/character comparison only.
    nonisolated static func changeSummary(raw: String, final: String) -> String? {
        let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty, a != b else { return nil }

        let rawParts = TranscriptParts(of: a)
        let finalParts = TranscriptParts(of: b)
        let rawLower = rawParts.words.map { $0.lowercased() }
        let finalLower = finalParts.words.map { $0.lowercased() }

        // Ordered by the caption's priority: capitalization, punctuation,
        // filler words, spacing/formatting.
        var classes: [String] = []

        if rawLower == finalLower {
            // Same words in the same order — the polish touched only casing,
            // punctuation, or whitespace. Each is independently detectable.
            if rawParts.words != finalParts.words {
                classes.append("capitalization")
            }
            if rawParts.punctuation != finalParts.punctuation {
                classes.append("punctuation")
            }
            if rawParts.whitespaceRuns != finalParts.whitespaceRuns {
                classes.append(
                    rawParts.newlineCount != finalParts.newlineCount ? "formatting" : "spacing"
                )
            }
        } else {
            // Word content differs. The only word-level change we can name
            // confidently is the removal of known filler words; anything else
            // (rewrites, additions, removed content words) stays generic.
            guard let match = subsequenceMatch(final: finalLower, within: rawLower),
                  removedWordsAreKnownFillers(match.removed.map { ($0, rawLower[$0]) })
            else { return nil }

            let casingChanged = match.aligned.contains { rawIndex, finalIndex in
                rawParts.words[rawIndex] != finalParts.words[finalIndex]
            }
            if casingChanged {
                classes.append("capitalization")
            }
            if rawParts.punctuation != finalParts.punctuation {
                classes.append("punctuation")
            }
            classes.append("filler words")
            // Whitespace differences here are an artifact of the removal
            // itself, never reported as a separate class.
        }

        switch classes.count {
        case 0: return nil
        case 1, 2: return classes.joined(separator: " and ")
        default: return "several fixes"
        }
    }

    /// One pass over a transcript, split into the three streams `changeSummary`
    /// compares independently: word tokens (runs of letters/digits, case kept),
    /// the punctuation-character sequence, and the whitespace-run sequence.
    private struct TranscriptParts {
        var words: [String] = []
        var punctuation: String = ""
        var whitespaceRuns: [String] = []
        var newlineCount: Int = 0

        init(of text: String) {
            var currentWord = ""
            var currentRun = ""
            for character in text {
                if character.isLetter || character.isNumber {
                    if !currentRun.isEmpty { whitespaceRuns.append(currentRun); currentRun = "" }
                    currentWord.append(character)
                } else {
                    if !currentWord.isEmpty { words.append(currentWord); currentWord = "" }
                    if character.isWhitespace {
                        currentRun.append(character)
                        if character == "\n" || character == "\r" { newlineCount += 1 }
                    } else {
                        if !currentRun.isEmpty { whitespaceRuns.append(currentRun); currentRun = "" }
                        punctuation.append(character)
                    }
                }
            }
            if !currentWord.isEmpty { words.append(currentWord) }
            if !currentRun.isEmpty { whitespaceRuns.append(currentRun) }
        }
    }

    /// Greedy in-order match of `final` as a subsequence of `raw` (both already
    /// lowercased). Returns the aligned index pairs and the raw indices of the
    /// removed words, or `nil` when `final` is not a subsequence (words were
    /// added or rewritten) or nothing was removed.
    private nonisolated static func subsequenceMatch(
        final: [String], within raw: [String]
    ) -> (aligned: [(rawIndex: Int, finalIndex: Int)], removed: [Int])? {
        var aligned: [(rawIndex: Int, finalIndex: Int)] = []
        var removed: [Int] = []
        var finalIndex = 0
        for rawIndex in raw.indices {
            if finalIndex < final.count, raw[rawIndex] == final[finalIndex] {
                aligned.append((rawIndex, finalIndex))
                finalIndex += 1
            } else {
                removed.append(rawIndex)
            }
        }
        guard finalIndex == final.count, !removed.isEmpty else { return nil }
        return (aligned, removed)
    }

    /// Whether every removed word is a known spoken filler — hesitations plus
    /// the discourse fillers the model prunes. Two-word fillers ("you know",
    /// "i mean") only count when both words were removed adjacently, so a lone
    /// removed "you" or "i" is never claimed as filler.
    private nonisolated static func removedWordsAreKnownFillers(
        _ removed: [(index: Int, word: String)]
    ) -> Bool {
        let singles: Set<String> = [
            "um", "uh", "er", "erm", "umm", "uhh", "uhm", "hmm", "ah", "mm", "mhm",
            "like", "well", "so", "actually", "basically", "literally", "anyway",
            "kinda", "sorta",
        ]
        let pairs: [[String]] = [["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"]]
        var i = 0
        while i < removed.count {
            if i + 1 < removed.count,
               removed[i + 1].index == removed[i].index + 1,
               pairs.contains(where: { $0[0] == removed[i].word && $0[1] == removed[i + 1].word }) {
                i += 2
                continue
            }
            guard singles.contains(removed[i].word) else { return false }
            i += 1
        }
        return true
    }

    /// Runs the provider's model cleanup over `text`, preserving its exact "\n"
    /// structure, and returns the cleaned string. No tone transform is applied here —
    /// that is layered on by `cleanup` over the whole final result.
    /// The user's own vocabulary that actually appears in `text`, in canonical
    /// (written) spelling — a preservation hint the model gets so it keeps their
    /// exact casing instead of guessing from generic knowledge ("yappy" → the
    /// product name "Yappy", not the word "happy"; "kubernetes" → "Kubernetes").
    ///
    /// Only terms PRESENT in the text are returned. A transcript with none yields
    /// an empty hint, so the prompt is byte-identical to before — zero token cost
    /// and zero behavior change on text that has no known term. Single-word terms
    /// match a whole token (so "go" does not fire on "golang"); multi-word terms
    /// and aliases match as a substring. Matching an alias still returns the
    /// canonical `text`, which is what the model should preserve.
    nonisolated static func vocabularyHints(
        in text: String, terms: [DictionaryTerm], limit: Int = 24
    ) -> [String] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        let lower = text.lowercased()
        let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        func present(_ raw: String) -> Bool {
            let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard needle.count >= 2 else { return false }
            if needle.contains(where: { $0 == " " }) { return lower.contains(needle) }
            return tokens.contains(needle)
        }

        var hints: [String] = []
        var seen = Set<String>()
        for term in terms {
            let canonical = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = canonical.lowercased()
            guard !canonical.isEmpty, !seen.contains(key) else { continue }
            if present(canonical)
                || term.aliases.contains(where: present)
                || term.learnedAliases.contains(where: present) {
                hints.append(canonical)
                seen.insert(key)
                if hints.count >= limit { break }
            }
        }
        return hints
    }

    private func cleanWithProvider(
        _ text: String,
        provider: CleanupProvider,
        tone: ToneStyle,
        backtrack: Bool,
        intensity: CleanupIntensity,
        knownTerms: [String]
    ) async -> String {
        // Clean each line independently so spoken "new line" / "next line" breaks
        // survive. Given the whole block, the on-device model reflows them — turning a
        // single break into a paragraph break, or dropping a trailing one — even though
        // the prompt says to keep them. We split on "\n" and rejoin on "\n" so the exact
        // structure (blank lines and a trailing break included) is preserved because the
        // model never sees the breaks. Single-line dictations keep the fast one-call path.
        guard text.contains("\n") else {
            return await provider.cleanup(text, tone: tone, backtrack: backtrack, intensity: intensity, knownTerms: knownTerms)
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
                lines: contentLines, tone: tone, backtrack: backtrack, intensity: intensity, knownTerms: knownTerms
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
                    await provider.cleanup(line, tone: tone, backtrack: backtrack, intensity: intensity, knownTerms: knownTerms)
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
