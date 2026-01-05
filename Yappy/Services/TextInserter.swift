//
//  TextInserter.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation
import AppKit
import ApplicationServices

/// Errors that can occur during text insertion.
enum TextInsertionError: LocalizedError {
    case clipboardAccessFailed
    case pasteSimulationFailed
    case textEncodingFailed

    var errorDescription: String? {
        switch self {
        case .clipboardAccessFailed:
            return "Failed to access the system clipboard."
        case .pasteSimulationFailed:
            return "Failed to simulate paste keystroke."
        case .textEncodingFailed:
            return "Failed to encode text for clipboard."
        }
    }
}

/// Manages system-wide text insertion via clipboard manipulation and paste simulation.
/// Preserves the original clipboard contents and restores them after insertion.
final class TextInserter {
    // MARK: - Private Properties

    /// Delay in seconds to wait after pasting before restoring clipboard.
    private let clipboardRestoreDelay: TimeInterval = 0.1

    /// Delay in microseconds between key down and key up events.
    private let keyEventDelay: UInt32 = 10_000 // 10ms

    // MARK: - Initialization

    init() {}

    // MARK: - Public Methods

    /// Inserts the specified text at the current cursor position in the active application.
    /// Temporarily replaces clipboard contents with the text and simulates Cmd+V.
    ///
    /// - Parameter text: The text to insert.
    /// - Throws: `TextInsertionError` if clipboard access or paste simulation fails.
    func insert(text: String) throws {
        // Validate text is not empty
        guard !text.isEmpty else { return }

        // Save current clipboard contents
        let savedClipboard = saveClipboard()

        // Set new text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.setString(text, forType: .string) else {
            // Attempt to restore original clipboard on failure
            restoreClipboard(savedClipboard)
            throw TextInsertionError.textEncodingFailed
        }

        // Simulate paste keystroke
        do {
            try simulatePaste()
        } catch {
            // Restore clipboard on paste failure
            restoreClipboard(savedClipboard)
            throw error
        }

        // Restore original clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) { [weak self] in
            self?.restoreClipboard(savedClipboard)
        }
    }

    // MARK: - Private Methods

    /// Simulates a Cmd+V paste keystroke to insert clipboard contents.
    ///
    /// - Throws: `TextInsertionError.pasteSimulationFailed` if event creation fails.
    private func simulatePaste() throws {
        // Key code for 'V' key
        let vKeyCode: CGKeyCode = 9

        // Create key down event for 'V' with Command modifier
        guard let keyDownEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: vKeyCode,
            keyDown: true
        ) else {
            throw TextInsertionError.pasteSimulationFailed
        }

        // Add Command flag
        keyDownEvent.flags = .maskCommand

        // Create key up event for 'V' with Command modifier
        guard let keyUpEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: vKeyCode,
            keyDown: false
        ) else {
            throw TextInsertionError.pasteSimulationFailed
        }

        keyUpEvent.flags = .maskCommand

        // Post events to HID event system
        keyDownEvent.post(tap: .cghidEventTap)

        // Small delay between key down and key up
        usleep(keyEventDelay)

        keyUpEvent.post(tap: .cghidEventTap)
    }

    /// Saves the current contents of the system clipboard.
    ///
    /// - Returns: A dictionary mapping pasteboard types to their data, or `nil` if clipboard is empty.
    private func saveClipboard() -> [NSPasteboard.PasteboardType: Data]? {
        let pasteboard = NSPasteboard.general
        var savedContents: [NSPasteboard.PasteboardType: Data] = [:]

        // Get all available types on the pasteboard
        guard let types = pasteboard.types else { return nil }

        // Save data for each type
        for type in types {
            if let data = pasteboard.data(forType: type) {
                savedContents[type] = data
            }
        }

        return savedContents.isEmpty ? nil : savedContents
    }

    /// Restores the system clipboard to previously saved contents.
    ///
    /// - Parameter contents: The saved clipboard contents to restore.
    private func restoreClipboard(_ contents: [NSPasteboard.PasteboardType: Data]?) {
        guard let contents = contents, !contents.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Restore all saved types
        for (type, data) in contents {
            pasteboard.setData(data, forType: type)
        }
    }
}

// MARK: - Convenience Extensions

extension TextInserter {
    /// Inserts text without throwing, logging errors instead.
    /// Useful for fire-and-forget insertion scenarios.
    ///
    /// - Parameter text: The text to insert.
    /// - Returns: `true` if insertion succeeded, `false` otherwise.
    @discardableResult
    func insertSafely(text: String) -> Bool {
        do {
            try insert(text: text)
            return true
        } catch {
            print("Text insertion failed: \(error.localizedDescription)")
            return false
        }
    }
}
