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
    /// The full text of our most recent insertion (including any leading space
    /// we added), used by voice editing to select it back and delete/replace it.
    private(set) var lastInsertedText: String?
    private var lastInsertionDate: Date?
    /// The fallback is only trusted briefly; after this the cursor has likely
    /// moved to a different field.
    private let fallbackValidityWindow: TimeInterval = 45

    /// Guard against synthesizing an unreasonable number of selection keystrokes.
    private let maxReselectableLength = 1000

    // MARK: - Public

    /// - Parameter allowLeadingSpace: when false, never prepends a separating
    ///   space (e.g. canned shortcut text the user wants inserted verbatim).
    func insert(text: String, allowLeadingSpace: Bool = true) throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionDenied
        }

        // Each transcript is trimmed, so a second dictation would otherwise land
        // flush against the previous word ("box.that"). Add a separating space
        // when the cursor sits right after a word.
        let payload = (allowLeadingSpace && needsLeadingSpace(before: text)) ? " " + text : text
        recordInsertion(of: payload)
        try pasteText(payload)
    }

    private func recordInsertion(of payload: String) {
        lastInsertedTrailingCharacter = payload.last
        lastInsertedText = payload
        lastInsertionDate = Date()
    }

    private func clearLastInsertion() {
        lastInsertedTrailingCharacter = nil
        lastInsertedText = nil
        lastInsertionDate = nil
    }

    /// Puts `payload` on the pasteboard, pastes it, and restores the user's
    /// clipboard afterward (only if nothing else wrote to it in the meantime).
    private func pasteText(_ payload: String) throws {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotClipboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        try postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard pasteboard.changeCount == ourChangeCount else { return }
            self?.restoreClipboard(snapshot, to: pasteboard)
        }
    }

    // MARK: - Voice Editing (act on the last insertion)

    /// Deletes the entire last insertion. Returns false (no-op) if we can't
    /// trust that the caret still sits right after it.
    @discardableResult
    func deleteLastInserted() -> Bool {
        guard let text = lastInsertedText, !text.isEmpty else { return false }
        guard selectBackOverLastInsertion(length: text.count) else { return false }
        postKey(0x33) // Delete (backspace) clears the selection
        clearLastInsertion()
        return true
    }

    @discardableResult func deleteLastWord() -> Bool { deleteTrailing(TextEditMath.trailingWordLength(of:)) }
    @discardableResult func deleteLastSentence() -> Bool { deleteTrailing(TextEditMath.trailingSentenceLength(of:)) }
    @discardableResult func deleteLastLine() -> Bool { deleteTrailing(TextEditMath.trailingLineLength(of:)) }

    private func deleteTrailing(_ measure: (String) -> Int) -> Bool {
        guard let text = lastInsertedText else { return false }
        let length = measure(text)
        guard length > 0, length <= text.count else { return false }
        guard selectBackOverLastInsertion(length: length) else { return false }
        postKey(0x33)
        let remaining = String(text.dropLast(length))
        if remaining.isEmpty {
            clearLastInsertion()
        } else {
            lastInsertedText = remaining
            lastInsertedTrailingCharacter = remaining.last
            // keep lastInsertionDate so chained edits stay within the window
        }
        return true
    }

    /// Selects the last insertion and pastes `replacement` over it. Returns
    /// false (and leaves text untouched) if the caret can't be trusted.
    @discardableResult
    func replaceLastInserted(with replacement: String) -> Bool {
        guard let text = lastInsertedText, !text.isEmpty else { return false }
        guard selectBackOverLastInsertion(length: text.count) else { return false }
        do { try pasteText(replacement) } catch { return false }
        recordInsertion(of: replacement)
        return true
    }

    /// Verifies the caret is still right after our last insertion, then extends
    /// the selection left by `length` characters. Degrades to false rather than
    /// risk deleting the wrong text.
    private func selectBackOverLastInsertion(length: Int) -> Bool {
        guard AXIsProcessTrusted(), length > 0, length <= maxReselectableLength else { return false }
        guard let when = lastInsertionDate,
              Date().timeIntervalSince(when) < fallbackValidityWindow,
              let expectedTrailing = lastInsertedTrailingCharacter else { return false }

        switch precedingContext() {
        case .startOfField:
            return false                                   // our text can't precede a start caret
        case .character(let actual):
            guard actual == expectedTrailing else { return false }  // caret moved
        case .unknown:
            break                                          // opaque app — trust the time window
        }

        postShiftLeftArrow(times: length)
        return true
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
        guard postKey(keyCode, flags: .maskCommand) else {
            throw InsertionError.eventCreationFailed
        }
    }

    /// Posts a single key chord. Pins flags to exactly `flags` so a modifier the
    /// user is still releasing (the recording hotkey) can't corrupt it.
    @discardableResult
    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        usleep(5_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Extends the selection left by `times` characters (Shift+Left ×N).
    private func postShiftLeftArrow(times: Int) {
        for _ in 0..<times {
            postKey(0x7B, flags: .maskShift) // Left Arrow
            usleep(800)
        }
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
