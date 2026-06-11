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
}
