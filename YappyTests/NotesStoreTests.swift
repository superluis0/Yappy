//
//  NotesStoreTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class NotesStoreTests: XCTestCase {

    var fileURL: URL!
    var store: NotesStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappy-notes-\(UUID().uuidString).json")
        store = NotesStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        store = nil
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testCreateInsertsAtTop() {
        let first = store.create()
        let second = store.create()
        XCTAssertEqual(store.notes.count, 2)
        XCTAssertEqual(store.notes.first?.id, second.id)
        XCTAssertEqual(store.notes.last?.id, first.id)
    }

    func testUpdateBody() {
        let note = store.create()
        store.update(note, body: "Buy milk")
        XCTAssertEqual(store.notes.first?.body, "Buy milk")
    }

    func testDelete() {
        let note = store.create()
        store.delete(note)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testDisplayTitleDerivesFromFirstNonEmptyLine() {
        XCTAssertEqual(Note(body: "").displayTitle, "New note")
        XCTAssertEqual(Note(body: "\n\nHello there\nmore").displayTitle, "Hello there")
        XCTAssertEqual(Note(body: "Groceries").displayTitle, "Groceries")
    }

    func testRoundTripsThroughDisk() {
        let note = store.create()
        store.update(note, body: "Persisted note")

        let deadline = Date().addingTimeInterval(2)
        var reloaded = NotesStore(fileURL: fileURL)
        while reloaded.notes.isEmpty, Date() < deadline {
            usleep(50_000)
            reloaded = NotesStore(fileURL: fileURL)
        }
        XCTAssertEqual(reloaded.notes.first?.body, "Persisted note")
    }
}
