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

    /// Last character we inserted, used to space consecutive dictations when the
    /// destination app doesn't expose its text to the accessibility API.
    private var lastInsertedTrailingCharacter: Character?
    private var lastInsertionDate: Date?
    /// The fallback is only trusted briefly; after this the cursor has likely
    /// moved to a different field.
    private let fallbackValidityWindow: TimeInterval = 45

    // MARK: - Public

    func insert(text: String) throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionDenied
        }

        // Each transcript is trimmed, so a second dictation would otherwise land
        // flush against the previous word ("box.that"). Add a separating space
        // when the cursor sits right after a word.
        let payload = needsLeadingSpace(before: text) ? " " + text : text
        lastInsertedTrailingCharacter = payload.last
        lastInsertionDate = Date()

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotClipboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
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

    // MARK: - Leading-space Decision

    private enum PrecedingContext {
        case startOfField          // caret at the very start — no space
        case character(Character)  // the char immediately before the caret
        case unknown               // app doesn't expose its text to AX
    }

    /// Whether to prepend a space so a new dictation doesn't abut the previous
    /// word. Prefers the actual character before the caret (accessibility API);
    /// falls back to the last character we inserted for apps that don't expose
    /// their text (Electron, many web views).
    private func needsLeadingSpace(before text: String) -> Bool {
        guard let first = text.first, !first.isWhitespace else { return false }
        // Never put a space before attaching punctuation.
        if ".,!?;:)]}".contains(first) { return false }

        switch precedingContext() {
        case .startOfField:
            return false
        case .character(let previous):
            return shouldSpace(after: previous)
        case .unknown:
            guard let previous = lastInsertedTrailingCharacter,
                  let when = lastInsertionDate,
                  Date().timeIntervalSince(when) < fallbackValidityWindow else {
                return false
            }
            return shouldSpace(after: previous)
        }
    }

    private func shouldSpace(after character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return false }
        // Don't add a space right after an opener or common joiner.
        if "([{/@#-_".contains(character) { return false }
        return true
    }

    private func precedingContext() -> PrecedingContext {
        let system = AXUIElementCreateSystemWide()
        var focusedObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedObj) == .success,
              let focused = focusedObj else { return .unknown }
        let element = focused as! AXUIElement

        var rangeObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeObj) == .success,
              let rangeValue = rangeObj, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .unknown }
        var caret = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &caret) else { return .unknown }
        guard caret.location > 0 else { return .startOfField }

        var charRange = CFRange(location: caret.location - 1, length: 1)
        guard let axCharRange = AXValueCreate(.cfRange, &charRange) else { return .unknown }
        var substringObj: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axCharRange,
            &substringObj
        )
        guard status == .success, let string = substringObj as? String, let last = string.last else {
            return .unknown
        }
        return .character(last)
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
