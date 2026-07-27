//
//  WhatsNew.swift
//  Yappy
//

import Foundation
import Combine

/// The "What's New in Yappy" content shown once after the app updates to a version
/// that has release notes. Keyed by marketing version (`CFBundleShortVersionString`).
///
/// The decision logic ([pending(current:prior:onboardingComplete:)]) is a pure
/// function so it can be unit-tested without UserDefaults or a bundle; the
/// `pendingAfterLaunch` convenience wires it to real persistence and is called once
/// from `AppDelegate` at launch (it advances the stored "last seen" version, so the
/// card shows at most once per update and never on a fresh install).
enum WhatsNew {
    /// One bullet in the What's New card.
    struct Highlight: Identifiable, Equatable {
        let icon: String // SF Symbol name
        let title: String
        let detail: String
        var id: String { title }
    }

    /// The release-notes card for a single version.
    struct Entry: Identifiable, Equatable {
        let version: String
        let headline: String
        let highlights: [Highlight]
        var id: String { version }
    }

    /// UserDefaults key tracking the last version the user has seen the card for.
    static let lastSeenKey = "com.yappy.lastSeenVersion"

    /// The running app's marketing version (e.g. "2.1").
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // MARK: - Content

    /// Release notes per version. Add a new entry when shipping a release worth
    /// announcing; upgraders from any earlier version see the entry for the
    /// version they land on.
    static let entries: [String: Entry] = [
        "3.1.0": Entry(
            version: "3.1.0",
            headline: "Your words, kept exactly as you said them.",
            highlights: [
                Highlight(icon: "text.quote",
                          title: "Spoken words stay words",
                          detail: "“She missed her period”, “add a dash of salt”, “one of these days” — Yappy now tells the difference between a punctuation command and an ordinary noun, so your sentences survive intact. Saying “comma” still types a comma."),
                Highlight(icon: "character.book.closed.fill",
                          title: "Your dictionary guides the polish",
                          detail: "Terms you have taught Yappy now travel with the cleanup pass, so a name or bit of jargon keeps the exact spelling and capitalization you chose instead of being second-guessed."),
                Highlight(icon: "arrow.uturn.backward.circle",
                          title: "See what changed",
                          detail: "When the polish pass edits your text, the pill names what it did — “Polished punctuation”, “Polished capitalization” — and one click puts your original words back."),
                Highlight(icon: "lock.shield",
                          title: "Answers clean up after themselves",
                          detail: "Quitting Yappy now purges the working files its Answers backends leave behind, and a new Storage panel in Settings shows exactly what is on disk and where, so nothing lingers unseen."),
                Highlight(icon: "slider.horizontal.3",
                          title: "A calmer Settings",
                          detail: "Sections collapse, dividers and stray tints are gone, and related options group under a single quiet rail — the same settings, far less noise.")
            ]),
        "3.0.0": Entry(
            version: "3.0.0",
            headline: "Edit anything, anywhere, with your voice.",
            highlights: [
                Highlight(icon: "wand.and.stars",
                          title: "Voice Edit (experimental)",
                          detail: "Select text in any app, hold Right Option, and say the change — “make this bullets”, “make it more formal”, “fix the spelling”. A preview card shows exactly what will change before you Replace. On-device, off by default."),
                Highlight(icon: "bolt.fill",
                          title: "Short dictations land instantly",
                          detail: "Quick replies skip the heavy polish pass they never needed, and the insert path sheds redundant work — text appears the moment you release the key. A new “How much cleanup” setting also lets you keep every word exactly as you said it."),
                Highlight(icon: "character.book.closed",
                          title: "It learns your words",
                          detail: "Say “scratch that”, fix a word, and Yappy quietly learns the correction as a dictionary alias — undo it with one click on the pill. Low-confidence guesses become suggestions instead, never silent changes."),
                Highlight(icon: "list.bullet.rectangle",
                          title: "Every command, one page",
                          detail: "A new Commands tab lists everything you can say — punctuation, line breaks, lists, “press enter”, edits — mined straight from the code that parses them, so it’s never out of date."),
                Highlight(icon: "exclamationmark.bubble",
                          title: "Failures show their face",
                          detail: "If text can’t insert, the mic goes quiet, or a backend signs out, Yappy says so on the pill — with a tap-to-recover action — instead of failing silently."),
                Highlight(icon: "keyboard",
                          title: "Pick your Ask key",
                          detail: "Answers can now live on Right Control, Right Shift, or Right Option — for keyboards where the Fn/Globe key never reaches macOS. Fn stays the default.")
            ]),
        "2.8.0": Entry(
            version: "2.8.0",
            headline: "It picks up right where you left off.",
            highlights: [
                Highlight(icon: "arrow.triangle.merge",
                          title: "Resume mid-sentence",
                          detail: "Let go of the hotkey mid-thought, press it again, and keep talking. Yappy joins the pieces into one clean sentence — no stray period, no random capital — using on-device judgment that never leaves your Mac."),
                Highlight(icon: "clock",
                          title: "Times land as times",
                          detail: "“Seven thirty AM” arrives as 7:30 AM even when the speech model writes it oddly. Deterministic, never a guess."),
                Highlight(icon: "lock.fill",
                          title: "Secure fields stay secret",
                          detail: "Password and other secure inputs now skip AI cleanup and history entirely — dictate into them with confidence."),
                Highlight(icon: "speaker.wave.2.fill",
                          title: "Answers aloud, minus the footnotes",
                          detail: "Read-aloud now skips citation links and source lists, so you hear the answer, not the bibliography.")
            ]),
        "2.6": Entry(
            version: "2.6",
            headline: "Answers can speak now.",
            highlights: [
                Highlight(icon: "speaker.wave.2.fill",
                          title: "Read answers aloud",
                          detail: "A new Speak button on the answer card — or just say “read that” — reads the reply out loud in a natural voice. Say “stop talking” to stop, or hold Fn to interrupt and ask something else."),
                Highlight(icon: "lock.laptopcomputer",
                          title: "100% on your Mac",
                          detail: "The voice runs entirely on-device — nothing spoken aloud ever leaves your computer. Optional: install mlx-audio once and it lights up green in Settings."),
                Highlight(icon: "waveform",
                          title: "Eight voices, American and British",
                          detail: "Pick from eight on-device voices across American and British accents, and choose whether to speak on request or read every answer automatically as it finishes.")
            ]),
        "2.5": Entry(
            version: "2.5",
            headline: "Ask out loud. Answers arrive.",
            highlights: [
                Highlight(icon: "questionmark.bubble",
                          title: "Answers — hold Fn, get an answer",
                          detail: "Speak a question and a floating card answers it, researched with live web search and cited sources — on your own Codex (ChatGPT) or Grok account. Off by default, one toggle in Settings."),
                Highlight(icon: "bolt.fill",
                          title: "Fast on both models",
                          detail: "Grok now answers in seconds, not half a minute — warm sessions, real follow-up threads, and honest timing shown on every card."),
                Highlight(icon: "mic.fill",
                          title: "Talk to the card",
                          detail: "Say “insert that” to drop the answer at your cursor, “copy that”, “pin that” — or just hold Fn mid-answer to interrupt and redirect."),
                Highlight(icon: "lock.shield",
                          title: "Dictation stays 100% on-device",
                          detail: "Nothing about dictation changed: audio never leaves your Mac. Answers sends only your typed-out question, only when you turn it on.")
            ]),
        "2.1": Entry(
            version: "2.1",
            headline: "On-device intelligence, and updates that come to you.",
            highlights: [
                Highlight(icon: "apple.logo",
                          title: "Apple Intelligence cleanup",
                          detail: "Polish transcripts on-device with Apple Intelligence — no server, nothing leaves your Mac."),
                Highlight(icon: "arrow.down.circle",
                          title: "Automatic updates",
                          detail: "Yappy now updates itself with one click via a signed, notarized installer."),
                Highlight(icon: "text.badge.plus",
                          title: "Spoken punctuation & lists",
                          detail: "Say “comma”, “question mark”, or count off “one… two… three…” to get real punctuation and numbered lists."),
                Highlight(icon: "note.text",
                          title: "Scratchpad",
                          detail: "Dictate into a floating scratchpad anytime with ⌥⇧S.")
            ]),
        "2.2": Entry(
            version: "2.2",
            headline: "Updates you’ll notice — and a faster, sharper feel.",
            highlights: [
                Highlight(icon: "bell.badge",
                          title: "Gentle update notices",
                          detail: "When a new version is ready, Yappy shows a calm banner, a menu-bar dot, and an “Update to Yappy …” item at the top of the menu — install whenever you like, or manage it in Settings → Software Update."),
                Highlight(icon: "bolt.fill",
                          title: "Instant on launch",
                          detail: "The first press after opening Yappy starts recording right away — the audio engine and speech model warm up ahead of time."),
                Highlight(icon: "checkmark.bubble",
                          title: "Sharper cleanup",
                          detail: "Dictating a question now types the question instead of answering it, and on-device cleanup is quicker and more reliable.")
            ]),
        "2.4": Entry(
            version: "2.4",
            headline: "It hears you better — and shows its work.",
            highlights: [
                Highlight(icon: "waveform.badge.plus",
                          title: "Boost your words in the speech model",
                          detail: "One toggle in Dictionary makes recognition itself prefer your names and jargon while you dictate (Parakeet, English)."),
                Highlight(icon: "wand.and.stars",
                          title: "Learns from your corrections",
                          detail: "Say “scratch that” and redo a word, and Yappy offers to remember the fix — one tap to teach it, never applied silently."),
                Highlight(icon: "arrow.uturn.backward.circle",
                          title: "See and revert AI cleanup",
                          detail: "Every dictation keeps what you actually said — reveal or copy it in History, or say “use what I said” to swap it back in place."),
                Highlight(icon: "escape",
                          title: "Escape, polish, and real tone",
                          detail: "Esc now aborts before text lands, the pill shows when cleanup is polishing, and Formal/Casual tones genuinely shape the result.")
            ]),
        "2.3": Entry(
            version: "2.3",
            headline: "A fresh liquid-glass look, and multilingual dictation.",
            highlights: [
                Highlight(icon: "sparkles",
                          title: "A bespoke redesign",
                          detail: "The whole window was rebuilt on macOS 26’s Liquid Glass — a branded sidebar, glass cards, and settings that finally breathe."),
                Highlight(icon: "globe",
                          title: "Multilingual with Nemotron",
                          detail: "Switch the speech model to NVIDIA Nemotron for multilingual dictation, alongside the default English Parakeet — in Settings."),
                Highlight(icon: "command",
                          title: "Right Control hotkey",
                          detail: "Hold Right Control to dictate, in addition to Right Command and Right Option — pick your key in Settings."),
                Highlight(icon: "checkmark.bubble",
                          title: "Sharper self-correction",
                          detail: "“I’ll have the chicken, actually the salmon” now lands as just “the salmon”, even without a pause.")
            ])
    ]

