//
//  ModeStoreTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class ModeStoreTests: XCTestCase {

    var fileURL: URL!
    var store: ModeStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-modes-tests-\(UUID().uuidString).json")
        store = ModeStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        store = nil
        super.tearDown()
    }

    func testSeedsWithAutoMode() {
        XCTAssertEqual(store.modes.count, 1)
        XCTAssertTrue(store.modes[0].isAuto)
        XCTAssertEqual(store.modes[0].id, Mode.autoID)
    }

    func testAddUpdateDelete() {
        var mode = Mode(name: "Code", tone: .verbatim)
        store.add(mode)
        XCTAssertEqual(store.modes.count, 2)

        mode.name = "Coding"
        store.update(mode)
        XCTAssertEqual(store.modes.last?.name, "Coding")

        store.delete(mode)
        XCTAssertEqual(store.modes.count, 1)
        XCTAssertTrue(store.modes[0].isAuto)
    }

    func testCannotAddOrDeleteAuto() {
        store.add(.auto)
        XCTAssertEqual(store.modes.count, 1)
        store.delete(store.modes[0]) // the Auto mode
        XCTAssertEqual(store.modes.count, 1)
        XCTAssertTrue(store.modes[0].isAuto)
    }

    func testPersistsAcrossInstances() {
        store.add(Mode(name: "Email", tone: .formal, autoTriggerCategory: .email))

        let deadline = Date().addingTimeInterval(2)
        var reloaded = ModeStore(fileURL: fileURL)
        while reloaded.modes.count < 2, Date() < deadline {
            usleep(50_000)
            reloaded = ModeStore(fileURL: fileURL)
        }
        XCTAssertEqual(reloaded.modes.count, 2)
        XCTAssertEqual(reloaded.modes.last?.name, "Email")
        XCTAssertTrue(reloaded.modes.contains { $0.isAuto })
    }

    func testEnsuresAutoWhenFileLacksIt() throws {
        // A modes.json that somehow has no Auto mode should get one re-inserted.
        let custom = [Mode(name: "Only", tone: .casual)]
        try JSONEncoder().encode(custom).write(to: fileURL, options: .atomic)

        let reloaded = ModeStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.modes.contains { $0.isAuto })
    }

    // MARK: - Resolution

    func testExplicitCustomModeWins() {
        let code = Mode(name: "Code", autoTriggerCategory: .code)
        let modes: [Mode] = [.auto, code]
        let resolved = ModeResolver.resolve(activeID: code.id, in: modes, forCategory: .email)
        XCTAssertEqual(resolved.id, code.id)
    }

    func testAutoFallsBackToAutoTriggerMatch() {
        let email = Mode(name: "Email", autoTriggerCategory: .email)
        let modes: [Mode] = [.auto, email]
        let resolved = ModeResolver.resolve(activeID: Mode.autoID, in: modes, forCategory: .email)
        XCTAssertEqual(resolved.id, email.id)
    }

    func testAutoWithNoMatchReturnsAuto() {
        let email = Mode(name: "Email", autoTriggerCategory: .email)
        let modes: [Mode] = [.auto, email]
        let resolved = ModeResolver.resolve(activeID: Mode.autoID, in: modes, forCategory: .code)
        XCTAssertTrue(resolved.isAuto)
    }

    func testNilActiveReturnsAuto() {
        let resolved = ModeResolver.resolve(activeID: nil, in: [.auto], forCategory: .other)
        XCTAssertTrue(resolved.isAuto)
    }

    // MARK: - Adaptive (learned per-app) resolution

    func testLearnedModeAppliesWhenOnAuto() {
        let code = Mode(name: "Code", autoTriggerCategory: .code)
        let email = Mode(name: "Email")
        let modes: [Mode] = [.auto, code, email]
        let resolved = ModeResolver.resolve(
            activeID: nil, learnedModeID: email.id, in: modes, forCategory: .code)
        XCTAssertEqual(resolved.id, email.id, "On Auto, a learned per-app mode should apply")
    }

    func testExplicitSelectionBeatsLearnedMode() {
        let code = Mode(name: "Code")
        let email = Mode(name: "Email")
        let modes: [Mode] = [.auto, code, email]
        let resolved = ModeResolver.resolve(
            activeID: code.id, learnedModeID: email.id, in: modes, forCategory: .other)
        XCTAssertEqual(resolved.id, code.id, "An explicit global selection outranks a learned mode")
    }

    func testLearnedModeBeatsCategoryAutoTrigger() {
        let emailAuto = Mode(name: "EmailAuto", autoTriggerCategory: .email)
        let casual = Mode(name: "Casual")
        let modes: [Mode] = [.auto, emailAuto, casual]
        let resolved = ModeResolver.resolve(
            activeID: nil, learnedModeID: casual.id, in: modes, forCategory: .email)
        XCTAssertEqual(resolved.id, casual.id, "Learned mode outranks a category auto-trigger")
    }

    func testNilLearnedFallsBackToCategory() {
        let email = Mode(name: "Email", autoTriggerCategory: .email)
        let modes: [Mode] = [.auto, email]
        let resolved = ModeResolver.resolve(
            activeID: nil, learnedModeID: nil, in: modes, forCategory: .email)
        XCTAssertEqual(resolved.id, email.id)
    }
}
