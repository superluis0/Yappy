//
//  SelectionTransformController.swift
//  Yappy
//
//  Drives "Voice Edit Anywhere": capture the current selection ONCE, hold the
//  hotkey and speak an instruction, transform it (deterministically, or via
//  Apple Intelligence when the intent is open-ended), show a before/after
//  preview card, and Replace by pasting over the still-live selection — exactly
//  the dictation insert path, never an invisible in-place mutation (the failure
//  mode that sank the old "Transforms" feature).
//
//  Design mirrors AskController: a small explicit state machine, a generation
//  counter so a stale async transform can't touch a newer session, injected
//  collaborators (recorder / transcriber / inserter / selection / generative)
//  behind protocols so the whole machine is unit-testable with fakes, and
//  AppDelegate owning the shared audio engine + hotkey wiring.
//

import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation

// MARK: - Injected collaborators

/// Records microphone audio for the instruction. `AudioRecorder` conforms as-is.
protocol VoiceEditRecording: AnyObject {
    func startRecording() -> Bool
    func stopRecording() -> [Float]
}

/// Transcribes the recorded instruction. `ParakeetTranscriptionService` conforms.
@MainActor
protocol VoiceEditTranscribing: AnyObject {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Puts the transformed text back where the selection was — but only after the
/// caller confirms the origin app is still frontmost (the selection is live).
/// Split so the controller can re-check its generation BETWEEN re-activation and
/// the paste, and copy instead of pasting blind when focus has moved.
@MainActor
protocol VoiceEditInserting: AnyObject {
    /// Re-activates `origin` and waits for the switch to settle. No-op when it is
    /// already frontmost (the nonactivating panel usually leaves it there).
    func activateOrigin(_ origin: NSRunningApplication?) async
    /// Whether `origin` is the frontmost app right now — the paste proceeds only
    /// if so, so we never paste over an unrelated caret.
    func isFrontmost(_ origin: NSRunningApplication?) -> Bool
    /// Pastes over the current selection via the shared dictation insert path.
    func paste(_ text: String)
    /// Explicit user-visible copy — NO clipboard snapshot/restore (the user asked
    /// for the result on their clipboard).
    func copyToClipboard(_ text: String)
}

/// Captures the current selection (AX first, Cmd+C fallback) plus the app that
/// owned it, so the replace can re-target that app.
@MainActor
protocol VoiceEditSelecting: AnyObject {
    func captureSelection() -> VoiceEditSelection
}

/// The on-device generative backend for open-ended instructions (Apple
/// Intelligence). Availability-gated so the controller can fall back to a caption.
@MainActor
protocol VoiceEditGenerating: AnyObject {
    func isAvailable() async -> Bool
    func transform(_ text: String, instruction: String) async -> String?
}

/// A captured selection and the app it came from. `text` is empty when nothing
/// was selected (the controller then shows a "select some text first" caption).
struct VoiceEditSelection {
    let text: String
    let origin: NSRunningApplication?
}

// The shared production instances conform as-is — the signatures already match.
extension AudioRecorder: VoiceEditRecording {}
extension ParakeetTranscriptionService: VoiceEditTranscribing {}

/// Audio/UX cues the controller emits for AppDelegate to realize (sounds only —
/// the visual card observes the published state directly).
enum VoiceEditFeedback {
    case listeningStarted
    case listeningStopped
    case replaced
}

// MARK: - Controller

@MainActor
final class SelectionTransformController: ObservableObject {

    /// The single source of truth for what the preview card shows.
    enum Stage: Equatable {
        case idle          // nothing on screen
        case capturing     // grabbing the selection (transient)
        case listening     // recording the spoken instruction
        case transforming  // transcribing + applying the transform
        case preview       // before/after shown, awaiting Replace / Try again
        case replacing     // pasting the result back
        case cancelled     // dismissed without replacing (card hidden)
    }

    // MARK: Published state (drives SelectionTransformView)

    @Published private(set) var stage: Stage = .idle
    /// The captured selection (dimmed "before" pane).
    @Published private(set) var original: String = ""
    /// The transcribed instruction line.
    @Published private(set) var instruction: String = ""
    /// The transformed text (bright "after" pane).
    @Published private(set) var result: String = ""
    /// A transient status line ("Select some text first", "Needs Apple
    /// Intelligence (macOS 26)"), auto-dismissed.
    @Published private(set) var caption: String?
    /// True while an open-ended transform is running on the language model, so
    /// the card can show a spinner.
    @Published private(set) var isGenerating = false

    // MARK: Injected wiring (set by AppDelegate)

