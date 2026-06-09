//
//  TextInserter.swift
//  Yappy
//

import Cocoa
import CoreGraphics

/// Inserts text at the cursor of the frontmost app by pasting (Cmd+V), then
/// restores the user's clipboard. Pasting works in Electron apps, web views,
/// and terminals where direct accessibility insertion does not.
final class TextInserter {
    enum InsertionError: LocalizedError {
        case accessibilityPermissionDenied
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionDenied:
                return "Accessibility permission is required to insert text. Enable Yappy in System Settings → Privacy & Security → Accessibility."
            case .eventCreationFailed:
                return "Failed to synthesize the paste keystroke."
            }
        }
    }

    /// Pasteboard contents snapshot for restore after pasting.
    private struct ClipboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    // MARK: - Public

    func insert(text: String) throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionDenied
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotClipboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        try postCommandV()

        // Restore the clipboard once the paste has been delivered — but only if
        // nothing else has written to the pasteboard in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard pasteboard.changeCount == ourChangeCount else { return }
            self?.restoreClipboard(snapshot, to: pasteboard)
        }
    }

    /// Copies the current selection in the frontmost app via ⌘C and returns it,
    /// restoring the user's clipboard afterward. Returns nil if nothing was
    /// captured (no selection). Used by Command Mode.
    func copySelection() throws -> String? {
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionDenied
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotClipboard(pasteboard)
        let beforeCount = pasteboard.changeCount

        // Clear first so a stale clipboard string isn't mistaken for a selection.
        pasteboard.clearContents()
        try postCommandKey(0x08) // 'C'

        // ⌘C is asynchronous; poll briefly for the pasteboard to update.
        var captured: String?
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if pasteboard.changeCount != beforeCount {
                captured = pasteboard.string(forType: .string)
                break
            }
            usleep(15_000)
        }

        restoreClipboard(snapshot, to: pasteboard)
        let trimmed = captured?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? captured : nil
    }

    // MARK: - Paste Keystroke

    private func postCommandV() throws {
        try postCommandKey(0x09) // 'V'
    }

    private func postCommandKey(_ keyCode: CGKeyCode) throws {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw InsertionError.eventCreationFailed
        }

        // The user may still be releasing the recording hotkey; pin the flags to
        // exactly Command so stray modifiers don't corrupt the keystroke.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(5_000)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard Preservation

    private func snapshotClipboard(_ pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    types[type] = data
                }
            }
            return types
        }
        return ClipboardSnapshot(items: items)
    }

    private func restoreClipboard(_ snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restored = snapshot.items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