    /// The running version's release notes, if any — for re-viewing the card on
    /// demand (the menu bar and Settings), separate from the once-after-update flow.
    static var current: Entry? { entries[currentVersion] }

    /// The highest-versioned entry, as a fallback when the running version has no
    /// notes of its own — so "What's New" always has something to show.
    static var latest: Entry? {
        entries.values.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    // MARK: - Decision

    /// Pure decision: which card (if any) to show, given the current version, the
    /// previously-seen version, and whether onboarding is done.
    ///
    /// Returns `nil` for a fresh install (`prior` empty/nil), when the version is
    /// unchanged, when onboarding hasn't completed, or when the landed-on version
    /// has no release notes.
    static func pending(current: String, prior: String?, onboardingComplete: Bool) -> Entry? {
        guard onboardingComplete,
              let prior, !prior.isEmpty,
              prior != current else { return nil }
        return entries[current]
    }

    /// Call once at launch. Reads the stored "last seen" version, advances it to
    /// the current version, and returns the card to show if the user just updated
    /// to a version that has release notes.
    static func pendingAfterLaunch(onboardingComplete: Bool,
                                   defaults: UserDefaults = .standard) -> Entry? {
        let prior = defaults.string(forKey: lastSeenKey)
        let current = currentVersion
        if !current.isEmpty { defaults.set(current, forKey: lastSeenKey) }
        return pending(current: current, prior: prior, onboardingComplete: onboardingComplete)
    }
}

/// Holds the What's New card to present, so `AppDelegate` (which decides at launch)
/// and the SwiftUI main window (which presents the sheet) stay decoupled.
@MainActor
final class WhatsNewPresenter: ObservableObject {
    @Published var entry: WhatsNew.Entry?
}
