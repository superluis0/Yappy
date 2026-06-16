//
//  VoiceControlCommandParserTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class VoiceControlCommandParserTests: XCTestCase {

    private let email = Mode(name: "Email")
    private let code = Mode(name: "Code")
    private var modes: [Mode] { [Mode.auto, email, code] }

    private func parse(_ s: String) -> VoiceControlCommand? {
        VoiceControlCommandParser.parse(s, modes: modes)
    }

    func testSwitchToModeWithPrefix() {
        XCTAssertEqual(parse("switch to email mode"), .switchToMode(id: email.id))
    }

    func testModeWithoutPrefix() {
        XCTAssertEqual(parse("code mode"), .switchToMode(id: code.id))
    }

    func testAutoMode() {
        XCTAssertEqual(parse("auto mode"), .selectAutoMode)
        XCTAssertEqual(parse("switch to auto mode"), .selectAutoMode)
    }

    func testOpenScratchpad() {
        XCTAssertEqual(parse("open scratchpad"), .openScratchpad)
        XCTAssertEqual(parse("show notes"), .openScratchpad)
    }

    func testNewNote() {
        XCTAssertEqual(parse("new note"), .newNote)
    }

    func testFillerTolerated() {
        XCTAssertEqual(parse("um, open scratchpad"), .openScratchpad)
    }

    func testUnknownModeIsNil() {
        XCTAssertNil(parse("switch to wizard mode"))
    }

    func testProseIsNil() {
        XCTAssertNil(parse("let's switch to a different tab"))
        XCTAssertNil(parse("open the scratchpad and start writing"))
        XCTAssertNil(parse("I sent the email this morning"))
    }
}
