//
//  AskRun.swift
//  Yappy
//
//  State model for a single "Ask" run — hold Fn, speak a question, the model
//  answers in the pill using its own web-search / research tools. Adapted from
//  VoiceAgent's VoiceRun, trimmed to the question-answering path: no computer
//  control, so no approval slot and no executing/awaitingApproval states.
//

import Foundation

public enum AskRunStatus: String, Codable, Equatable, Sendable {
    case idle
    /// Fn held while the shared speech model is still loading — pill visible,
    /// recording auto-starts when the model becomes ready.
    case preparing
    case listening
    case transcribing
    /// Turn submitted, waiting on the first token or tool call.
    case thinking
    /// Streaming an answer and/or running research tools (web search, MCP).
    case working
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

public enum AskRunTransitionError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidTransition(from: AskRunStatus, to: AskRunStatus)

    public var description: String {
        switch self {
        case .invalidTransition(let from, let to):
            return "Invalid AskRun transition from \(from.rawValue) to \(to.rawValue)"
        }
    }
}

public enum AskRunStepState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
}

/// What kind of work a step represents — drives the icon in the pill.
public enum AskRunStepKind: String, Codable, Equatable, Sendable {
    case generic
    case thinking
    case search
    case tool
    case command
    case narration
}

public struct AskRunStep: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var state: AskRunStepState
    public var detail: String?
    public var kind: AskRunStepKind
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        state: AskRunStepState = .pending,
        detail: String? = nil,
        kind: AskRunStepKind = .generic,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.kind = kind
        self.createdAt = createdAt
    }
}

public struct AskTurn: Codable, Equatable, Sendable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public struct AskRun: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// The spoken question, verbatim.
    public var rawTranscript: String
    public var status: AskRunStatus
    /// Completed turns in this visible conversation before the active turn.
    public var turns: [AskTurn]
    /// Research activity feed (web searches, tool calls) shown in the pill.
    public var steps: [AskRunStep]
    /// Streamed answer text — accumulated from agentMessage deltas.
    public var answerText: String?
    /// Final answer on success, or an error message on failure.
    public var result: String?
    public var codexThreadID: String?
    public var codexTurnID: String?
    public var grokSessionID: String?
    /// Friendly model name snapshotted at dispatch ("gpt-5.5", "Composer 2.5 Fast", …).
    public var modelLabel: String?
    /// Whether the user invoked "think harder" for this run — preserved on retry.
    public var thinkHarder: Bool = false
    /// Wall-clock latency from dispatch to completion, shown on the pill footer.
    public var latencySeconds: Double?
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        rawTranscript: String,
        status: AskRunStatus = .idle,
        turns: [AskTurn] = [],
        steps: [AskRunStep] = [],
        answerText: String? = nil,
        result: String? = nil,
        codexThreadID: String? = nil,
        codexTurnID: String? = nil,
        grokSessionID: String? = nil,
        modelLabel: String? = nil,
        thinkHarder: Bool = false,
        latencySeconds: Double? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.rawTranscript = rawTranscript
        self.status = status
        self.turns = turns
        self.steps = steps
        self.answerText = answerText
        self.result = result
        self.codexThreadID = codexThreadID
        self.codexTurnID = codexTurnID
        self.grokSessionID = grokSessionID
        self.modelLabel = modelLabel
        self.thinkHarder = thinkHarder
        self.latencySeconds = latencySeconds
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    public mutating func transition(to newStatus: AskRunStatus) throws {
        guard Self.allowedTransitions[status, default: []].contains(newStatus) else {
            throw AskRunTransitionError.invalidTransition(from: status, to: newStatus)
        }
        status = newStatus
        if newStatus.isTerminal {
            completedAt = Date()
        }
    }

    public mutating func appendStep(
        _ title: String,
        state: AskRunStepState = .pending,
        detail: String? = nil,
        kind: AskRunStepKind = .generic
    ) {
        steps.append(AskRunStep(title: title, state: state, detail: detail, kind: kind))
    }

    private static let allowedTransitions: [AskRunStatus: Set<AskRunStatus>] = [
        .idle: [.listening, .preparing, .cancelled],
        .preparing: [.listening, .cancelled, .failed],
        .listening: [.transcribing, .cancelled],
        .transcribing: [.thinking, .failed, .cancelled],
        .thinking: [.working, .completed, .failed, .cancelled, .listening],
        .working: [.completed, .failed, .cancelled, .listening],
        .completed: [.listening],
        .failed: [],
        .cancelled: []
    ]
}
