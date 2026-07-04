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
        let icon: String      // SF Symbol name
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
                          detail: "Nothing about dictation changed: audio never leaves your Mac. Answers sends only your typed-out question, only when you turn it on."),
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
                          detail: "Dictate into a floating scratchpad anytime with ⌥⇧S."),
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
                          detail: "Dictating a question now types the question instead of answering it, and on-device cleanup is quicker and more reliable."),
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
                          detail: "Esc now aborts before text lands, the pill shows when cleanup is polishing, and Formal/Casual tones genuinely shape the result."),
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
                          detail: "“I’ll have the chicken, actually the salmon” now lands as just “the salmon”, even without a pause."),
            ]),
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
