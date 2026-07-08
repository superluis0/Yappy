//
//  TextInserter.swift
//  Yappy
//

import Carbon.HIToolbox
import Cocoa
import CoreGraphics
import os

/// Inserts text at the cursor of the frontmost app by pasting (Cmd+V), then
/// restores the user's clipboard. Pasting works in Electron apps, web views,
/// and terminals where direct accessibility insertion does not.
final class TextInserter {

    /// Notice-level (persisted) breadcrumbs for the paste path. A posted Cmd+V
    /// that never lands is otherwise invisible — it either reaches the frontmost
    /// app or silently evaporates (secure input, a TCC edge, focus elsewhere),
    /// and only a stage-by-stage log can tell those apart in the field. Lengths,
    /// stages, and app names only — never the text being inserted.
    private static let logger = Logger(subsystem: "com.yappy.app", category: "insertion")
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

    /// Marker stamped on every keyboard event this class synthesizes (the paste,
    /// Return, backspace, and selection keystrokes), so the app's own event taps
    /// can tell our events from the user's. Without it, our synthetic Cmd+V
    /// would count as "user typed something" and invalidate the very insertion
    /// context it belongs to.
    static let syntheticEventTag: Int64 = 0x59415050

    /// Caps every synchronous AX IPC round-trip in this process. The system
    /// default messaging timeout is ~6 seconds per call; on the dictation insert
    /// path we issue several AX reads/writes, and a busy destination app can
    /// block our main thread for that full window on each one. Healthy apps
    /// answer AX queries in well under 10 ms, so 0.3 s is ~30× headroom; all AX
    /// reads on Yappy's insertion path already have graceful fallbacks (opaque-
    /// target handling, .unknown classification) if a call times out or fails,
    /// so capping the pathological case at 0.3 s cannot break correctness — it
    /// only bounds worst-case latency. Setting the timeout on the system-wide
    /// accessibility element (per Apple's documentation) applies process-wide,
    /// covering every AX call site in the app — no per-element calls needed.
    private static let axTimeoutConfigured: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }()

    /// True once the user has typed a key, clicked, or switched apps since our
    /// last insertion — the caret can no longer be assumed to sit right after
    /// what we inserted. Gates the OPAQUE-app fallbacks only (leading-space and
    /// voice-edit trust); AX-verified paths don't need it. This is what stops
    /// the stray leading space in apps like Google Docs, whose canvas editor
    /// exposes no focused element to the accessibility API at all (measured):
    /// there the 45 s fallback used to fire even after Enter or a click moved
    /// the caret somewhere a speculative space makes no sense.
    private var contextInvalidatedByUserInput = false

    /// Called (via the app's event taps/monitors) when the user types, clicks,
    /// or switches apps. Cheap and idempotent.
    func noteUserInputOccurred() {
        contextInvalidatedByUserInput = true
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

    /// Re-entrancy guard for voice edits. A voice edit posts a burst of key
    /// events with tiny inter-key sleeps; a second edit that interleaved its
    /// keystrokes with an in-flight one would extend or delete the wrong span.
    /// Everything here runs synchronously on the main thread, so the only way a
    /// second edit arrives mid-flight is re-entrantly (e.g. a queued hotkey
    /// callback firing during a sleep) — this flag makes that a safe no-op.
    private var isVoiceEditInFlight = false

    /// The pending clipboard restore for the most recent paste. Held so a new
    /// paste can CANCEL it before starting: otherwise an overlapping insertion's
    /// restore could fire mid-way through and stamp Yappy's own payload (or a
    /// stale snapshot) over the user's real clipboard.
    private var pendingClipboardRestore: DispatchWorkItem?

    /// Opaque apps (Electron, many web views) don't expose their text to the
    /// accessibility API, so we can't confirm the paste landed. Give a slow
    /// consumer (busy app, machine under load) a generous window before
    /// restoring, rather than the old fixed 0.3 s that races the paste.
    private let opaqueRestoreDelay: TimeInterval = 1.0
    /// For AX-capable apps, poll for the pasted text to appear before restoring.
    /// Bounded so we always restore eventually even if the read never confirms.
    private let restorePollInterval: TimeInterval = 0.05
    private let maxRestorePolls = 24   // ~1.2 s ceiling at 0.05 s spacing

    // MARK: - Public

    /// - Parameter allowLeadingSpace: when false, never prepends a separating
    ///   space (e.g. canned shortcut text the user wants inserted verbatim).
    func insert(text: String, allowLeadingSpace: Bool = true) throws {
        _ = Self.axTimeoutConfigured
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionDenied
        }

        // Each transcript is trimmed, so a second dictation would otherwise land
        // flush against the previous word ("box.that"). Add a separating space
        // when the cursor sits right after a word.
        let payload = (allowLeadingSpace && needsLeadingSpace(before: text)) ? " " + text : text
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        Self.logger.notice("Insert: \(payload.count, privacy: .public) chars -> frontmost '\(frontmost, privacy: .public)'; secureInput=\(IsSecureEventInputEnabled(), privacy: .public)")
        recordInsertion(of: payload)
        try pasteText(payload)
    }

    /// Sends a Return keystroke — used by the "press enter" voice command to submit
    /// (send a message, run a search, commit a cell) after the dictated text lands.
    func sendReturn() {
        postKey(0x24) // Return / Enter
    }

    private func recordInsertion(of payload: String) {
        lastInsertedTrailingCharacter = payload.last
        lastInsertedText = payload
        lastInsertionDate = Date()
        // A fresh insertion re-establishes the context the fallbacks reason
        // about; anything the user does after this re-invalidates it.
        contextInvalidatedByUserInput = false
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

        // Cancel any restore still pending from a previous paste before we
        // overwrite the pasteboard: otherwise its timer could fire against THIS
        // paste's payload and stamp a stale snapshot over the user's clipboard.
        cancelPendingClipboardRestore()

        let snapshot = snapshotClipboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        try postCommandV()
        Self.logger.notice("Cmd+V posted (pasteboard changeCount \(ourChangeCount, privacy: .public))")

        scheduleClipboardRestore(snapshot,
                                 to: pasteboard,
                                 payload: payload,
                                 ourChangeCount: ourChangeCount)
    }

    private func cancelPendingClipboardRestore() {
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = nil
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

    /// Verifies the caret is still right after our last insertion, then selects
    /// the last `length` characters. Prefers a single accessibility set-selection
    /// call (instant, no keystrokes); falls back to synthesizing Shift+Left for
    /// apps that don't expose a settable selection range. Degrades to false
    /// rather than risk selecting — and then deleting — the wrong text.
    private func selectBackOverLastInsertion(length: Int) -> Bool {
        // Trust checks first — cheap, and they gate BOTH the fast path and the
        // fallback so we never act on a stale caret regardless of which we use.
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
            // Opaque app: the time window alone can't see a moved caret. If the
            // user typed/clicked/switched apps since we inserted, refuse rather
            // than risk selecting and deleting the wrong text.
            guard !contextInvalidatedByUserInput else { return false }
        }

        // Re-entrancy guard: a burst of Shift+Left events (fallback) must not
        // interleave with another in-flight edit. Held across both paths so the
        // state stays consistent even when the fast path succeeds.
        guard !isVoiceEditInFlight else { return false }
        isVoiceEditInFlight = true
        defer { isVoiceEditInFlight = false }

        // Fast path: one IPC round-trip instead of `length` keystrokes + sleeps.
        if setSelectionViaAccessibility(length: length) { return true }

        // Fallback for opaque apps that don't allow a settable selection range.
        postShiftLeftArrow(times: length)
        return true
    }

    /// Selects the `length` characters ending at the current caret by SETTING the
    /// focused element's `kAXSelectedTextRange`, then reading it back to confirm
    /// the app honored the request. This replaces `length` synthetic Shift+Left
    /// keystrokes (each with an inter-key sleep) with a single accessibility call.
    ///
    /// Returns false — so the caller falls back to keystrokes — whenever the app
    /// doesn't expose a caret range, rejects the set, or reports back a different
    /// range than requested (Electron/web views typically fall into this bucket).
    /// The read-back is the safety net: we only report success on an exact match,
    /// so a partially-honored or ignored set never leaves us thinking a delete
    /// will land on the right span.
    private func setSelectionViaAccessibility(length: Int) -> Bool {
        guard let focus = focusedCaret() else { return false }
        guard let target = TextEditMath.selectionRange(caretLocation: focus.caret.location, length: length) else {
            return false
        }

        var desired = CFRange(location: target.location, length: target.length)
        guard let axDesired = AXValueCreate(.cfRange, &desired) else { return false }
        guard AXUIElementSetAttributeValue(
            focus.element,
            kAXSelectedTextRangeAttribute as CFString,
            axDesired
        ) == .success else { return false }

        // Verify: read the selection back and require an exact match. Without
        // this an app that silently ignores or clamps the set would leave the
        // caret where it was — and the subsequent delete would hit the wrong text.
        var readbackObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                focus.element,
                kAXSelectedTextRangeAttribute as CFString,
                &readbackObj
              ) == .success,
              let readbackValue = readbackObj,
              CFGetTypeID(readbackValue) == AXValueGetTypeID() else { return false }
        var actual = CFRange()
        guard AXValueGetValue(readbackValue as! AXValue, .cfRange, &actual) else { return false }

        return actual.location == target.location && actual.length == target.length
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
            // Opaque app (Google Docs exposes no focused element at all): only
            // trust the last-insertion memory if the user hasn't typed, clicked,
            // or switched apps since — any of those moves the caret somewhere a
            // speculative space would be wrong (the "stray leading space" bug).
            guard !contextInvalidatedByUserInput,
                  let previous = lastInsertedTrailingCharacter,
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
        guard let focus = focusedCaret() else { return .unknown }
        guard focus.caret.location > 0 else { return .startOfField }

        let range = CFRange(location: focus.caret.location - 1, length: 1)
        guard let string = string(in: range, of: focus.element), let last = string.last else {
            return .unknown
        }
        return .character(last)
    }

    /// The system-wide focused element and the current caret/selection range
    /// within it. Returns nil for apps that don't expose a selected-text range
    /// to the accessibility API (opaque apps), or when nothing is focused.
    /// The single place the focused-element + `kAXSelectedTextRange` read lives,
    /// shared by the leading-space decision, the set-selection fast path, and the
    /// post-paste restore verification.
    private func focusedCaret() -> (element: AXUIElement, caret: CFRange)? {
        let system = AXUIElementCreateSystemWide()
        var focusedObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedObj) == .success,
              let focused = focusedObj else { return nil }
        let element = focused as! AXUIElement

        var rangeObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeObj) == .success,
              let rangeValue = rangeObj, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var caret = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &caret) else { return nil }
        return (element, caret)
    }

    /// Reads the substring occupying `range` in `element` via the parameterized
    /// `kAXStringForRange` attribute. Returns nil if the app can't service it.
    private func string(in range: CFRange, of element: AXUIElement) -> String? {
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var substringObj: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &substringObj
        )
        guard status == .success, let string = substringObj as? String else { return nil }
        return string
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
    /// user is still releasing (the recording hotkey) can't corrupt it. Every
    /// event is stamped with `syntheticEventTag` so the app's own keyDown tap
    /// can distinguish it from real typing (see `noteUserInputOccurred`).
    @discardableResult
    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
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

    /// Whether the frontmost app has finished consuming the synthetic paste.
    private enum PasteConfirmation {
        case confirmed   // the pasted text is now present at the caret
        case notYet      // AX-capable app, but the text hasn't landed yet
        case opaque      // app doesn't expose its text — can't confirm via AX
    }

    /// Restores the user's clipboard once the paste has been consumed, rather
    /// than after a fixed delay that races slow consumers. For AX-capable apps we
    /// poll (cheaply) until the pasted text appears at the caret, then restore
    /// immediately; opaque apps get a single generous delay. The `changeCount`
    /// guard is re-checked on every tick so we never clobber a clipboard the user
    /// changed themselves. Non-blocking: each tick is a separate main-queue work
    /// item, so the pill animation and hotkeys keep running while we wait.
    private func scheduleClipboardRestore(_ snapshot: ClipboardSnapshot,
                                          to pasteboard: NSPasteboard,
                                          payload: String,
                                          ourChangeCount: Int) {
        scheduleRestoreTick(snapshot,
                            to: pasteboard,
                            payload: payload,
                            ourChangeCount: ourChangeCount,
                            attempt: 0)
    }

    private func scheduleRestoreTick(_ snapshot: ClipboardSnapshot,
                                     to pasteboard: NSPasteboard,
                                     payload: String,
                                     ourChangeCount: Int,
                                     attempt: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The user (or a newer paste's restore) put something else on the
            // clipboard — leave it alone.
            guard pasteboard.changeCount == ourChangeCount else {
                self.pendingClipboardRestore = nil
                return
            }

            switch self.pasteLanded(payload) {
            case .confirmed:
                Self.logger.notice("Paste CONFIRMED landed (poll \(attempt, privacy: .public)); restoring clipboard")
                self.restoreClipboard(snapshot, to: pasteboard)
                self.pendingClipboardRestore = nil
            case .notYet where attempt + 1 < self.maxRestorePolls:
                self.scheduleRestoreTick(snapshot,
                                         to: pasteboard,
                                         payload: payload,
                                         ourChangeCount: ourChangeCount,
                                         attempt: attempt + 1)
            case .notYet:
                // Polled to the ceiling without confirmation — restore anyway so
                // we don't strand the user's clipboard. This is the smoking-gun
                // line for a swallowed paste: the target IS AX-readable, we
                // watched for ~1.2 s, and the pasted text never appeared.
                Self.logger.notice("Paste NEVER CONFIRMED after \(attempt + 1, privacy: .public) polls; restoring clipboard anyway")
                self.restoreClipboard(snapshot, to: pasteboard)
                self.pendingClipboardRestore = nil
            case .opaque:
                // Can't verify; give the app a generous fixed window (measured
                // from now) before restoring, rather than re-polling forever.
                Self.logger.notice("Paste target opaque to AX (poll \(attempt, privacy: .public)); restoring clipboard in \(self.opaqueRestoreDelay, format: .fixed(precision: 1), privacy: .public)s")
                self.scheduleOpaqueRestore(snapshot, to: pasteboard, ourChangeCount: ourChangeCount)
            }
        }
        pendingClipboardRestore = work
        // First tick fires immediately (many apps have already consumed the
        // paste by the time the run loop turns); later ticks are spaced out.
        let delay = attempt == 0 ? 0 : restorePollInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleOpaqueRestore(_ snapshot: ClipboardSnapshot,
                                       to pasteboard: NSPasteboard,
                                       ourChangeCount: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClipboardRestore = nil
            guard pasteboard.changeCount == ourChangeCount else { return }
            self.restoreClipboard(snapshot, to: pasteboard)
        }
        pendingClipboardRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + opaqueRestoreDelay, execute: work)
    }

    /// Reads the text immediately before the caret and checks it ends with what
    /// we pasted — evidence the frontmost app has serviced the synthetic Cmd+V.
    /// Compares the payload's trailing characters so we don't depend on the app
    /// exposing the entire field (some cap `kAXStringForRange` reads).
    private func pasteLanded(_ payload: String) -> PasteConfirmation {
        guard let focus = focusedCaret() else { return .opaque }
        let expected = String(payload.suffix(maxReselectableLength))
        let expectedLength = expected.count
        guard expectedLength > 0 else { return .confirmed }
        guard focus.caret.location >= expectedLength else { return .notYet }

        let range = CFRange(location: focus.caret.location - expectedLength, length: expectedLength)
        guard let actual = string(in: range, of: focus.element) else { return .opaque }
        return actual == expected ? .confirmed : .notYet
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
