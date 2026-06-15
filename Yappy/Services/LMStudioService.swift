//
//  LMStudioService.swift
//  Yappy
//

import Foundation

/// Optional transcript cleanup via LM Studio's local OpenAI-compatible server.
/// Strictly best-effort: any failure (server not running, timeout, bad response)
/// must result in the raw transcript being used — dictation never breaks.
final class LMStudioService {
    private let settings: Settings
    private let session: URLSession

    init(settings: Settings) {
        self.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.lmStudioTimeout
        configuration.timeoutIntervalForResource = Constants.lmStudioTimeout
        self.session = URLSession(configuration: configuration)
    }

    private var baseURL: URL? {
        URL(string: settings.lmStudioBaseURL)
    }

    // MARK: - Models

    /// Lists model identifiers currently loaded in LM Studio. Returns [] if unreachable.
    func availableModels() async -> [String] {
        guard let url = baseURL?.appendingPathComponent("models") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            return list.data.map(\.id)
        } catch {
            return []
        }
    }

    /// True if the LM Studio server responds.
    func isReachable() async -> Bool {
        guard let url = baseURL?.appendingPathComponent("models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Cleanup

    private static let systemPrompt = """
        You clean up voice dictation transcripts. Fix punctuation, capitalization, \
        and obvious transcription mistakes. Remove filler words (um, uh, you know). \
        Do not change the meaning, do not add content, do not answer questions in the \
        text. Reply with ONLY the cleaned text and nothing else.
        """

    /// Guidance for resolving spoken self-corrections ("backtrack").
    private static let backtrackGuidance = """
        If the speaker corrects themselves mid-thought — with cues like "actually", \
        "I mean", "no wait", "make that", "scratch that", or "sorry" — keep only the \
        corrected version and drop the words they retracted. For example, "let's meet \
        at 2 actually 3" becomes "Let's meet at 3." and "send it to John I mean Jane" \
        becomes "Send it to Jane."
        """

    /// Assembles the cleanup system prompt. Pure and static so the prompt can be
    /// unit-tested without a running LM Studio server.
    static func cleanupPrompt(tone: ToneStyle, backtrack: Bool) -> String {
        var parts = [systemPrompt, tone.promptGuidance]
        if backtrack { parts.append(backtrackGuidance) }
        return parts.joined(separator: "\n")
    }

    /// Returns the cleaned transcript, or the original text on any failure.
    /// `tone` shapes the output to the destination app's context. Verbatim tone
    /// (e.g. code editors) skips the model entirely so nothing gets reworded.
    /// - Parameters:
    ///   - backtrack: when true, the model also resolves spoken self-corrections.
    ///   - cleanupEnabled: overrides the global setting (a mode can force cleanup
    ///     on/off); nil inherits `settings.cleanupEnabled`.
    func cleanup(_ text: String, tone: ToneStyle = .formal, backtrack: Bool = false,
                 cleanupEnabled: Bool? = nil) async -> String {
        guard (cleanupEnabled ?? settings.cleanupEnabled), !text.isEmpty else { return text }
        guard tone != .verbatim else { return text }

        let prompt = Self.cleanupPrompt(tone: tone, backtrack: backtrack)
        let result = await complete(systemPrompt: prompt, userContent: text, temperature: 0.1)
        return result?.isEmpty == false ? result! : text
    }

    private static let commandSystemPrompt = """
        You edit text based on an instruction. Apply the user's instruction to the \
        provided text and reply with ONLY the resulting text — no preamble, no \
        explanation, no quotes around it. If the instruction is a translation or \
        rewrite, return just the transformed text.
        """

    /// Applies a spoken instruction to a selection. Returns nil when the model
    /// is disabled/unreachable or returns nothing, so the caller can abort
    /// without destroying the user's selection.
    func runCommand(instruction: String, selection: String) async -> String? {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty, !selection.isEmpty else { return nil }

        let user = """
            Instruction: \(trimmedInstruction)

            Text:
            \(selection)
            """
        let result = await complete(systemPrompt: Self.commandSystemPrompt, userContent: user, temperature: 0.2)
        guard let result, !result.isEmpty else { return nil }
        return result
    }

    private static let transformSystemPrompt = """
        Apply the following instruction to the user's text and reply with ONLY the \
        resulting text — no preamble, no explanation, no quotes around it.
        """

    /// Applies a saved transform's prompt to some text. Returns nil when the
    /// model is disabled/unreachable or returns nothing, so the caller can leave
    /// the original text untouched.
    func runTransform(prompt: String, text: String) async -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !text.isEmpty else { return nil }

        let user = """
            Instruction: \(trimmedPrompt)

            Text:
            \(text)
            """
        let result = await complete(systemPrompt: Self.transformSystemPrompt, userContent: user, temperature: 0.2)
        guard let result, !result.isEmpty else { return nil }
        return result
    }

    // MARK: - Chat Completion

    /// Resolves the model and performs one chat completion. Returns trimmed
    /// content, or nil on any failure (disabled, unreachable, bad response).
    private func complete(systemPrompt: String, userContent: String, temperature: Double) async -> String? {
        guard let url = baseURL?.appendingPathComponent("chat/completions") else { return nil }

        let model: String
        if let configured = settings.lmStudioModelID, !configured.isEmpty {
            model = configured
        } else if let first = await availableModels().first {
            model = first
        } else {
            return nil
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            let completion = try JSONDecoder().decode(ChatCompletion.self, from: data)
            return completion.choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Response Types

    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct ChatCompletion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }
}
