//
//  AskBackendClient.swift
//  Yappy
//
//  Injectable seams for Ask backends. Protocols mirror the existing client
//  surfaces so AskController can substitute fakes in unit tests without
//  normalizing the two event streams.
//

import Foundation

protocol CodexAsking: AnyObject {
    var onNotification: (@Sendable (CodexEventEnvelope) -> Void)? { get set }
    func prewarm() async
    func ask(transcript: String, continuingThread: String?, effort: String) async throws -> CodexRunStart
    func interrupt(threadID: String, turnID: String)
    func stop()
}

struct GrokAskRequest: Equatable, Sendable {
    var prompt: String
    var model: String
    var effort: String = "low"          // "low" | "high"
    var systemPrompt: String? = nil     // → --system-prompt-override when non-nil
    var resumeSessionID: String? = nil  // reserved for a later stage; unused today
}

protocol GrokAsking: AnyObject {
    var onEvent: (@Sendable (GrokEvent) -> Void)? { get set }
    func prewarm() async
    func ask(_ request: GrokAskRequest) async throws
    func cancel()
    func stop()
}

extension GrokAsking {
    func prewarm() async {}
    func stop() { cancel() }
}

extension CodexAskClient: CodexAsking {}
extension GrokAskClient: GrokAsking {}
extension GrokAgentClient: GrokAsking {}

/// Routes Grok asks through the warm agent client, falling back to the
/// one-shot CLI when the warm process can't serve the request.
final class GrokClientRouter: GrokAsking {
    private let warm: any GrokAsking
    private let oneShot: any GrokAsking

    var onEvent: (@Sendable (GrokEvent) -> Void)? {
        didSet {
            let handler = onEvent
            warm.onEvent = handler
            oneShot.onEvent = handler
        }
    }

    init(warm: any GrokAsking, oneShot: any GrokAsking) {
        self.warm = warm
        self.oneShot = oneShot
    }

    func prewarm() async {
        await warm.prewarm()
    }

    func ask(_ request: GrokAskRequest) async throws {
        do {
            try await warm.ask(request)
        } catch {
            VLog.grok("router fallback → one-shot (\(type(of: error)))")
            try await oneShot.ask(request)
        }
    }

    func cancel() {
        warm.cancel()
        oneShot.cancel()
    }

    func stop() {
        warm.stop()
        oneShot.stop()
    }
}