    /// True when dictation/Ask own the audio engine or the speech model isn't
    /// ready — recording must never start then (engine contention + the
    /// no-ML-during-audio crash invariant).
    var isBusy: () -> Bool = { false }
    /// Whether the captured clip actually contains speech (AppDelegate wires this
    /// to `AudioRecorder.containsSpeech`) — a silent clip must never be
    /// transcribed into a hallucinated instruction.
    var hasSpeech: ([Float]) -> Bool = { _ in true }
    /// Emits recording sounds; AppDelegate maps these onto `SoundPlayer`.
    var onFeedback: (VoiceEditFeedback) -> Void = { _ in }
    /// Fires true when a live session begins (listening) and false when it ends,
    /// so AppDelegate can arm/disarm the shared Escape interceptor.
    var onActiveChanged: (Bool) -> Void = { _ in }
    /// Safety cap on how long a single instruction may record. Overridable in
    /// tests; defaults to the same ceiling dictation/Ask use.
    var maxRecordingDuration: TimeInterval = Constants.maxRecordingDuration

    // MARK: Collaborators

    private let recorder: VoiceEditRecording
    private let transcriber: VoiceEditTranscribing
    private let inserter: VoiceEditInserting
    private let selection: VoiceEditSelecting
    private let generative: VoiceEditGenerating

    // MARK: Session state

    /// Bumped whenever a session starts or is torn down; async work captures the
    /// value at dispatch and no-ops if it changed, so a slow transcription/
    /// transform can never mutate a newer (or cancelled) session.
    private var generation = 0
    private var recording = false
    /// The app that owned the selection, retargeted for the paste.
    private var origin: NSRunningApplication?
    /// True while the Escape interceptor is armed for this session (guards the
    /// paired on/off so it fires exactly once per session).
    private var escapeArmed = false
    /// After "Try again" the original selection is retained so the next hotkey
    /// hold re-records against it instead of re-grabbing the selection.
    private var retainedForRetry: (text: String, origin: NSRunningApplication?)?
    private var transformTask: Task<Void, Never>?
    private var captionTask: Task<Void, Never>?
    /// Bounds an unbounded hold (or a missed key-up after a tap reset): fires
    /// `endListening` at the max duration, treating the timeout as a key release.
    private var maxDurationTask: Task<Void, Never>?
    /// Set when a hotkey release/cancel is dispatched WHILE `captureSelection` is
    /// still pumping the run loop (the Cmd+C fallback). Re-checked after capture
    /// so we never start recording with the key already up.
    private var releasedDuringCapture = false

    private static let captionDuration: TimeInterval = 2.6
    private static let retryPromptDuration: TimeInterval = 6

    init(
        recorder: VoiceEditRecording,
        transcriber: VoiceEditTranscribing,
        inserter: VoiceEditInserting,
        selection: VoiceEditSelecting,
        generative: VoiceEditGenerating
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.selection = selection
        self.generative = generative
    }

    // MARK: - Coarse state (for AppDelegate)

    /// Any on-screen/live session — used to route Escape and keep the Escape
    /// interceptor alive through the preview.
    var isActive: Bool {
        switch stage {
        case .capturing, .listening, .transforming, .preview, .replacing: return true
        case .idle, .cancelled: return false
        }
    }

    /// The window where the audio engine and/or speech model are in use, so
    /// dictation/Ask stay mutually exclusive with it. A lingering preview card is
    /// deliberately NOT included — the user may dictate elsewhere while it waits.
    var isCapturingAudio: Bool {
        switch stage {
        case .capturing, .listening, .transforming: return true
        default: return false
        }
    }

    var isListening: Bool { stage == .listening }

    // MARK: - Lifecycle (driven by the hotkey)

    /// Hotkey pressed — capture the selection and begin recording the
    /// instruction. Ignored while the audio engine is otherwise busy.
    func begin() {
        guard stage == .idle || stage == .cancelled else { return }
        guard !isBusy() else { return }

        clearCaption()
        generation += 1
        let gen = generation
        releasedDuringCapture = false
        stage = .capturing

        let captured: VoiceEditSelection
        if let retained = retainedForRetry {
            // "Try again" / retry path: reuse the same selection, skip re-capture
            // (synchronous — no run-loop pump, so no reentrancy window).
            retainedForRetry = nil
            captured = VoiceEditSelection(text: retained.text, origin: retained.origin)
        } else {
            captured = selection.captureSelection()
        }

        // captureSelection's Cmd+C fallback can pump the run loop; a hotkey
        // release or cancel dispatched during that window must abort — never
        // start recording with the key already up, and never resurrect a session
        // a concurrent cancel already tore down.
        guard gen == generation, stage == .capturing, !releasedDuringCapture else {
            if stage == .capturing { stage = .idle }
            return
        }

        let text = captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            stage = .idle
            showTransientCaption("Select some text first", duration: Self.captionDuration)
            return
        }

