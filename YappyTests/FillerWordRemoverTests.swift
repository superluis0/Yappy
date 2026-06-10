//
//  FillerWordRemoverTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class FillerWordRemoverTests: XCTestCase {

    private func f(_ s: String) -> String { FillerWordRemover.remove(s) }

    func testLeadingFillerRecapitalizes() {
        XCTAssertEqual(f("Um, so I think"), "So I think")
    }

    func testParentheticalFillerCollapses() {
        XCTAssertEqual(f("I was, um, thinking"), "I was thinking")
    }

    func testPureFillerBecomesEmpty() {
        XCTAssertEqual(f("Hmm."), "")
    }

    func testConsecutiveLeadingFillers() {
        XCTAssertEqual(f("Um, uh, so yeah"), "So yeah")
    }

    func testEllipsisAfterLeadingFiller() {
        XCTAssertEqual(f("Erm... maybe"), "Maybe")
    }

    func testUhHuhIsPreserved() {
        XCTAssertEqual(f("Uh-huh, sounds good"), "Uh-huh, sounds good")
    }

    func testDiscourseWordsUntouched() {
        XCTAssertEqual(f("It's like, you know, fine"), "It's like, you know, fine")
    }

    func testEmbeddedLettersAreSafe() {
        XCTAssertEqual(f("summer umbrella"), "summer umbrella")
    }

    func testTrailingFillerKeepsPeriod() {
        XCTAssertEqual(f("Sounds good, um."), "Sounds good.")
    }

    func testFillerAfterSentenceEndRecapitalizes() {
        XCTAssertEqual(f("Done. Um, next item"), "Done. Next item")
    }

    func testFillerCarryingSentenceEndKeepsBoundary() {
        XCTAssertEqual(f("I agree, um. Next item"), "I agree. Next item")
    }

    func testPlainSpacesAroundFiller() {
        XCTAssertEqual(f("so um yeah"), "so yeah")
    }

    func testNoFillerIsIdentity() {
        XCTAssertEqual(f("Nothing to remove here."), "Nothing to remove here.")
    }
}
