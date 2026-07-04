//
//  CodexEvent.swift
//  Yappy
//
// Typed parser for codex app-server notifications, written against the REAL
// wire format captured from codex-cli 0.142.x. The critical shapes:
//
//   item/started / item/completed
//     params.item.type ∈ { userMessage, agentMessage, reasoning, webSearch,
//                          mcpToolCall, commandExecution, … }
//     • agentMessage: { id: "msg_…", text, phase: "final_answer" | preamble… }
//     • reasoning:    { id: "rs_…",  summary: [...], content: [...] }
//     • webSearch:    { id: "ws_…",  query, action: { type, query, queries } }
//
//   item/agentMessage/delta
//     params: { itemId, delta }        ← the ONLY streaming answer text
//
//   turn/started, turn/completed      ← params.turn.{id,status,error}
//
// This parser is exhaustive about what each event MEANS and never falls back to
// identifiers (rs_…, ws_…, msg_…) — that scraping was the old parser's bug.

import Foundation

/// One semantic event from the Codex app-server stream.
public enum CodexEvent: Equatable, Sendable {
    case turnStarted
    /// `failureMessage` is non-nil when the turn ended in failure.
    case turnCompleted(failureMessage: String?)

    /// An assistant message item opened. `phase` distinguishes the final
    /// answer ("final_answer") from working narration (preamble/plan chatter).
    case agentMessageStarted(itemID: String, phase: String?)
    /// Streaming text for an assistant message item.
    case agentMessageDelta(itemID: String?, delta: String)
    /// Authoritative full text for a completed assistant message item.
    case agentMessageCompleted(itemID: String?, phase: String?, text: String)

    case reasoningStarted
    /// `summary` is the model's own thinking summary when provided (often empty).
    case reasoningCompleted(summary: String?)

    case webSearchStarted
    case webSearchCompleted(query: String?)

    case toolCallStarted(name: String?)
    case toolCallProgress(text: String?)
    case toolCallCompleted(name: String?, failed: Bool)

    case commandStarted(command: String?)
    case commandCompleted(command: String?, failed: Bool)

    case serverError(message: String)

    /// Bookkeeping traffic we deliberately ignore (token usage, rate limits,
    /// MCP startup status, thread status, warnings, user-message echoes, …).
    case ignored(method: String)
}

/// A parsed notification: thread/turn routing plus the semantic event.
public struct CodexEventEnvelope: Equatable, Sendable {
    public let threadID: String?
    public let turnID: String?
    public let event: CodexEvent

    public init(threadID: String?, turnID: String?, event: CodexEvent) {
        self.threadID = threadID
        self.turnID = turnID
        self.event = event
    }

    public init?(jsonObject: [String: Any]) {
        // A root-level JSON-RPC error object with no id (server-fatal notice).
        if jsonObject["method"] == nil {
            guard let error = jsonObject["error"] as? [String: Any] else { return nil }
            self.init(
                threadID: nil,
                turnID: nil,
                event: .serverError(message: error["message"] as? String ?? "Codex reported an error.")
            )
            return
        }

        guard let method = jsonObject["method"] as? String else { return nil }
        let params = jsonObject["params"] as? [String: Any] ?? [:]
        let turn = params["turn"] as? [String: Any]
        let item = params["item"] as? [String: Any]
        let itemType = item?["type"] as? String

        let threadID = params["threadId"] as? String
        let turnID = (params["turnId"] as? String) ?? (turn?["id"] as? String)

        let event: CodexEvent
        switch method {
        case "turn/started":
            event = .turnStarted

        case "turn/completed", "turn/failed":
            let status = turn?["status"] as? String
            let errorMessage = Self.errorMessage(turn?["error"]) ?? Self.errorMessage(params["error"])
            if let errorMessage {
                event = .turnCompleted(failureMessage: errorMessage)
            } else if status == "failed" || method == "turn/failed" {
                event = .turnCompleted(failureMessage: "The agent run failed.")
            } else {
                event = .turnCompleted(failureMessage: nil)
            }

        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String, !delta.isEmpty else {
                event = .ignored(method: method)
                break
            }
            event = .agentMessageDelta(itemID: params["itemId"] as? String, delta: delta)

        case "item/started", "item/updated", "item/completed":
            event = Self.itemEvent(method: method, itemType: itemType, item: item)

        case "item/mcpToolCall/progress":
            let text = (params["message"] as? String)
                ?? (params["progress"] as? String)
                ?? (params["text"] as? String)
            event = .toolCallProgress(text: text)

        case "error":
            event = .serverError(
                message: (params["message"] as? String)
                    ?? Self.errorMessage(params["error"])
                    ?? "Codex reported an error."
            )

        default:
            event = .ignored(method: method)
        }

        self.init(threadID: threadID, turnID: turnID, event: event)
    }

    // MARK: - Item mapping

    private static func itemEvent(method: String, itemType: String?, item: [String: Any]?) -> CodexEvent {
        let started = method == "item/started"
        let completed = method == "item/completed"

        switch itemType {
        case "agentMessage":
            let id = item?["id"] as? String
            let phase = item?["phase"] as? String
            if started {
                return .agentMessageStarted(itemID: id ?? "", phase: phase)
            }
            if completed {
                return .agentMessageCompleted(itemID: id, phase: phase, text: item?["text"] as? String ?? "")
            }
            return .ignored(method: method)

        case "reasoning":
            if started { return .reasoningStarted }
            if completed { return .reasoningCompleted(summary: reasoningSummary(item)) }
            return .ignored(method: method)

        case "webSearch":
            if started { return .webSearchStarted }
            if completed { return .webSearchCompleted(query: searchQuery(item)) }
            return .ignored(method: method)

        case "mcpToolCall":
            let name = toolName(item)
            if started { return .toolCallStarted(name: name) }
            if completed {
                let status = (item?["status"] as? String)?.lowercased()
                let failed = status == "failed" || status == "error"
                return .toolCallCompleted(name: name, failed: failed)
            }
            return .ignored(method: method)

        case "commandExecution":
            let command = commandText(item)
            if started { return .commandStarted(command: command) }
            if completed {
                let exitCode = item?["exitCode"] as? Int
                return .commandCompleted(command: command, failed: (exitCode ?? 0) != 0)
            }
            return .ignored(method: method)

        default:
            // userMessage echoes, fileChange, todoList, … — nothing to render.
            return .ignored(method: method)
        }
    }

    // MARK: - Field extraction (never falls back to IDs)

    private static func reasoningSummary(_ item: [String: Any]?) -> String? {
        guard let summary = item?["summary"] else { return nil }
        var parts: [String] = []
        if let strings = summary as? [String] {
            parts = strings
        } else if let objects = summary as? [[String: Any]] {
            parts = objects.compactMap { $0["text"] as? String }
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func searchQuery(_ item: [String: Any]?) -> String? {
        if let query = item?["query"] as? String, !query.isEmpty { return query }
        if let action = item?["action"] as? [String: Any],
           let query = action["query"] as? String, !query.isEmpty {
            return query
        }
        return nil
    }

    private static func toolName(_ item: [String: Any]?) -> String? {
        for key in ["tool", "toolName", "name"] {
            if let name = item?[key] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    private static func commandText(_ item: [String: Any]?) -> String? {
        if let command = item?["command"] as? String, !command.isEmpty { return command }
        if let parts = item?["command"] as? [String], !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return nil
    }

    private static func errorMessage(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let object = value as? [String: Any] {
            return object["message"] as? String
        }
        return nil
    }
}
