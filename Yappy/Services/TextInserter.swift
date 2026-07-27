//
//  TextInserter.swift
//  Yappy
//

import Carbon.HIToolbox
import Cocoa
import CoreGraphics
import os

/// Decides whether a fresh dictation continues the sentence already at the
/// caret, and if so lowercases its sentence-start capital. Parakeet (and the
/// cleanup model) capitalize the first word of every dictation as a new
/// sentence — but when the user released the hotkey mid-sentence and resumed,
/// that capital is wrong ("I have a call — Tomorrow at seven"). Pure logic,
/// deliberately conservative: it only ever lowercases a plainly sentence-cased
/// word, and only when the character before the caret plainly continues a
/// sentence.
enum ContinuationCasing {

    /// True when text ending with `preceding` is mid-sentence at its end — i.e.
    /// new text typed right after it continues the sentence rather than starting
    /// one. Whitelist, not blacklist: only a letter, digit, or comma (after any
    /// trailing spaces) counts as continuing. A newline, sentence terminator,
    /// closing quote, empty window — anything else — does not.
    static func continuesSentence(after preceding: String) -> Bool {
        var trailing = Substring(preceding)
        while let last = trailing.last, last.isWhitespace {
            if last.isNewline { return false }   // new line = new block, keep the capital
            trailing = trailing.dropLast()
        }
        guard let last = trailing.last else { return false }
        return last.isLetter || last.isNumber || last == ","
    }

    /// Words that essentially never end an English sentence — articles,
    /// conjunctions, prepositions, possessive determiners. When a dictation
    /// ends with one of these followed by a period, that period was appended
    /// by the cleanup model to a fragment cut off mid-sentence ("tomorrow at."),
    /// not dictated as a sentence end. Deliberately excludes anything that can
    /// legitimately close a sentence ("I will.", "You should.", "I think so.").
    private static let midSentenceWords: Set<String> = [
        // articles
        "the", "a", "an",
        // conjunctions
        "and", "or", "but", "nor",
        // prepositions
        "of", "at", "to", "with", "for", "from", "by", "into", "onto",
        "about", "than", "as", "per", "via", "upon", "during",
        "between", "among", "toward", "towards", "versus",
        // possessive determiners
        "my", "your", "their", "our",
    ]

    /// True when a previous insertion's text could be the LEFT half of a
    /// continuation join: it ends with a single period (not an ellipsis, and
    /// not "?"/"!" — a question or exclamation is always a finished sentence).
    static func isJoinEligibleTail(_ text: String) -> Bool {
        guard text.hasSuffix(".") else { return false }
        return !text.dropLast().hasSuffix(".")
    }

    /// Words that open a standalone reply or a change of direction rather than
    /// a mid-thought continuation ("Nope, still not working", "Okay, next
    /// topic"). A resume starting with one of these never joins via the
    /// prosody arm — the speaker is answering or pivoting, not continuing.
    private static let standaloneReplyWords: Set<String> = [
        "no", "nope", "yes", "yeah", "yep", "okay", "ok", "sure",
        "thanks", "hey", "hi", "hello", "wait", "actually", "anyway",
        "scratch", "never",
    ]

    /// True when `text` reads as the start of a standalone reply/pivot rather
    /// than a continuation of an interrupted thought.
    static func startsAsStandaloneReply(_ text: String) -> Bool {
        let firstWord = text.drop(while: { !$0.isLetter })
            .prefix(while: { $0.isLetter })
        guard !firstWord.isEmpty else { return false }
        return standaloneReplyWords.contains(firstWord.lowercased())
    }

    /// True when `text` ends with a period that must have been appended to a
    /// mid-sentence fragment: the word before it is one that can't end a
    /// sentence. ("…tomorrow at." → true; "…tomorrow at 7." → false;
    /// "I will." → false.)
    static func endsWithMidSentencePeriod(_ text: String) -> Bool {
        guard text.hasSuffix(".") else { return false }
        let beforePeriod = text.dropLast()
        guard !beforePeriod.hasSuffix(".") else { return false }   // ellipsis / ".."
        let wordStart = beforePeriod.lastIndex(where: { !$0.isLetter })
            .map { beforePeriod.index(after: $0) } ?? beforePeriod.startIndex
        let word = beforePeriod[wordStart...]
        guard !word.isEmpty else { return false }
        return midSentenceWords.contains(word.lowercased())
    }

