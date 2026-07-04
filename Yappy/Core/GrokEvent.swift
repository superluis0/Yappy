//
//  GrokEvent.swift
//  Yappy
//
// Typed parser for the Grok Build CLI's headless `--output-format
// streaming-json` stream (newline-delimited JSON), written against the REAL
// wire format captured from grok 0.2.82:
//
//   {"type":"thought","data":"<delta>"}   ← thinking stream
//   {"type":"text","data":"<delta>"}      ← answer text stream
//   {"type":"end","stopReason":"EndTurn","sessionId":"…","requestId":"…"}
//
// Anything unrecognized parses as `.ignored` so future event types degrade
// gracefully instead of polluting the answer.

import Foundation

public enum GrokEvent: Equatable, Sendable {
    /// A fragment of the model's thinking stream.
    case thought(delta: String)
    /// A fragment of the answer text.
    case text(delta: String)
    /// The turn finished. `stopReason` is "EndTurn" on success.
    case end(stopReason: String?, sessionId: String?)
    /// A research tool began (stdio `tool_call` / in-progress `tool_call_update`).
    case toolStarted(title: String)
    /// A research tool finished (stdio `tool_call_update` with terminal status).
    case toolCompleted(title: String, failed: Bool)
    /// The CLI reported an error.
    case error(message: String)
    /// Unrecognized event type — safe to drop.
    case ignored(type: String)

    public init?(jsonObject: [String: Any]) {
        guard let type = jsonObject["type"] as? String else { return nil }
        switch type {
        case "thought":
            self = .thought(delta: jsonObject["data"] as? String ?? "")
        case "text":
            self = .text(delta: jsonObject["data"] as? String ?? "")
        case "end":
            self = .end(
                stopReason: jsonObject["stopReason"] as? String,
                sessionId: jsonObject["sessionId"] as? String
            )
        case "error":
            let message = (jsonObject["message"] as? String)
                ?? (jsonObject["data"] as? String)
                ?? ((jsonObject["error"] as? [String: Any])?["message"] as? String)
                ?? "Grok reported an error."
            self = .error(message: message)
        default:
            self = .ignored(type: type)
        }
    }

    /// Parses one NDJSON line. Returns nil for blank/non-JSON lines.
    public static func parse(line: String) -> GrokEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return GrokEvent(jsonObject: object)
    }
}

extension GrokEvent {
    /// Translates one `grok agent stdio` notification frame (already JSON-decoded) into
    /// a GrokEvent, or nil for frames that carry no user-visible signal.
    static func fromSessionUpdate(method: String, params: [String: Any]) -> GrokEvent? {
        if method == "_x.ai/session/update" || method == "_x.ai/session_notification" {
            guard let update = params["update"] as? [String: Any],
                  let sessionUpdate = update["sessionUpdate"] as? String,
                  sessionUpdate == "turn_completed" else {
                return nil
            }
            return .end(
                stopReason: update["stop_reason"] as? String,
                sessionId: params["sessionId"] as? String
            )
        }

        guard method == "session/update",
              let update = params["update"] as? [String: Any],
              let sessionUpdate = update["sessionUpdate"] as? String else {
            return nil
        }

        switch sessionUpdate {
        case "agent_thought_chunk":
            guard let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String else { return nil }
            return .thought(delta: text)
        case "agent_message_chunk":
            guard let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String else { return nil }
            return .text(delta: text)
        case "tool_call":
            return .toolStarted(title: update["title"] as? String ?? "Working")
        case "tool_call_update":
            let title = update["title"] as? String ?? "Working"
            if let status = update["status"] as? String, status == "completed" || status == "failed" {
                return .toolCompleted(title: title, failed: status == "failed")
            }
            return .toolStarted(title: title)
        case "user_message_chunk", "available_commands_update":
            return nil
        default:
            return nil
        }
    }
}
