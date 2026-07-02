//
//  AliasMiner.swift
//  Yappy
//

import Foundation

/// Extracts likely "sounds like" spellings for a dictionary term from how the
/// speech model *actually* transcribed the user saying it (with boosting OFF).
/// Conservative on purpose: these aliases feed the recognition rescorer, so junk
/// candidates would cause false corrections. Pure and unit-tested.
enum AliasMiner {

    /// At most this many words — a name mishearing is short.
    private static let maxWords = 3

    /// Mines deduplicated candidates from a set of takes. `isolated` are takes
    /// where the user said the term alone; `sentences` pair a template (with the
    /// placeholder "{}" where the term belongs) with what the model heard.
    static func mineCandidates(
        forTerm term: String,
        isolated: [String] = [],
        sentences: [(template: String, transcript: String)] = []
    ) -> [String] {
        var result: [String] = []
        var seen: Set<String> = [normalize(term)]

        func consider(_ raw: String?) {
            guard let candidate = raw else { return }
            let key = candidate.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(candidate)
        }

        for take in isolated { consider(isolatedCandidate(forTerm: term, transcript: take)) }
        for s in sentences { consider(sentenceCandidate(forTerm: term, template: s.template, transcript: s.transcript)) }
        return result
    }

    /// The whole transcript of an isolated take, if it plausibly differs from
    /// the term (short, length within a sane ratio).
    static func isolatedCandidate(forTerm term: String, transcript: String) -> String? {
        let candidate = normalize(transcript)
        let canonical = normalize(term)
        guard !candidate.isEmpty, candidate != canonical else { return nil }
        guard wordCount(candidate) <= maxWords else { return nil }
        guard plausibleLength(candidate, vs: canonical) else { return nil }
        return candidate
    }

    /// The token run that landed where the term was expected, by stripping the
    /// template's matching prefix/suffix words from the transcript.
    static func sentenceCandidate(forTerm term: String, template: String, transcript: String) -> String? {
        let parts = template.lowercased().components(separatedBy: "{}")
        guard parts.count == 2 else { return nil }

        let prefix = words(parts[0])
        let suffix = words(parts[1])
        var heard = words(transcript)

        // Strip the matching leading words, then the matching trailing words.
        for p in prefix {
            guard heard.first == p else { break }
            heard.removeFirst()
        }
        for s in suffix.reversed() {
            guard heard.last == s else { break }
            heard.removeLast()
        }

        let candidate = heard.joined(separator: " ")
        let canonical = normalize(term)
        guard !candidate.isEmpty, candidate != canonical else { return nil }
        guard wordCount(candidate) <= maxWords else { return nil }
        guard plausibleLength(candidate, vs: canonical) else { return nil }
        return candidate
    }

    // MARK: - Corrections (learn-from-"scratch that")

    /// Diffs a rejected dictation against the phrase the user immediately
    /// re-dictated and, when the two differ only in a tight middle run of words,
    /// returns that (heard → corrected) substitution as a candidate alias pair.
    ///
    /// The signal: after "scratch that" the user re-says nearly the same phrase,
    /// so the model *heard* one thing and the user *meant* another. We keep this
    /// as conservative as the rest of the miner — a wrong alias feeds the
    /// dictionary and would degrade accuracy — so we only accept a substitution
    /// bracketed by matching context and reject anything that looks like an
    /// unrelated re-dictation.
    ///
    /// Approach: tokenize both, strip the longest common prefix and suffix, and
    /// take the middle remainders as (heard, corrected). We require:
    /// - both remainders non-empty (a pure insertion/deletion isn't a
    ///   spelling correction) and each ≤ `maxWords`,
    /// - at least 2 words of shared context (prefix + suffix) so re-dictating
    ///   something unrelated yields nothing,
    /// - the two normalized runs actually differ, and their lengths are
    ///   plausibly related (reuses `plausibleLength`).
    ///
    /// Returns at most one pair (the single middle diff) — deliberately narrow.
    static func correctionPairs(rejected: String, redictated: String) -> [(heard: String, corrected: String)] {
        let heardWords = words(rejected)
        let correctedWords = words(redictated)
        guard !heardWords.isEmpty, !correctedWords.isEmpty else { return [] }
        // Identical utterances carry no correction.
        guard heardWords != correctedWords else { return [] }

        // Strip the longest common prefix.
        var prefixLength = 0
        let maxPrefix = min(heardWords.count, correctedWords.count)
        while prefixLength < maxPrefix, heardWords[prefixLength] == correctedWords[prefixLength] {
            prefixLength += 1
        }

        // Strip the longest common suffix, without overlapping the prefix.
        var suffixLength = 0
        let maxSuffix = min(heardWords.count, correctedWords.count) - prefixLength
        while suffixLength < maxSuffix,
              heardWords[heardWords.count - 1 - suffixLength] == correctedWords[correctedWords.count - 1 - suffixLength] {
            suffixLength += 1
        }

        // Require real shared context on both sides combined — an unrelated
        // re-dictation shares little or nothing.
        guard prefixLength + suffixLength >= 2 else { return [] }

        let heardRun = Array(heardWords[prefixLength ..< (heardWords.count - suffixLength)])
        let correctedRun = Array(correctedWords[prefixLength ..< (correctedWords.count - suffixLength)])

        // Both sides must be a tight substitution: non-empty (not a pure
        // insertion/deletion) and short (a name mishearing, not a new clause).
        guard !heardRun.isEmpty, !correctedRun.isEmpty,
              heardRun.count <= maxWords, correctedRun.count <= maxWords else {
            return []
        }

        let heard = heardRun.joined(separator: " ")
        let corrected = correctedRun.joined(separator: " ")
        // The runs must genuinely differ once normalized (so "Luis" vs "luis."
        // isn't mined) and be plausibly the same word length.
        guard normalize(heard) != normalize(corrected),
              plausibleLength(heard, vs: corrected) else {
            return []
        }
        return [(heard: heard, corrected: corrected)]
    }

    // MARK: - Helpers

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func wordCount(_ text: String) -> Int { words(text).count }

    /// The candidate's length must be in [0.5×, 2×] the term's, so wildly
    /// different garbage ("the weather today") is rejected.
    private static func plausibleLength(_ candidate: String, vs canonical: String) -> Bool {
        let c = candidate.replacingOccurrences(of: " ", with: "").count
        let t = canonical.replacingOccurrences(of: " ", with: "").count
        guard t > 0 else { return false }
        return c * 2 >= t && c <= t * 2 + 2
    }
}