        original = captured.text
        origin = captured.origin
        instruction = ""
        result = ""

        guard recorder.startRecording() else {
            stage = .idle
            resetSession()
            return
        }
        recording = true
        stage = .listening
        armEscape()
        armMaxDuration()
        onFeedback(.listeningStarted)
    }

    /// Hotkey released — stop recording and run the transform. Transcription runs
    /// only AFTER the engine has stopped (same invariant as dictation).
    func endListening() {
        // The release arrived while the (run-loop-pumping) capture was still in
        // flight — flag it so begin() aborts instead of recording key-up.
        if stage == .capturing {
            releasedDuringCapture = true
            return
        }
        guard stage == .listening, recording else { return }
        recording = false
        maxDurationTask?.cancel()
        maxDurationTask = nil
        let samples = recorder.stopRecording()
        onFeedback(.listeningStopped)

        // A silent clip must not be transcribed into a hallucinated instruction —
        // say so and return to the retry state (same selection retained).
        guard hasSpeech(samples) else {
            returnToRetry(caption: "Didn't catch that")
            return
        }

        stage = .transforming

        let gen = generation
        transformTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let raw = (try? await self.transcriber.transcribe(samples)) ?? ""
            guard gen == self.generation, self.stage == .transforming else { return }

            let spoken = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else {
                // Nothing was said — discard cleanly rather than park a ghost card.
                self.endSession(to: .cancelled)
                return
            }
            self.instruction = spoken

            let op = TransformEngine.parse(spoken)
            if let deterministic = TransformEngine.apply(op, to: self.original) {
                self.present(result: deterministic, gen: gen)
            } else {
                await self.runGenerative(instruction: spoken, gen: gen)
            }
        }
    }

    /// Hotkey deactivated mid-hold (secure input, app switch, chord) — discard.
    func cancel() {
        let wasActive = isActive || caption != nil || retainedForRetry != nil
        generation += 1
        transformTask?.cancel()
        transformTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        if recording {
            recording = false
            _ = recorder.stopRecording()
        }
        stage = .cancelled
        resetSession()
        clearCaption()
        if wasActive { disarmEscape() }
    }

    // MARK: - Card actions

    /// Replace button — re-activate the origin app, verify it actually became
    /// frontmost AND the session is still current, then paste over the (live)
    /// selection. If focus moved (the user typed/clicked/switched/dictated), the
    /// selection is dead: never paste blind — copy the result and say so.
    /// One-shot: a second tap is a no-op (the guard drops it once we leave
    /// `.preview`).
    func replace() {
        guard stage == .preview else { return }
        let text = result
        guard !text.isEmpty else { return }
        let capturedOrigin = origin
        stage = .replacing
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.inserter.activateOrigin(capturedOrigin)
            // Re-check AFTER the async re-activation: the selection must still be
            // live (origin frontmost) and this must still be the same session.
            guard gen == self.generation, self.stage == .replacing else { return }
            if self.inserter.isFrontmost(capturedOrigin) {
                // Commit point: stop the Escape interceptor BEFORE posting the
                // paste — synthetic key events posted while our own CGEvent
                // tap is armed get stalled and dropped (the same own-tap stall
                // the dictation path guards against before sendReturn and
                // voice-edit backspaces; live-caught here as "Paste NEVER
                // CONFIRMED" with the replacement silently lost).
                self.disarmEscape()
                self.inserter.paste(text)
                self.onFeedback(.replaced)
                self.endSession(to: .idle)
            } else {
                self.inserter.copyToClipboard(text)
                self.endSession(to: .cancelled)
                self.showTransientCaption("Selection changed — result copied instead",
                                          duration: Self.captionDuration)
            }
        }
    }

    /// Try again — keep the same selection and re-record a new instruction on the
    /// next hotkey hold.
    func tryAgain() {
        guard stage == .preview else { return }
        returnToRetry(caption: "Hold Right Option and say a new instruction")
    }

    /// Parks the session in a "hold again to retry" prompt with the current
    /// selection retained, and DISARMS Escape (the prompt rests at `.idle`, so
    /// AppDelegate stops routing Escape to Voice Edit — leaving the interceptor
    /// armed would swallow Escape system-wide). Re-holding re-arms it via begin().
    private func returnToRetry(caption: String) {
        retainedForRetry = (original, origin)
        generation += 1
        transformTask?.cancel()
        transformTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recording = false
        instruction = ""
        result = ""
        isGenerating = false
        stage = .idle
        disarmEscape()
        // Card stays up via the caption until the user re-holds (or it times out).
        showTransientCaption(caption, duration: Self.retryPromptDuration,
                             endSessionOnExpiry: true)
    }

    // MARK: - Transform completion

    private func present(result output: String, gen: Int) {
        guard gen == generation, stage == .transforming else { return }
        isGenerating = false
        result = output
        stage = .preview
    }

    private func runGenerative(instruction spoken: String, gen: Int) async {
        guard gen == generation, stage == .transforming else { return }
        isGenerating = true

        guard await generative.isAvailable() else {
            guard gen == generation else { return }
            isGenerating = false
            endSession(to: .cancelled)
            showTransientCaption("Needs Apple Intelligence (macOS 26)",
                                 duration: Self.captionDuration)
            return
        }

        let output = await generative.transform(original, instruction: spoken)
        guard gen == generation, stage == .transforming else { return }
        isGenerating = false

        guard let output,
              let cleaned = TransformEngine.sanitizeGenerative(output, original: original) else {
            endSession(to: .cancelled)
            showTransientCaption("Couldn't transform that — try rephrasing",
                                 duration: Self.captionDuration)
            return
        }
        present(result: cleaned, gen: gen)
    }

    // MARK: - Session teardown

    /// Ends the current session, clearing all per-session state and disarming
    /// Escape. Does NOT touch any caption (callers set one afterward when needed).
    private func endSession(to finalStage: Stage) {
        generation += 1
        transformTask?.cancel()
        transformTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        stage = finalStage
        resetSession()
        disarmEscape()
    }

    private func resetSession() {
        recording = false
        original = ""
        instruction = ""
        result = ""
        origin = nil
        isGenerating = false
        retainedForRetry = nil
        releasedDuringCapture = false
    }

    /// Fires `endListening` at the max duration so a runaway hold — or a missed
    /// key-up after a HotkeyManager tap reset — can't leave the recorder running.
    /// The timeout is treated as a key release (stop and transcribe what we have).
    private func armMaxDuration() {
        maxDurationTask?.cancel()
        let duration = maxRecordingDuration
        maxDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled, self.stage == .listening else { return }
            self.endListening()
        }
    }

    private func armEscape() {
        guard !escapeArmed else { return }
        escapeArmed = true
        onActiveChanged(true)
    }

    private func disarmEscape() {
        guard escapeArmed else { return }
        escapeArmed = false
        onActiveChanged(false)
    }

    // MARK: - Captions

    private func showTransientCaption(_ text: String,
                                      duration: TimeInterval,
                                      endSessionOnExpiry: Bool = false) {
        captionTask?.cancel()
        caption = text
        captionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.caption = nil
            // A retry prompt that times out un-armed ends the retained session.
            if endSessionOnExpiry, self.retainedForRetry != nil, self.stage == .idle {
                self.endSession(to: .idle)
            }
        }
    }

    private func clearCaption() {
        captionTask?.cancel()
        captionTask = nil
        caption = nil
    }
}

