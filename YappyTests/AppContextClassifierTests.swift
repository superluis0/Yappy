//
//  AppContextClassifierTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class AppContextClassifierTests: XCTestCase {

    func testKnownCategories() {
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.tinyspeck.slackmacgap"), .workChat)
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.apple.MobileSMS"), .personalChat)
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.apple.dt.Xcode"), .code)
    }

    func testUnknownAndNilFallBackToOther() {
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.unknown.app"), .other)
        XCTAssertEqual(AppContextClassifier.category(forBundleID: nil), .other)
    }

    func testCategoryDefaultTones() {
        XCTAssertEqual(AppCategory.email.defaultTone, .formal)
        XCTAssertEqual(AppCategory.workChat.defaultTone, .formal)
        XCTAssertEqual(AppCategory.personalChat.defaultTone, .casual)
        XCTAssertEqual(AppCategory.code.defaultTone, .verbatim)
        XCTAssertEqual(AppCategory.other.defaultTone, .formal)
    }

    // MARK: - FocusedFieldClassifier (pure role/subrole mapping)

    func testSearchSubroleMapsToSearch() {
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXTextField", subrole: "AXSearchField"), .search)
        // Subrole wins even without a recognized role.
        XCTAssertEqual(FocusedFieldClassifier.kind(role: nil, subrole: "AXSearchField"), .search)
    }

    func testTextAreaMapsToMultiLine() {
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXTextArea", subrole: nil), .multiLine)
    }

    func testTextFieldMapsToSingleLine() {
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXTextField", subrole: nil), .singleLine)
    }

    func testUnknownAndNilRolesMapToUnknown() {
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXStaticText", subrole: nil), .unknown)
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXButton", subrole: "AXSomethingElse"), .unknown)
        XCTAssertEqual(FocusedFieldClassifier.kind(role: nil, subrole: nil), .unknown)
    }

    // MARK: - Single-line collapse (used for single-line / search fields)

    func testCollapseFlattensNewlinesToSingleSpaces() {
        XCTAssertEqual(
            FocusedFieldClassifier.collapseToSingleLine("first line\nsecond line"),
            "first line second line")
    }

    func testCollapseCollapsesRunsOfWhitespace() {
        XCTAssertEqual(
            FocusedFieldClassifier.collapseToSingleLine("hello   world"),
            "hello world")
        XCTAssertEqual(
            FocusedFieldClassifier.collapseToSingleLine("a\n\n\nb\t c"),
            "a b c")
    }

    func testCollapseTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(
            FocusedFieldClassifier.collapseToSingleLine("  \n padded \n "),
            "padded")
    }

    func testCollapseIsIdempotentOnAlreadyCleanText() {
        let clean = "already a single clean line"
        XCTAssertEqual(FocusedFieldClassifier.collapseToSingleLine(clean), clean)
    }
}
