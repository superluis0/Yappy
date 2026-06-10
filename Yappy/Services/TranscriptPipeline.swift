//
//  TranscriptPipeline.swift
//  Yappy
//

import Foundation

/// Chains the local transcript cleanups in their required order:
/// fillers → numbers → formatting commands. Runs on the raw Parakeet output,
/// before user-authored shortcut expansions (which must stay verbatim).
struct TranscriptPipeline {
    var removeFillers: Bool
    var formatNumbers: Bool
    var applyCommands: Bool

    func process(_ raw: String) -> String {
        var text = raw
        if removeFillers { text = FillerWordRemover.remove(text) }
        if formatNumbers { text = SpokenNumberFormatter.format(text) }
        if applyCommands { text = SpokenCommandFormatter.apply(text) }
        return text
    }
}
