//
//  DictionaryReplacerTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class DictionaryReplacerTests: XCTestCase {

    private func replacer(_ terms: [DictionaryTerm]) -> DictionaryReplacer {
        DictionaryReplacer(terms: terms)
    }

    func testCorrectsKnownMishearing() {
        let r = replacer([DictionaryTerm(text: "Luis", aliases: ["Lewis", "Louise"])])
        XCTAssertEqual(r.apply("Hey Lewis, are you free?"), "Hey Luis, are you free?")
    }

    func testBuiltInDevTermsMapToCanonical() {
        let r = replacer(BuiltInDictionary.terms)
        XCTAssertEqual(r.apply("deploy to super base"), "deploy to Supabase")
        XCTAssertEqual(r.apply("scaffold a next js app"), "scaffold a Next.js app")
        XCTAssertEqual(r.apply("spin up a versel project"), "spin up a Vercel project")
    }

    func testCaseInsensitiveButCanonicalCasingOut() {
        let r = replacer([DictionaryTerm(text: "Luis", aliases: ["Lewis"])])
        XCTAssertEqual(r.apply("lewis and LEWIS"), "Luis and Luis")
    }

    func testWholeWordOnly() {
        let r = replacer([DictionaryTerm(text: "Luis", aliases: ["Lewis"])])
        // "Lewisham" must not become "Luisham".
        XCTAssertEqual(r.apply("I live in Lewisham"), "I live in Lewisham")
    }

    func testMultiWordAlias() {
        let r = replacer([DictionaryTerm(text: "Kubernetes", learnedAliases: ["cooper netties"])])
        XCTAssertEqual(r.apply("deploy to cooper netties today"), "deploy to Kubernetes today")
    }

    func testUsesLearnedAndManualAliases() {
        let r = replacer([DictionaryTerm(text: "Luis", aliases: ["Louise"], learnedAliases: ["Lewis"])])
        XCTAssertEqual(r.apply("Louise and Lewis"), "Luis and Luis")
    }

    func testNoTermsIsIdentity() {
        XCTAssertEqual(replacer([]).apply("nothing to change"), "nothing to change")
    }

    func testTermWithNoAliasesIsIdentity() {
        let r = replacer([DictionaryTerm(text: "Micro1")])
        XCTAssertEqual(r.apply("the micro1 build"), "the micro1 build")
    }
}
