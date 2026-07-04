//
//  AskHotkeyStateMachine.swift
//  Yappy
//
//  Pure hold-to-talk state machine for the Fn/Globe "Ask" key. Kept separate
//  from Yappy's HotkeyStateMachine (which multiplexes hold/double-tap dictation
//  modes) — this one is a simple debounced hold, driven by a dedicated Fn tap.
//  Ported from VoiceAgent; renamed to avoid the HotkeyStateMachine collision.
//

import Foundation

public enum AskHotkeyEvent: Equatable, Sendable {
    case down
    case up
}

public enum AskHotkeyAction: Equatable, Sendable {
    case none
    case start
    case stop
    case cancel
}

public struct AskHotkeyStateMachine: Sendable {
    private var active = false
    private var lastDownAt: TimeInterval?
    private var lastUpAt: TimeInterval?
    private let debounceInterval: TimeInterval

    public init(debounceInterval: TimeInterval = 0.1) {
        self.debounceInterval = debounceInterval
    }

    public mutating func handle(_ event: AskHotkeyEvent, at time: TimeInterval) -> AskHotkeyAction {
        switch event {
        case .down:
            if active { return .none }
            if let lastUpAt, time - lastUpAt < debounceInterval { return .none }
            active = true
            lastDownAt = time
            return .start
        case .up:
            guard active else { return .none }
            if let lastDownAt, time - lastDownAt < 0 {
                return .none
            }
            active = false
            lastUpAt = time
            return .stop
        }
    }

    public mutating func deactivate() -> AskHotkeyAction {
        guard active else { return .none }
        active = false
        return .cancel
    }
}
