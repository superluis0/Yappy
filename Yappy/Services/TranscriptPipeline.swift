//
//  TranscriptPipeline.swift
//  Yappy
//

import Foundation

/// Chains the local transcript cleanups in their required order:
/// fillers → numbers → lists → line-break commands → punctuation. Runs on the
/// raw Parakeet output, before user-authored shortcut expansions (which must
/// stay verbatim). Lists run after numbers so the spoken counters already read
/// as digits; punctuation runs last so it can hug the words it lands against.
struct TranscriptPipeline {
    var removeFillers: Bool
    var formatNumbers: Bool
    var formatLists: Bool
    var applyCommands: Bool
    var applyPunctuation: Bool

    func process(_ raw: String) -> String {
        var text = raw
        if removeFillers { text = FillerWordRemover.remove(text) }
        if formatNumbers { text = SpokenNumberFormatter.format(text) }
        if formatLists { text = SpokenListFormatter.format(text) }
        if applyCommands { text = SpokenCommandFormatter.apply(text) }
        if applyPunctuation { text = SpokenPunctuationFormatter.apply(text) }
        return text
    }
}