// MARK: - Real inserter (AppKit)

/// Re-activates the origin app, verifies it is frontmost, and pastes over the
/// still-live selection via the same `TextInserter` the dictation path uses.
/// `allowLeadingSpace: false` keeps the replacement verbatim (no separating
/// space, no continuation-casing).
@MainActor
final class VoiceEditInserter: VoiceEditInserting {
    private let textInserter: TextInserter

    init(textInserter: TextInserter) {
        self.textInserter = textInserter
    }

    func activateOrigin(_ origin: NSRunningApplication?) async {
        if let origin, origin != NSRunningApplication.current, !origin.isActive {
            origin.activate()
        }
        // ALWAYS settle before the frontmost check / paste — even when the
        // origin never lost active status. The Replace click can leave the
        // card panel holding key-window status; the card orders out on
        // `.replacing`, and this delay lets that teardown (and the key
        // handoff back to the origin) complete before Cmd+V is posted.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    func isFrontmost(_ origin: NSRunningApplication?) -> Bool {
        guard let origin else { return false }
        // Yappy's own nonactivating panel doesn't steal focus, so the origin (or
        // Yappy itself, if that was the edit target) being frontmost means the
        // selection is still live.
        if origin == NSRunningApplication.current { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == origin.processIdentifier
    }

    func paste(_ text: String) {
        do {
            try textInserter.insert(text: text, allowLeadingSpace: false)
        } catch {
            VLog.app("voice-edit paste failed: \(error.localizedDescription)")
        }
    }

    func copyToClipboard(_ text: String) {
        // Explicit user copy — no snapshot/restore; the user asked for this.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Real selection reader (AX first, Cmd+C fallback)

/// Reads the current selection. Prefers the accessibility API
/// (`kAXSelectedText` of the focused element — instant, non-destructive); falls
/// back to a synthetic Cmd+C that snapshots and restores the user's clipboard,
/// for apps (Electron, web canvases, terminals) that don't expose a selection to
/// AX. Both remember the frontmost app so the replace can retarget it.
@MainActor
final class VoiceEditSelectionReader: VoiceEditSelecting {

    func captureSelection() -> VoiceEditSelection {
        let origin = NSWorkspace.shared.frontmostApplication
        if let axText = readAXSelectedText(), !axText.isEmpty {
            return VoiceEditSelection(text: axText, origin: origin)
        }
        if let copied = copyViaCommandC(), !copied.isEmpty {
            return VoiceEditSelection(text: copied, origin: origin)
        }
        return VoiceEditSelection(text: "", origin: origin)
    }

    private func readAXSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedObject) == .success,
              let focused = focusedObject else { return nil }
        let element = focused as! AXUIElement

        var valueObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueObject) == .success,
              let text = valueObject as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Snapshot → synthetic Cmd+C → read → restore. Detects "nothing copied" via
    /// the pasteboard change count so an app that ignores the copy yields nil
    /// (rather than the user's prior clipboard text). Bounded run-loop spin so a
    /// slow app still gets serviced without blocking indefinitely.
    private func copyViaCommandC() -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotClipboard(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        postCommandC()

        var copied: String?
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            if pasteboard.changeCount != changeCountBefore {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        restoreClipboard(snapshot, to: pasteboard)
        return copied
    }

    private func snapshotClipboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
    }

    private func restoreClipboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]],
                                  to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyC = CGKeyCode(kVK_ANSI_C)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Tag like every other Yappy-synthesized key so the app's own taps can
        // tell it from real typing (reuses TextInserter's marker; no dup).
        keyDown.setIntegerValueField(.eventSourceUserData, value: TextInserter.syntheticEventTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: TextInserter.syntheticEventTag)
        keyDown.post(tap: .cghidEventTap)
        usleep(5_000)
        keyUp.post(tap: .cghidEventTap)
    }
}

