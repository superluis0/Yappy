//
//  CardShortcutInterceptor.swift
//  Yappy
//

import Carbon.HIToolbox
import Cocoa
import Combine
import CoreGraphics

/// A keyboard action on a floating card (the Answers card, the Voice Edit
/// preview). Every one of those cards' actions used to be mouse-only.
///
/// The obvious fix — letting the panel take keyboard focus — is forbidden: a
/// nonactivating panel that becomes key steals the synthetic ⌘V meant for the
/// origin app, and the replacement silently never lands (see the comment in
/// `SelectionTransformPanelController.makePanel`). So these arrive through a
/// CGEvent tap instead, exactly like Escape does, and no window ever takes
/// focus.
///
/// All chords are ⌘⌥ + a letter. That prefix is deliberately unusual: the tap
/// is session-wide while a card is up, so anything it claims is a keystroke the
/// app underneath does not get. Escape is NOT handled here — `EscapeInterceptor`
/// already owns it, and two head-inserted taps racing for the same key would
/// make which handler wins undefined.
enum CardShortcut: String, CaseIterable, Equatable {
    /// Insert the answer at the cursor / Replace the selection.
    case insert
    case copy
    /// Speak the answer, or stop speaking if it already is.
    case speak
    /// Ask again / Try again.
    case retry
    /// Stop the in-flight answer.
    case stop
    /// Dismiss the card.
    case dismiss

    /// The chord's letter on the user's CURRENT layout — matching is by
    /// character, not virtual keycode, so Dvorak/Colemak/AZERTY users press the
    /// key labeled with this letter, not whatever sits at the ANSI position.
    ///
    /// "X" for dismiss, not "D": ⌘⌥D is the system-wide Show/Hide Dock shortcut,
    /// and a session tap that swallowed it would silently break a global macOS
    /// command whenever a card was up.
    var letter: Character {
        switch self {
        case .insert: return "i"
        case .copy: return "c"
        case .speak: return "s"
        case .retry: return "r"
        case .stop: return "t"
        case .dismiss: return "x"
        }
    }

    /// How the chord is written in a tooltip.
    var displayShortcut: String { "⌘⌥\(String(letter).uppercased())" }

    /// How VoiceOver should read the chord.
    var spokenShortcut: String { "Command Option \(String(letter).uppercased())" }

    /// The modifiers every card chord requires: Command + Option, and nothing
    /// else. Pure, so the matcher is unit-testable without a live event tap —
    /// the caller resolves the pressed key to a base-layout character first
    /// (`CardShortcutInterceptor.baseCharacter(for:)`).
    static func match(character: Character?, flags: CGEventFlags) -> CardShortcut? {
        let interesting: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard flags.intersection(interesting) == [.maskCommand, .maskAlternate] else { return nil }
        guard let character else { return nil }
        let lowered = Character(String(character).lowercased())
        return allCases.first { $0.letter == lowered }
    }
}

/// Delivers `CardShortcut`s to a visible floating card WITHOUT giving its panel
/// keyboard focus. Lifecycle mirrors `EscapeInterceptor`: created once, started
/// only for the seconds a card is on screen, self-healing if the system disables
/// the tap. Every key it does not claim passes through untouched.
final class CardShortcutInterceptor {
    /// Invoked on the main queue for a matched chord. Set by whoever puts a card
    /// on screen; replaced wholesale when a different card takes over.
    var onShortcut: ((CardShortcut) -> Void)?

    /// The chords the visible card can act on RIGHT NOW. Anything outside this
    /// set passes through to the app underneath — the tap must never swallow
    /// ⌘⌥C while the Voice Edit card (which has no Copy) is up. Written by the
    /// binder on the main thread; read in `handle`, whose run-loop source is
    /// also main, so no synchronization is needed.
    var claimedShortcuts: Set<CardShortcut> = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Resolves a virtual keycode to the character on the user's CURRENT
    /// keyboard layout, ignoring modifiers (⌥ must not produce "ı"/"ç"
    /// variants, and Dvorak's "i" is not at the ANSI I position). Falls back
    /// through the raw keyboard layout for input sources that carry no layout
    /// data (CJK input methods), and to nil when translation fails entirely —
    /// a nil never matches, so an untranslatable key just passes through.
    static func baseCharacter(for keyCode: Int64) -> Character? {
        var source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var layoutData = source.flatMap {
            TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData)
        }
        if layoutData == nil {
            source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            layoutData = source.flatMap {
                TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData)
            }
        }
        guard let layoutData else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return errSecParam
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                0, // no modifiers: the BASE character of the key
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return Character(String(utf16CodeUnits: chars, count: length))
    }

    deinit {
        stop()
    }

    /// Creates and enables the tap. Returns false if the tap can't be created
    /// (no accessibility permission) — the card is then mouse-only, as before.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<CardShortcutInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Cheap flags check FIRST — layout translation only runs for the rare
        // keystroke that already holds exactly ⌘⌥.
        let interesting: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(interesting) == [.maskCommand, .maskAlternate] else {
            return Unmanaged.passUnretained(event)
        }

        guard let shortcut = CardShortcut.match(
            character: Self.baseCharacter(for: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags
        ), claimedShortcuts.contains(shortcut) else {
            // Not one of ours, or the visible card can't act on it right now —
            // the app underneath keeps its keystroke.
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in
            self?.onShortcut?(shortcut)
        }
        // Claimed: the app underneath must not also act on it.
        return nil
    }
}

