//
//  AliasMinerTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class AliasMinerTests: XCTestCase {

    func testIsolatedMishearingBecomesCandidate() {
        XCTAssertEqual(AliasMiner.isolatedCandidate(forTerm: "Luis", transcript: "Lewis"), "lewis")
        XCTAssertEqual(AliasMiner.isolatedCandidate(forTerm: "Kubernetes", transcript: "Cooper Netties."), "cooper netties")
    }

    func testIsolatedExactMatchIsNotACandidate() {
        XCTAssertNil(AliasMiner.isolatedCandidate(forTerm: "Luis", transcript: "Luis"))
        XCTAssertNil(AliasMiner.isolatedCandidate(forTerm: "Luis", transcript: "luis."))
    }

    func testIsolatedGarbageRejectedByLengthAndWordCount() {
        // Way too long / too many words to be a mishearing of "Luis".
        XCTAssertNil(AliasMiner.isolatedCandidate(forTerm: "Luis", transcript: "I have no idea what you said"))
    }

    func testSentenceCandidateExtractsMiddle() {
        let c = AliasMiner.sentenceCandidate(
            forTerm: "Kubernetes",
            template: "deploy to {} today",
            transcript: "deploy to cooper netties today"
        )
        XCTAssertEqual(c, "cooper netties")
    }

    func testSentenceCandidateExactMatchIsNil() {
        let c = AliasMiner.sentenceCandidate(
            forTerm: "Kubernetes",
            template: "deploy to {} today",
            transcript: "deploy to kubernetes today"
        )
        XCTAssertNil(c)
    }

    func testMineDedupesAcrossTakes() {
        let candidates = AliasMiner.mineCandidates(
            forTerm: "Luis",
            isolated: ["Lewis", "lewis.", "Louise", "Luis"],
            sentences: [("my name is {}", "my name is lewis")]
        )
        // "lewis" once (dedup + exact-match drop of "Luis"), plus "louise".
        XCTAssertEqual(candidates, ["lewis", "louise"])
    }

    func testEmptyTakeYieldsNoCandidate() {
        XCTAssertNil(AliasMiner.isolatedCandidate(forTerm: "Luis", transcript: "   "))
    }

    // MARK: - Corrections (learn-from-"scratch that")

    func testCorrectionSingleWordSubstitutionWithContext() {
        let pairs = AliasMiner.correctionPairs(
            rejected: "email harkonen about the deploy",
            redictated: "email Harkonnen about the deploy"
        )
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.heard, "harkonen")
        // Casing preserved from re-dictation so high-confidence can see proper nouns.
        XCTAssertEqual(pairs.first?.corrected, "Harkonnen")
    }

    func testCorrectionIdenticalTextsYieldNothing() {
        XCTAssertTrue(AliasMiner.correctionPairs(
            rejected: "deploy to kubernetes today",
            redictated: "deploy to kubernetes today"
        ).isEmpty)
    }

    func testCorrectionUnrelatedSentencesYieldNothing() {
        XCTAssertTrue(AliasMiner.correctionPairs(
            rejected: "the weather is nice today",
            redictated: "please send the quarterly report"
        ).isEmpty)
    }

    func testCorrectionPureInsertionYieldsNothing() {
        // Re-dictation only adds words around a matching core — no substitution.
        XCTAssertTrue(AliasMiner.correctionPairs(
            rejected: "deploy the service",
            redictated: "please deploy the service now"
        ).isEmpty)
    }

    func testCorrectionMultiWordSubstitutionWorks() {
        let pairs = AliasMiner.correctionPairs(
            rejected: "deploy to cooper netties today",
            redictated: "deploy to kubernetes today"
        )
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.heard, "cooper netties")
        XCTAssertEqual(pairs.first?.corrected, "kubernetes")
    }

    func testCorrectionOverLongDiffYieldsNothing() {
        // The middle diff is 4 words on each side — beyond maxWords (3).
        XCTAssertTrue(AliasMiner.correctionPairs(
            rejected: "start one two three four end",
            redictated: "start five six seven eight end"
        ).isEmpty)
    }

    func testCorrectionIsCaseAndPunctuationInsensitiveForContext() {
        // Surrounding context differs only in case/punctuation and still aligns;
        // the substitution is still found. Corrected casing is preserved.
        let pairs = AliasMiner.correctionPairs(
            rejected: "Ping Luis, about it.",
            redictated: "ping Lewis about it"
        )
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.heard, "Luis")
        XCTAssertEqual(pairs.first?.corrected, "Lewis")
    }

    func testCorrectionNormalizedEqualPairYieldsNothing() {
        // "Luis" vs "luis." normalize to the same token — not a real correction.
        XCTAssertTrue(AliasMiner.correctionPairs(
            rejected: "call Luis now",
            redictated: "call luis. now"
        ).isEmpty)
    }

    func testCorrectionImplausibleLengthRatioYieldsNothing() {
        // "hi" vs "internationalization" is far outside the plausible ratio.
        XCTAssertTrue(AliasMiner.correctionPairs(
            rejected: "the hi keyword",
            redictated: "the internationalization keyword"
        ).isEmpty)
    }

    // MARK: - High-confidence auto-learn

    func testHighConfidenceAcceptsKnownTermSingleToken() {
        // Single-token, short edit distance, corrected already in dictionary.
        XCTAssertTrue(AliasMiner.isHighConfidence(
            original: "harkonen",
            corrected: "Harkonnen",
            knownTerms: ["Harkonnen"]
        ))
    }

    func testHighConfidenceAcceptsProperNounShape() {
        // Not in dictionary, but capitalized proper-noun shape + close edit.
        XCTAssertTrue(AliasMiner.isHighConfidence(
            original: "lewis",
            corrected: "Luis",
            knownTerms: []
        ))
    }

    func testHighConfidenceRejectsMultiWord() {
        XCTAssertFalse(AliasMiner.isHighConfidence(
            original: "cooper netties",
            corrected: "Kubernetes",
            knownTerms: ["Kubernetes"]
        ))
    }

    func testHighConfidenceRejectsShortCorrected() {
        // Corrected length < 3.
        XCTAssertFalse(AliasMiner.isHighConfidence(
            original: "ab",
            corrected: "cd",
            knownTerms: ["cd"]
        ))
    }

    func testHighConfidenceRejectsLargeEditDistance() {
        // Completely different tokens — edit ratio well above 40%.
        XCTAssertFalse(AliasMiner.isHighConfidence(
            original: "banana",
            corrected: "Kitchen",
            knownTerms: ["Kitchen"]
        ))
    }

    func testHighConfidenceRejectsAllLowercaseUnknown() {
        // No known term and not proper-noun-shaped (all lowercase).
        XCTAssertFalse(AliasMiner.isHighConfidence(
            original: "harkonen",
            corrected: "harkonnen",
            knownTerms: []
        ))
    }

    func testHighConfidenceBoundaryEditRatio() {
        // "kitten" → "sitting" is too far; "color" → "colour" is close (British).
        // "recieve" → "Receive" (proper noun shape + 2 swaps on 7 chars ≈ 28%).
        XCTAssertTrue(AliasMiner.isHighConfidence(
            original: "recieve",
            corrected: "Receive",
            knownTerms: []
        ))
        // "abcdefgh" → "zyxwvuts" is total rewrite.
        XCTAssertFalse(AliasMiner.isHighConfidence(
            original: "abcdefgh",
            corrected: "Zyxwvuts",
            knownTerms: []
        ))
    }

    func testSentenceInitialCapitalizationIsNotProperNounEvidence() {
        // "Cat sat…" → "Cats sat…": the correction is the FIRST word, so its
        // capital is sentence casing. Must NOT auto-learn (review P1).
        XCTAssertFalse(AliasMiner.isHighConfidence(
            original: "Cat",
            corrected: "Cats",
            knownTerms: [],
            correctedIsSentenceInitial: true
        ))
        // A dictionary-term match still qualifies even sentence-initially.
        XCTAssertTrue(AliasMiner.isHighConfidence(
            original: "Cuberneties",
            corrected: "Kubernetes",
            knownTerms: ["Kubernetes"],
            correctedIsSentenceInitial: true
        ))
    }

    func testHeardTokenThatIsACanonicalTermNeverAutoApplies() {
        // "Lewis" → "Luis" when BOTH are dictionary terms: aliasing would
        // rewrite every legitimate "Lewis" (review P2). Suggestion path only.
        XCTAssertFalse(AliasMiner.isHighConfidence(
            original: "Lewis",
            corrected: "Luis",
            knownTerms: ["Lewis", "Luis"]
        ))
    }

    func testLevenshteinBasics() {
        XCTAssertEqual(AliasMiner.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(AliasMiner.levenshtein("same", "same"), 0)
        XCTAssertEqual(AliasMiner.levenshtein("", "abc"), 3)
    }
}
