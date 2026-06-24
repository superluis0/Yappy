//
//  FoundationModelsCleanupProvider.swift
//  Yappy
//

import Foundation

// FoundationModels ships in the macOS 26 SDK and is weak-linked because the app's
// deployment target is macOS 14. Every use is gated with @available / #available,
// so its symbols are only touched on macOS 26+ where the framework is present.
import FoundationModels

// MARK: - FoundationModelsCleanupProvider

/// `CleanupProvider` backed by Apple's on-device Foundation Models framework
/// (Apple Intelligence). This provider requires macOS 26+ and the user to have
/// Apple Intelligence enabled; `isAvailable()` gates every caller so the
/// coordinator can fall back to other backends transparently.
///
/// All generation methods are best-effort: every error path returns the input
/// unchanged (or nil for optional transforms) so a model hiccup never breaks
/// live dictation.
///
/// Thread-safety note: `LanguageModelSession` allows only one in-flight
/// `respond(to:)` at a time per instance. Yappy's dictation pipeline is
/// sequential (one cleanup call at a time), so a single session per call site
/// is safe. Each method creates a fresh session to avoid cross-call state
/// accumulation in the conversation history.
final class FoundationModelsCleanupProvider: CleanupProvider {

    // MARK: - CleanupProvider

    var displayName: String { "Apple Intelligence" }

    /// Returns `true` only when the on-device model is fully downloaded and
    /// Apple Intelligence is enabled by the user in System Settings.
    func isAvailable() async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    /// Cleans a voice-dictation transcript using the on-device model.
    ///
    /// The system instructions cover the full cleanup contract:
    /// - Fix punctuation, capitalisation, and obvious transcription errors
    /// - Strip filler words (um, uh, you know)
    /// - Never alter meaning or add content
    /// - Always use American (US) English spelling
    /// - Preserve lists, line breaks, and digit formatting
    /// - Shape output to the requested `tone`
    ///
    /// When `backtrack` is true an extra instruction teaches the model to
    /// resolve spoken self-corrections ("scratch that", "I mean", etc.) by
    /// keeping only the corrected version.
    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool) async -> String {
        guard !text.isEmpty else { return text }
        guard #available(macOS 26.0, *) else { return text }

        let instructions = Self.cleanupInstructions(backtrack: backtrack)
        guard let cleaned = await generate(instructions: instructions, userMessage: text) else { return text }
        // Safety net: the small on-device model can occasionally run away and
        // invent content. Cleanup output should be roughly input-length, so reject
        // a result that's wildly longer and fall back to the original text.
        return cleaned.count <= text.count * 4 + 120 ? cleaned : text
    }

    /// Applies a spoken Command-Mode instruction to a selected text range.
    /// Returns `nil` on any failure so the caller can abort without clobbering
    /// the user's selection.
    func runCommand(instruction: String, selection: String) async -> String? {
        guard !instruction.isEmpty, !selection.isEmpty else { return nil }
        guard #available(macOS 26.0, *) else { return nil }

        let instructions = """
            You edit text based on an instruction. Apply the user's instruction \
            to the provided text and reply with ONLY the resulting text — no \
            preamble, no explanation, no quotes.
            """
        let userMessage = """
            Instruction: \(instruction)

            Text:
            \(selection)
            """
        return await generate(instructions: instructions, userMessage: userMessage)
    }

    /// Applies a saved Transform's prompt to an arbitrary block of text.
    /// The `prompt` string IS the system instruction; the text is the user turn.
    /// Returns `nil` on any failure so the caller can leave the original text
    /// untouched.
    func runTransform(prompt: String, text: String) async -> String? {
        guard !prompt.isEmpty, !text.isEmpty else { return nil }
        guard #available(macOS 26.0, *) else { return nil }

        // The transform author's prompt is the system instruction; the text is the
        // user turn, so the model treats it as input rather than part of its own
        // directive.
        return await generate(instructions: prompt, userMessage: text)
    }

    // MARK: - Private helpers

    /// Core generation helper. Creates a single-use session with the given
    /// system-level instructions, sends `userMessage`, and returns the trimmed
    /// response string. Returns `nil` on any error (guardrail violation, model
    /// not ready, context overflow, etc.).
    ///
    /// A new session per call is intentional: we don't want earlier conversation
    /// turns leaking into unrelated cleanup or transform calls.
    @available(macOS 26.0, *)
    private func generate(instructions: String, userMessage: String) async -> String? {
        do {
            // Guardrails live on the model, not the session (verified against the
            // macOS 26 SDK). Permissive content-transformation guardrails avoid
            // spurious refusals when faithfully rewriting dictated text.
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: instructions)

            // Greedy sampling + a response cap keep the small on-device model from
            // running away — default random sampling turned a one-word input into a
            // 100-line hallucination that leaked these instructions into the output.
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 2000)
            let response = try await session.respond(to: userMessage, options: options)

            let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            // Best-effort: log in debug builds; callers handle nil / original text.
#if DEBUG
            print("[FoundationModelsCleanupProvider] generation error: \(error)")
#endif
            return nil
        }
    }

    // MARK: - Prompt assembly

    /// Builds the cleanup system instructions. Deliberately terse and emphatic
    /// about NOT adding content: Apple's small on-device model otherwise
    /// "completes" a short input into invented sentences. Tone-restyling is left to
    /// the LM Studio backend (pushing this model toward a tone made it expand), and
    /// the one-shot example anchors "a tiny input stays tiny".
    static func cleanupInstructions(backtrack: Bool) -> String {
        backtrack ? baseCleanupInstructions + "\n" + backtrackInstructions
                  : baseCleanupInstructions
    }

    private static let baseCleanupInstructions = """
        You are a transcription cleaner. Fix only capitalization, punctuation, and \
        obvious transcription errors in the dictated text, and remove filler words \
        (um, uh, you know). Never add, expand, continue, rephrase, translate, \
        summarize, answer, or invent content — if the text is already correct, \
        return it unchanged. Keep numbered lists, line breaks, and digits as they \
        are. Use American (US) English spelling. Output only the corrected text — \
        no preamble, no quotes, no commentary.

        Example — input: "testing" → output: "Testing."
        """

    /// Appended when backtrack-correction is enabled. Best-effort on the small
    /// on-device model — it handles clear cases but can mishandle very terse ones.
    private static let backtrackInstructions = """
        If the speaker corrects themselves ("actually", "I mean", "no wait", \
        "make that", "scratch that"), keep only the corrected version and drop the \
        retracted words.
        """
}