/// Points the chord tap at whichever floating card is currently showing
/// buttons, and tears it down when none is. Lives outside AppDelegate so the
/// routing stays readable and the tap's lifetime is obvious in one place.
@MainActor
final class CardShortcutBinder {
    private let interceptor = CardShortcutInterceptor()
    private let ask: AskController
    private let voiceEdit: SelectionTransformController
    private var cancellables: Set<AnyCancellable> = []

    init(ask: AskController, voiceEdit: SelectionTransformController) {
        self.ask = ask
        self.voiceEdit = voiceEdit
    }

    /// Starts observing both cards. Called once at launch.
    func activate() {
        guard cancellables.isEmpty else { return }
        ask.$run
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebind() }
            .store(in: &cancellables)
        voiceEdit.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebind() }
            .store(in: &cancellables)
        // speakAvailable flips after a run completes (the voice engine probe is
        // async) and it decides whether ⌘⌥S is claimed — rebind on it too.
        ask.$speakAvailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebind() }
            .store(in: &cancellables)
        rebind()
    }

    func stop() {
        interceptor.onShortcut = nil
        interceptor.stop()
    }

    /// The tap is session-wide, so it stays alive only while a card can
    /// actually act on a chord.
    private func rebind() {
        if askCardShowsActions {
            interceptor.onShortcut = { [weak self] shortcut in self?.performAsk(shortcut) }
            interceptor.claimedShortcuts = askClaimedShortcuts
            interceptor.start()
        } else if voiceEdit.stage == .preview {
            interceptor.onShortcut = { [weak self] shortcut in self?.performVoiceEdit(shortcut) }
            // No Copy or Speak on the Voice Edit card — those chords must keep
            // reaching the app underneath.
            interceptor.claimedShortcuts = [.insert, .retry, .stop, .dismiss]
            interceptor.start()
        } else {
            stop()
        }
    }

    /// Only the chords the Ask card's CURRENT status can act on. A claimed
    /// chord is a keystroke stolen from the app underneath, so the set is as
    /// small as the visible buttons.
    private var askClaimedShortcuts: Set<CardShortcut> {
        guard let run = ask.run else { return [] }
        switch run.status {
        case .idle, .preparing, .listening, .transcribing:
            return []
        case .thinking, .working:
            return [.stop, .dismiss]
        case .completed:
            var claimed: Set<CardShortcut> = [.insert, .copy, .retry, .dismiss]
            if ask.speakAvailable { claimed.insert(.speak) }
            return claimed
        case .failed, .cancelled:
            return [.retry, .dismiss]
        }
    }

    /// Mirrors AskPillController's interactivity rule: the compact capture
    /// states show no buttons, so there is nothing for a chord to hit.
    private var askCardShowsActions: Bool {
        guard let run = ask.run else { return false }
        switch run.status {
        case .idle, .preparing, .listening, .transcribing: return false
        case .thinking, .working, .completed, .failed, .cancelled: return true
        }
    }

    private func performAsk(_ shortcut: CardShortcut) {
        guard askCardShowsActions else { return }
        switch shortcut {
        case .insert:
            // OWN-TAP RULE: disarm our tap BEFORE any action that posts
            // synthetic keys (the paste is a synthetic ⌘V) — the same
            // convention EscapeInterceptor follows. The rebind on the next
            // state change re-arms if a card is still up.
            interceptor.stop()
            ask.insertAnswer()
        case .copy: ask.copyAnswer()
        case .speak:
            guard ask.speakAvailable else { return }
            switch ask.speakingPhase {
            case .idle: ask.speakCurrentAnswer()
            case .synthesizing, .speaking: ask.stopSpeakingNow()
            }
        case .retry: ask.retry()
        case .stop: ask.abort()
        case .dismiss: ask.dismiss()
        }
    }

    private func performVoiceEdit(_ shortcut: CardShortcut) {
        guard voiceEdit.stage == .preview else { return }
        switch shortcut {
        case .insert:
            // OWN-TAP RULE: see performAsk(.insert) — replace() pastes.
            interceptor.stop()
            voiceEdit.replace()
        case .retry: voiceEdit.tryAgain()
        case .dismiss, .stop: voiceEdit.cancel()
        // The Voice Edit card has no Copy or Speak action.
        case .copy, .speak: break
        }
    }
}
