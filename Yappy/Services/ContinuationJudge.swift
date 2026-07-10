//
//  ContinuationJudge.swift
//  Yappy
//

import Foundation

// FoundationModels ships in the macOS 26 SDK. Wrapped in #if canImport so the file
// still compiles on older SDKs (e.g. CI on an older Xcode), where the stub below
// always abstains. Mirrors FoundationModelsCleanupProvider's gating exactly.
#if canImport(FoundationModels)
import FoundationModels

/// A one-word on-device judgment for resumed dictations: when the previous
/// insertion ended with a period and a new dictation arrives at the same caret,
/// decides whether the new text CONTINUES that sentence (the user released the
/// hotkey mid-thought) or genuinely starts a new one.
///
/// This covers the case no deterministic rule can: "I have a call with Cigna
/// tomorrow." + "7:30 A.M." — "tomorrow" can legitimately end a sentence, so
/// only seeing BOTH fragments can tell. The deterministic layers still run
/// first (function-word repair, lowercase-start join); this judge only breaks
/// the genuinely ambiguous ties.
///
/// Best-effort by design: every failure path returns nil (abstain), so the
/// caller falls back to today's deterministic behavior. Runs concurrently with
/// the cleanup call (both post-audio-teardown, so the no-ML-during-audio
/// invariant holds) and the caller enforces a hard timeout.
actor ContinuationJudge {

    /// The guardrails model, created once and reused (building it can decode the
    /// on-device model manifest — wasteful to repeat). Typed `Any?` because
    /// `SystemLanguageModel` is macOS 26+ only and can't be a stored property's
    /// type on this macOS-14-available actor.
    private var cachedModel: Any?

    @available(macOS 26.0, *)
    private func sharedModel() -> SystemLanguageModel {
        if let model = cachedModel as? SystemLanguageModel { return model }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        cachedModel = model
        return model
    }

    /// true = the new text continues the previous sentence (join them),
    /// false = it starts a new sentence, nil = unavailable/undecidable —
    /// the caller keeps today's deterministic behavior.
    func shouldJoin(previousTail: String, newText: String) async -> Bool? {
        guard #available(macOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.availability == .available else { return nil }

        // ~15 words a side is plenty of context for a boundary call; hard-capped
        // so a long dictation never inflates the prompt.
        let tail = String(previousTail.suffix(120))
        let head = String(newText.prefix(120))
        do {
            // A fresh session per call — the judge must never inherit earlier
            // conversation state. Greedy sampling + a tiny response cap keep the
            // small model pinned to the one-word contract.
            let session = LanguageModelSession(model: sharedModel(), instructions: Self.instructions)
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 6)
            let response = try await session.respond(to: Self.userMessage(tail: tail, head: head),
                                                     options: options)
            let verdict = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if verdict.hasPrefix("JOIN") { return true }
            if verdict.hasPrefix("NEW") { return false }
            return nil
        } catch {
            // Guardrail refusal, model not ready, context overflow — abstain.
            return nil
        }
    }

    /// Judges speaker INTENT over messy speech, not grammar — a speaker who
    /// releases the hotkey mid-thought produces fragments that often don't join
    /// grammatically but were one utterance ("There is no" + "I can't stop").
    /// Still biased toward NEW when uncertain: wrongly keeping two sentences
    /// apart is today's (tolerable) behavior, wrongly merging them is a new error.
    private static let instructions = """
        You judge spoken dictation. The speaker dictated some words, paused \
        (maybe mid-breath), then dictated more. Decide whether the pause \
        interrupted a SINGLE ongoing thought, or the speaker started a separate \
        new message. Judge the speaker's intent, not strict grammar — speech is \
        fragmentary and messy. Reply with exactly one word: JOIN if the new \
        words continue the same thought, NEW if they start a separate message. \
        When uncertain, reply NEW.

        Examples:
        previous: "I have a call with Cigna tomorrow." new: "7:30 A.M." → JOIN
        previous: "There is no" new: "I can't stop" → JOIN
        previous: "We should meet at." new: "The coffee shop on Main." → JOIN
        previous: "I think we should" new: "maybe go tomorrow" → JOIN
        previous: "Send the report to Ann." new: "Thanks for your patience." → NEW
        previous: "That works for me." new: "Nope, actually scratch that." → NEW
        previous: "Sounds good." new: "See you then." → NEW
        """

    /// The fragments are wrapped in ⟦⟧ markers like the cleanup prompts, so the
    /// model treats them as quoted material to judge — never text to answer.
    private static func userMessage(tail: String, head: String) -> String {
        """
        previous: ⟦\(tail)⟧
        new: ⟦\(head)⟧
        Same continued thought, or a separate new message? Reply JOIN or NEW.
        """
    }
}

#else

/// Fallback for SDKs without FoundationModels (e.g. CI on an older Xcode).
/// Always abstains, so callers keep the deterministic behavior.
actor ContinuationJudge {
    func shouldJoin(previousTail: String, newText: String) async -> Bool? { nil }
}

#endif
