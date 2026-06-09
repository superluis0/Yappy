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
}
