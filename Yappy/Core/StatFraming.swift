//
//  StatFraming.swift
//  Yappy
//

import Foundation

/// Tasteful, human-scale framings of raw stats. Returns nil below a threshold so
/// the UI never shows a forced or trivial comparison. Restrained on purpose —
/// these read as quiet context, not gimmicks.
enum StatFraming {

    private struct Tier { let floor: Int; let phrase: String }

    private static let wordTiers: [Tier] = [
        Tier(floor: 1_000,   phrase: "about a short story's worth"),
        Tier(floor: 5_000,   phrase: "a long article's worth"),
        Tier(floor: 15_000,  phrase: "a novella's worth"),
        Tier(floor: 40_000,  phrase: "a short novel's worth"),
        Tier(floor: 100_000, phrase: "a full novel's worth"),
    ]

    private static let timeTiers: [Tier] = [
        Tier(floor: 15,  phrase: "about a coffee break"),
        Tier(floor: 60,  phrase: "an hour of your day back"),
        Tier(floor: 240, phrase: "half a workday saved"),
        Tier(floor: 480, phrase: "a full workday saved"),
        Tier(floor: 2_400, phrase: "a full workweek saved"),
    ]

    /// e.g. "a novella's worth", or nil under ~1,000 words.
    static func wordsMilestone(_ words: Int) -> String? {
        highestPhrase(for: words, in: wordTiers)
    }

    /// e.g. "half a workday saved", or nil under ~15 minutes.
    static func timeSavedRelatable(minutes: Int) -> String? {
        highestPhrase(for: minutes, in: timeTiers)
    }

    private static func highestPhrase(for value: Int, in tiers: [Tier]) -> String? {
        tiers.last { value >= $0.floor }?.phrase
    }
}