    /// Lowercases `text`'s first letter when the first word is plainly
    /// sentence-cased. Leaves everything else alone: "I" and its contractions,
    /// acronyms ("HTTP"), mixed-case names ("McRae"), words in `protected`
    /// (user-dictionary terms whose canonical spelling is capitalized), and
    /// text that doesn't start with an uppercase letter at all.
    static func decapitalized(_ text: String, protecting protected: Set<String> = []) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = text.prefix(while: { $0.isLetter || $0 == "'" || $0 == "\u{2019}" })
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I\u{2019}") { return text }
        if protected.contains(String(word)) { return text }
        // Sentence-cased only: a single leading capital, all lowercase after.
        guard word.dropFirst().allSatisfy({ $0.isLowercase || $0 == "'" || $0 == "\u{2019}" }) else {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }
}

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

        var byteCount: Int {
            items.reduce(0) { total, item in
                total + item.values.reduce(0) { $0 + $1.count }
            }
        }
    }

    /// One accessibility capture shared by field classification and insert-time
    /// spacing/casing. `nil` remains reserved for callers that intentionally use
    /// the legacy self-capturing path (shortcuts and voice edits).
    struct InsertContext {
        let fieldKind: FocusedFieldKind
        fileprivate let precedingWindow: PrecedingWindow
    }

    /// Privacy-safe timing values supplied by the dictation pipeline. Paste and
    /// restore stages are filled in by `TextInserter` before the line is emitted.
    struct TimingSeed {
        let transcribeMs: Int
        let audioMs: Int
        let cleanupMs: Int
        let classifyMs: Int
        let words: Int
        let field: FocusedFieldKind
    }

    struct InsertTiming: Equatable {
        let transcribeMs: Int
        let audioMs: Int
        let cleanupMs: Int
        let classifyMs: Int
        let spaceMs: Int
        let snapMs: Int
        let snapBytes: Int
        let confirmMs: Int
        let restoreMs: Int
        let opaque: Bool
        let polls: Int
        let field: FocusedFieldKind
        let words: Int

        var formattedLine: String {
            "insert-timing transcribe_ms=\(transcribeMs) audio_ms=\(audioMs) "
                + "cleanup_ms=\(cleanupMs) classify_ms=\(classifyMs) "
                + "space_ms=\(spaceMs) snap_ms=\(snapMs) snap_bytes=\(snapBytes) "
                + "confirm_ms=\(confirmMs) restore_ms=\(restoreMs) "
                + "opaque=\(opaque ? 1 : 0) polls=\(polls) "
                + "field=\(field.rawValue) words=\(words)"
        }
    }

    private final class ClipboardSnapshotBox: @unchecked Sendable {
        var snapshot = ClipboardSnapshot(items: [])
    }

    private final class TimingTracker {
        let seed: TimingSeed
        let spaceMs: Int
        let snapMs: Int
        let snapBytes: Int
        let confirmStartedAt: CFTimeInterval
        private var emitted = false

        init(seed: TimingSeed, spaceMs: Int, snapMs: Int, snapBytes: Int,
             confirmStartedAt: CFTimeInterval) {
            self.seed = seed
            self.spaceMs = spaceMs
            self.snapMs = snapMs
            self.snapBytes = snapBytes
            self.confirmStartedAt = confirmStartedAt
        }

        func emit(opaque: Bool, polls: Int, restoreMs: Int) {
            guard !emitted else { return }
            emitted = true
            let timing = InsertTiming(
                transcribeMs: seed.transcribeMs,
                audioMs: seed.audioMs,
                cleanupMs: seed.cleanupMs,
                classifyMs: seed.classifyMs,
                spaceMs: spaceMs,
                snapMs: snapMs,
                snapBytes: snapBytes,
                confirmMs: Int((CACurrentMediaTime() - confirmStartedAt) * 1000),
                restoreMs: restoreMs,
                opaque: opaque,
                polls: polls,
                field: seed.field,
                words: seed.words
            )
            VLog.store(timing.formattedLine)
        }
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
    /// Whether the last insertion's PRE-cleanup transcript ended without terminal
    /// punctuation — the ASR's prosody signal that the speaker trailed off
    /// mid-thought (the cleanup model appends the period regardless). Feeds the
    /// continuation decision for the next dictation. Kept in `recordInsertion`
    /// so it can never describe a different insertion than `lastInsertedText`.
    private(set) var lastInsertionRawEndedMidThought = false
    /// When the last insertion landed — exposed so the dictation pipeline can
    /// measure the press-to-resume gap for the continuation decision.
    var lastInsertionAt: Date? { lastInsertionDate }
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
    private var pendingTimingTracker: TimingTracker?

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

    /// Canonical spellings from the user's dictionary that start with a capital
    /// ("Cigna", "Xcode") — never lowercased by the continuation adjustment.
    /// Kept in sync by the AppDelegate's dictionary sink.
    var protectedCapitalizedWords: Set<String> = []

    /// The tail of our last insertion when it's still eligible for a
    /// continuation join: it ended with a single period and the insertion is
    /// recent enough to trust. The dictation pipeline reads this to decide
    /// whether to consult the continuation judge; nil means "don't bother".
    /// (The insert-time repair re-verifies the caret against this text — this
    /// accessor alone never authorizes an edit.)
    var pendingContinuationTail: String? {
        guard let last = lastInsertedText,
              ContinuationCasing.isJoinEligibleTail(last),
              let when = lastInsertionDate,
              Date().timeIntervalSince(when) < fallbackValidityWindow else { return nil }
        return String(last.suffix(120))
    }

    /// - Parameter allowLeadingSpace: when false, never prepends a separating
    ///   space (e.g. canned shortcut text the user wants inserted verbatim —
    ///   which also skips the continuation-casing adjustment).
    /// - Parameter joinContinuation: when true, the dictation pipeline has
    ///   decided (deterministically or via the on-device continuation judge)
    ///   that this text continues the previous insertion's sentence — repair
    ///   the trailing period without requiring a mid-sentence function word.
    ///   The caret is still AX-verified before any repair.
    /// - Parameter rawEndedMidThought: whether this dictation's PRE-cleanup
    ///   transcript lacked terminal punctuation (ASR prosody said the speaker
    ///   trailed off) — remembered for the NEXT dictation's continuation
    ///   decision. Irrelevant to (and unused by) this insertion itself.
    func insert(text: String, allowLeadingSpace: Bool = true,
                context: InsertContext? = nil,
                joinContinuation: Bool = false, rawEndedMidThought: Bool = false,
                timing: TimingSeed? = nil) throws {
        _ = Self.axTimeoutConfigured
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionDenied
        }

        // One AX read of the text just before the caret feeds both decisions
        // below (spacing and casing) — no second round-trip.
        let spaceStartedAt = CACurrentMediaTime()
        var window = context?.precedingWindow ?? precedingWindow()

        // Continuation repair: when OUR previous insertion ended with a period
        // appended to a mid-sentence fragment ("tomorrow at.") and the user
        // resumed dictating at that same caret, delete that period before
        // inserting — the resumed text then joins the sentence it always
        // belonged to. Two ways in: deterministically (the word before the
        // period can't end a sentence), or via `joinContinuation` (the pipeline
        // consulted the on-device judge with both fragments in view). Either
        // way the text at the caret must verifiably be our own insertion's tail.
        if allowLeadingSpace,
           !ContinuationCasing.startsAsStandaloneReply(text),
           canRepairMidSentencePeriod(window: window, requireMidSentenceWord: !joinContinuation) {
            postKey(0x33)   // backspace over our own spurious period
            if let last = lastInsertedText {
                let trimmed = String(last.dropLast())
                lastInsertedText = trimmed
                lastInsertedTrailingCharacter = trimmed.last
            }
            switch window {
            case .text(let string):
                let repaired = String(string.dropLast())
                window = repaired.isEmpty ? .unknown : .text(repaired)
            case .unknown, .startOfField:
                if let last = lastInsertedText {
                    window = .text(String(last.suffix(Self.precedingWindowLength)))
                }
            }
            Self.logger.notice("Continuation repair: removed our mid-sentence period before resumed dictation")
        }

        // A dictation resumed mid-sentence (hotkey released and re-pressed)
        // arrives sentence-capitalized; lowercase it when the caret plainly
        // continues a sentence. Verbatim insertions are never adjusted.
        let adjusted = allowLeadingSpace ? continuationAdjusted(text, window: window) : text

        // Each transcript is trimmed, so a second dictation would otherwise land
        // flush against the previous word ("box.that"). Add a separating space
        // when the cursor sits right after a word.
        let payload = (allowLeadingSpace && needsLeadingSpace(before: adjusted, window: window))
            ? " " + adjusted : adjusted
        let spaceMs = Int((CACurrentMediaTime() - spaceStartedAt) * 1000)
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        Self.logger.notice("Insert: \(payload.count, privacy: .public) chars -> frontmost '\(frontmost, privacy: .public)'; secureInput=\(IsSecureEventInputEnabled(), privacy: .public)")
        try pasteText(payload, timing: timing, spaceMs: spaceMs)
        // Only trust this memory after Cmd+V was successfully created and posted.
        // A failed retry must not poison opaque-field spacing for the next dictation.
        recordInsertion(of: payload, rawEndedMidThought: rawEndedMidThought)
    }

    /// Captures the focused element once, then role/subrole/selection in one AX
    /// batch and (only for a non-zero caret) one short string-for-range read.
    /// Every failure remains advisory: field and preceding text independently
    /// fall back to `.unknown`, matching the former two-reader behavior.
    func captureInsertContext() -> InsertContext {
        _ = Self.axTimeoutConfigured
        let system = AXUIElementCreateSystemWide()
        var focusedObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedObj
        ) == .success, let focusedObj else {
            return InsertContext(fieldKind: .unknown, precedingWindow: .unknown)
        }
        let element = focusedObj as! AXUIElement

        let attributes = [kAXRoleAttribute, kAXSubroleAttribute,
                          kAXSelectedTextRangeAttribute] as CFArray
        var valuesObj: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesObj
        ) == .success, let values = valuesObj as? [AnyObject], values.count == 3 else {
            return InsertContext(fieldKind: .unknown, precedingWindow: .unknown)
        }

        let fieldKind = FocusedFieldClassifier.kind(
            role: values[0] as? String,
            subrole: values[1] as? String
        )
        guard CFGetTypeID(values[2]) == AXValueGetTypeID() else {
            return InsertContext(fieldKind: fieldKind, precedingWindow: .unknown)
        }
        var caret = CFRange()
        guard AXValueGetValue(values[2] as! AXValue, .cfRange, &caret) else {
            return InsertContext(fieldKind: fieldKind, precedingWindow: .unknown)
        }
        guard caret.location > 0 else {
            return InsertContext(fieldKind: fieldKind, precedingWindow: .startOfField)
        }
        let length = min(caret.location, Self.precedingWindowLength)
        let range = CFRange(location: caret.location - length, length: length)
        let window = string(in: range, of: element).flatMap { value in
            value.isEmpty ? nil : PrecedingWindow.text(value)
        } ?? .unknown
        return InsertContext(fieldKind: fieldKind, precedingWindow: window)
    }

    /// Sends a Return keystroke — used by the "press enter" voice command to submit
    /// (send a message, run a search, commit a cell) after the dictated text lands.
    func sendReturn() {
        postKey(0x24) // Return / Enter
    }

    private func recordInsertion(of payload: String, rawEndedMidThought: Bool = false) {
        lastInsertedTrailingCharacter = payload.last
        lastInsertedText = payload
        lastInsertionDate = Date()
        lastInsertionRawEndedMidThought = rawEndedMidThought
        // A fresh insertion re-establishes the context the fallbacks reason
        // about; anything the user does after this re-invalidates it.
        contextInvalidatedByUserInput = false
    }

    private func clearLastInsertion() {
        lastInsertedTrailingCharacter = nil
        lastInsertedText = nil
        lastInsertionDate = nil
        lastInsertionRawEndedMidThought = false
    }

    /// Puts `payload` on the pasteboard, pastes it, and restores the user's
    /// clipboard afterward (only if nothing else wrote to it in the meantime).
    private func pasteText(_ payload: String, timing: TimingSeed? = nil,
                           spaceMs: Int = 0) throws {
        let pasteboard = NSPasteboard.general

        // Cancel any restore still pending from a previous paste before we
        // overwrite the pasteboard: otherwise its timer could fire against THIS
        // paste's payload and stamp a stale snapshot over the user's clipboard.
        cancelPendingClipboardRestore()

        // Snapshot work is size-proportional. Start it off-main, then JOIN before
        // clearContents() — the join is the hard clipboard-preservation invariant.
        let snapshotStartedAt = CACurrentMediaTime()
        let snapshotBox = ClipboardSnapshotBox()
        let snapshotGroup = DispatchGroup()
        snapshotGroup.enter()
        DispatchQueue.global(qos: .utility).async { [snapshotBox] in
            snapshotBox.snapshot = Self.snapshotClipboard(pasteboard)
            snapshotGroup.leave()
        }
        snapshotGroup.wait()
        let snapshot = snapshotBox.snapshot
        let snapMs = Int((CACurrentMediaTime() - snapshotStartedAt) * 1000)

        // NEVER move this clear above the snapshot join.
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        do {
            try postCommandV()
        } catch {
            // Event creation failed after we staged the payload. Restore the
            // snapshot synchronously while our changeCount still owns the board.
            if pasteboard.changeCount == ourChangeCount {
                restoreClipboard(snapshot, to: pasteboard)
            }
            throw error
        }
        Self.logger.notice("Cmd+V posted (pasteboard changeCount \(ourChangeCount, privacy: .public))")

        let tracker = timing.map {
            TimingTracker(seed: $0, spaceMs: spaceMs, snapMs: snapMs,
                          snapBytes: snapshot.byteCount,
                          confirmStartedAt: CACurrentMediaTime())
        }
        pendingTimingTracker = tracker
        scheduleClipboardRestore(snapshot,
                                 to: pasteboard,
                                 payload: payload,
                                 ourChangeCount: ourChangeCount,
                                 tracker: tracker)
    }

    private func cancelPendingClipboardRestore() {
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = nil
        pendingTimingTracker?.emit(opaque: false, polls: 0, restoreMs: 0)
        pendingTimingTracker = nil
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

    // MARK: - Preceding-context Decisions (spacing + continuation casing)

    private enum PrecedingContext {
        case startOfField          // caret at the very start — no space
        case character(Character)  // the char immediately before the caret
        case unknown               // app doesn't expose its text to AX
    }

    /// A short stretch of text immediately before the caret — one AX read shared
    /// by the leading-space decision (its last character) and the continuation-
    /// casing decision (its last non-space character).
    fileprivate enum PrecedingWindow {
        case startOfField
        case text(String)          // 1...windowLength chars ending at the caret
        case unknown
    }

    private static let precedingWindowLength = 8

    private func precedingWindow() -> PrecedingWindow {
        guard let focus = focusedCaret() else { return .unknown }
        guard focus.caret.location > 0 else { return .startOfField }
        let length = min(focus.caret.location, Self.precedingWindowLength)
        let range = CFRange(location: focus.caret.location - length, length: length)
        guard let string = string(in: range, of: focus.element), !string.isEmpty else {
            return .unknown
        }
        return .text(string)
    }

    /// Whether the caret verifiably sits right after our own last insertion AND
    /// that insertion ended with a repairable period. `requireMidSentenceWord`
    /// demands the deterministic signal (the word before the period can't end a
    /// sentence); the judge-approved path drops that requirement but every
    /// trust gate still applies. AX-capable apps verify by matching the text
    /// before the caret against the insertion's tail; opaque apps fall back to
    /// the last-insertion memory under the same trust gates as every other
    /// opaque fallback here.
    private func canRepairMidSentencePeriod(window: PrecedingWindow,
                                            requireMidSentenceWord: Bool) -> Bool {
        guard let last = lastInsertedText,
              ContinuationCasing.isJoinEligibleTail(last),
              !requireMidSentenceWord || ContinuationCasing.endsWithMidSentencePeriod(last),
              let when = lastInsertionDate,
              Date().timeIntervalSince(when) < fallbackValidityWindow else { return false }
        switch window {
        case .startOfField:
            return false
        case .text(let string):
            // The text before the caret must BE our insertion's tail — an exact
            // match over the overlap, so we never delete a character we didn't
            // put there.
            let overlap = min(string.count, last.count)
            guard overlap > 0 else { return false }
            return string.suffix(overlap) == last.suffix(overlap)
        case .unknown:
            return !contextInvalidatedByUserInput
        }
    }

    /// Lowercases a resumed dictation's sentence-start capital when the caret
    /// plainly continues a sentence. Same trust model as the leading-space
    /// fallback: prefer the real text before the caret; in opaque apps fall back
    /// to our last insertion, but only while that memory is still valid.
    private func continuationAdjusted(_ text: String, window: PrecedingWindow) -> String {
        let preceding: String
        switch window {
        case .startOfField:
            return text
        case .text(let string):
            preceding = string
        case .unknown:
            guard !contextInvalidatedByUserInput,
                  let last = lastInsertedText,
                  let when = lastInsertionDate,
                  Date().timeIntervalSince(when) < fallbackValidityWindow else {
                return text
            }
            preceding = String(last.suffix(Self.precedingWindowLength))
        }
        guard ContinuationCasing.continuesSentence(after: preceding) else { return text }
        return ContinuationCasing.decapitalized(text, protecting: protectedCapitalizedWords)
    }

    /// Whether to prepend a space so a new dictation doesn't abut the previous
    /// word. Prefers the actual character before the caret (accessibility API);
    /// falls back to the last character we inserted for apps that don't expose
    /// their text (Electron, many web views).
    private func needsLeadingSpace(before text: String, window: PrecedingWindow) -> Bool {
        guard let first = text.first, !first.isWhitespace else { return false }
        // Never put a space before attaching punctuation.
        if ".,!?;:)]}".contains(first) { return false }

        switch window {
        case .startOfField:
            return false
        case .text(let string):
            guard let previous = string.last else { return false }
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

    private static func snapshotClipboard(_ pasteboard: NSPasteboard) -> ClipboardSnapshot {
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
                                          ourChangeCount: Int,
                                          tracker: TimingTracker?) {
        scheduleRestoreTick(snapshot,
                            to: pasteboard,
                            payload: payload,
                            ourChangeCount: ourChangeCount,
                            attempt: 0,
                            tracker: tracker)
    }

    private func scheduleRestoreTick(_ snapshot: ClipboardSnapshot,
                                     to pasteboard: NSPasteboard,
                                     payload: String,
                                     ourChangeCount: Int,
                                     attempt: Int,
                                     tracker: TimingTracker?) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The user (or a newer paste's restore) put something else on the
            // clipboard — leave it alone.
            guard pasteboard.changeCount == ourChangeCount else {
                self.pendingClipboardRestore = nil
                tracker?.emit(opaque: false, polls: attempt + 1, restoreMs: 0)
                if self.pendingTimingTracker === tracker { self.pendingTimingTracker = nil }
                return
            }

            switch self.pasteLanded(payload) {
            case .confirmed:
                Self.logger.notice("Paste CONFIRMED landed (poll \(attempt, privacy: .public)); restoring clipboard")
                let restoreStartedAt = CACurrentMediaTime()
                self.restoreClipboard(snapshot, to: pasteboard)
                self.pendingClipboardRestore = nil
                tracker?.emit(
                    opaque: false,
                    polls: attempt + 1,
                    restoreMs: Int((CACurrentMediaTime() - restoreStartedAt) * 1000)
                )
                if self.pendingTimingTracker === tracker { self.pendingTimingTracker = nil }
            case .notYet where attempt + 1 < self.maxRestorePolls:
                self.scheduleRestoreTick(snapshot,
                                         to: pasteboard,
                                         payload: payload,
                                         ourChangeCount: ourChangeCount,
                                         attempt: attempt + 1,
                                         tracker: tracker)
            case .notYet:
                // Polled to the ceiling without confirmation — restore anyway so
                // we don't strand the user's clipboard. This is the smoking-gun
                // line for a swallowed paste: the target IS AX-readable, we
                // watched for ~1.2 s, and the pasted text never appeared.
                Self.logger.notice("Paste NEVER CONFIRMED after \(attempt + 1, privacy: .public) polls; restoring clipboard anyway")
                let restoreStartedAt = CACurrentMediaTime()
                self.restoreClipboard(snapshot, to: pasteboard)
                self.pendingClipboardRestore = nil
                tracker?.emit(
                    opaque: false,
                    polls: attempt + 1,
                    restoreMs: Int((CACurrentMediaTime() - restoreStartedAt) * 1000)
                )
                if self.pendingTimingTracker === tracker { self.pendingTimingTracker = nil }
            case .opaque:
                // Can't verify; give the app a generous fixed window (measured
                // from now) before restoring, rather than re-polling forever.
                Self.logger.notice("Paste target opaque to AX (poll \(attempt, privacy: .public)); restoring clipboard in \(self.opaqueRestoreDelay, format: .fixed(precision: 1), privacy: .public)s")
                self.scheduleOpaqueRestore(snapshot, to: pasteboard,
                                           ourChangeCount: ourChangeCount,
                                           polls: attempt + 1,
                                           tracker: tracker)
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
                                       ourChangeCount: Int,
                                       polls: Int,
                                       tracker: TimingTracker?) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClipboardRestore = nil
            guard pasteboard.changeCount == ourChangeCount else {
                tracker?.emit(opaque: true, polls: polls, restoreMs: 0)
                if self.pendingTimingTracker === tracker { self.pendingTimingTracker = nil }
                return
            }
            let restoreStartedAt = CACurrentMediaTime()
            self.restoreClipboard(snapshot, to: pasteboard)
            tracker?.emit(
                opaque: true,
                polls: polls,
                restoreMs: Int((CACurrentMediaTime() - restoreStartedAt) * 1000)
            )
            if self.pendingTimingTracker === tracker { self.pendingTimingTracker = nil }
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
