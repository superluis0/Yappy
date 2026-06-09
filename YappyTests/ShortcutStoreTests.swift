//
//  ShortcutStoreTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class ShortcutStoreTests: XCTestCase {

    var fileURL: URL!
    var store: ShortcutStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-shortcuts-tests-\(UUID().uuidString).json")
        store = ShortcutStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        store = nil
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.shortcuts.isEmpty)
    }

    func testAddUpdateDelete() {
        let shortcut = VoiceShortcut(trigger: "ty", expansion: "thank you")
        store.add(shortcut)
        XCTAssertEqual(store.shortcuts.count, 1)

        var updated = shortcut
        updated.expansion = "thanks!"
        store.update(updated)
        XCTAssertEqual(store.shortcuts.first?.expansion, "thanks!")

        store.delete(shortcut)
        XCTAssertTrue(store.shortcuts.isEmpty)
    }

    func testPersistsAcrossInstances() {
        store.add(VoiceShortcut(trigger: "sig", expansion: "Best,\nLuis"))

        let deadline = Date().addingTimeInterval(2)
        var reloaded = ShortcutStore(fileURL: fileURL)
        while reloaded.shortcuts.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = ShortcutStore(fileURL: fileURL)
        }
        XCTAssertEqual(reloaded.shortcuts.first?.trigger, "sig")
    }
}