// MARK: - Generative backend (Apple Intelligence)

// FoundationModels ships in the macOS 26 SDK. Wrapped in #if canImport so the
// file still compiles on older SDKs (CI on an older Xcode), where the stub below
// reports unavailable. On the macOS 26 SDK every use is additionally #available
// gated for the macOS 14 deployment target — the exact pattern
// FoundationModelsCleanupProvider uses.
#if canImport(FoundationModels)
import FoundationModels

/// Open-ended selection transforms ("make it more formal", "summarize this")
/// via Apple's on-device model. A fresh session per call keeps each transform
/// history-free; the permissive content-transformation guardrails avoid spurious
/// refusals when faithfully rewriting the user's own text.
@MainActor
final class FoundationModelsTransformProvider: VoiceEditGenerating {

    func isAvailable() async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    func transform(_ text: String, instruction: String) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        guard !text.isEmpty, !instruction.isEmpty else { return nil }
        do {
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            // Bound the reply so a runaway generation aborts instead of grinding
            // to the token ceiling; a rewrite legitimately runs a bit longer than
            // the input, so allow headroom.
            let maxTokens = min(2000, text.count / 2 + 400)
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
            let response = try await session.respond(to: Self.userMessage(text: text, instruction: instruction),
                                                     options: options)
            let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
#if DEBUG
            VLog.app("voice-edit generative error: \(error.localizedDescription)")
#endif
            return nil
        }
    }

    private static let instructions = """
        You rewrite a passage of the user's own text according to a short \
        instruction. Apply the instruction faithfully and output ONLY the \
        rewritten text — no preamble, no quotes, no commentary, no explanation. \
        Preserve the user's meaning and anything the instruction does not ask you \
        to change. Keep lists, line breaks, and digits intact unless the \
        instruction says otherwise. American (US) English spelling.
        """

    private static func userMessage(text: String, instruction: String) -> String {
        """
        Instruction: \(instruction)

        Text:
        \(text)
        """
    }
}

#else

/// Fallback for SDKs without FoundationModels — always unavailable, so the
/// controller shows the "Needs Apple Intelligence" caption.
@MainActor
final class FoundationModelsTransformProvider: VoiceEditGenerating {
    func isAvailable() async -> Bool { false }
    func transform(_ text: String, instruction: String) async -> String? { nil }
}

#endif
