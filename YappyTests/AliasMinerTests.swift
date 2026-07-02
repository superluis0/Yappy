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
        XCTAssertEqual(pairs.first?.corrected, "harkonnen")
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
        // the substitution is still found.
        let pairs = AliasMiner.correctionPairs(
            rejected: "Ping Luis, about it.",
            redictated: "ping Lewis about it"
        )
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.heard, "luis")
        XCTAssertEqual(pairs.first?.corrected, "lewis")
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
}
