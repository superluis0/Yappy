//
//  CommandCatalog.swift
//  Yappy
//

import Foundation

/// One phrase in the Commands cheat sheet: what to say, what it does, and
/// (optionally) a worked example. Phrases are mined verbatim from the parser
/// that recognizes them — never invented — so the catalog always matches what
/// the app actually understands.
struct CommandEntry {
    let phrase: String
    let effect: String
    let example: String?
    /// False for the few PHYSICAL actions (hold the hotkey, press Esc) listed
    /// for completeness in "Dictation basics". CommandsView renders those
    /// without the quoted-phrase chip so nobody tries to say them aloud.
    let isSpoken: Bool

    init(_ phrase: String, effect: String, example: String? = nil, isSpoken: Bool = true) {
        self.phrase = phrase
        self.effect = effect
        self.example = example
        self.isSpoken = isSpoken
    }
}

/// A group of related phrases, optionally gated behind a Settings toggle.
/// `settingsKeyPath` is nil when the behavior is always on (no toggle can
/// disable it).
struct CommandSection {
    let title: String
    let icon: String
    let settingsKeyPath: KeyPath<Settings, Bool>?
    let entries: [CommandEntry]
}

/// The full catalog of Yappy's built-in spoken phrases, grouped the way the
/// Commands tab and (collapsed) Settings section present them. Every phrase
/// here is copied verbatim from the parser that recognizes it:
/// `SpokenPunctuationFormatter`, `SpokenCommandFormatter`, `SpokenListFormatter`
/// (+ `SpokenBulletFormatter`), `SpokenNumberFormatter`, `VoiceEditCommandParser`,
/// `VoiceControlCommandParser`, `SubmitCommandParser`, and `AskCardCommand` /
/// `AskController.extractThinkHarder`.
enum CommandCatalog {
    /// Title of the Answers-card section. `CommandsView` hides this section
    /// entirely (not just an "Off" badge) when Answers is disabled — those
    /// card commands have no surface anywhere in the app until it's turned on,
    /// unlike the other sections' formatting/editing behavior.
    static let answersSectionTitle = "Answers"

    static let sections: [CommandSection] = [
        CommandSection(
            title: "Dictation basics",
            icon: "mic",
            settingsKeyPath: nil,
            entries: [
                CommandEntry("Hold your hotkey",
                              effect: "Starts recording — release to transcribe and insert the words at your cursor.",
                              isSpoken: false),
                CommandEntry("Release your hotkey",
                              effect: "Stops recording and inserts the cleaned-up text.",
                              isSpoken: false),
                CommandEntry("Press Esc",
                              effect: "Cancels the dictation before it lands — works while recording or while it's being polished.",
                              isSpoken: false),
            ]
        ),
        CommandSection(
            title: "Spoken punctuation",
            icon: "textformat",
            settingsKeyPath: \.spokenPunctuationEnabled,
            entries: [
                CommandEntry("comma", effect: "→ ,"),
                CommandEntry("period", effect: "→ . (also \u{201c}full stop\u{201d})"),
                CommandEntry("question mark", effect: "→ ?"),
                CommandEntry("exclamation mark", effect: "→ ! (also \u{201c}exclamation point\u{201d})"),
                CommandEntry("colon", effect: "→ :"),
                CommandEntry("semicolon", effect: "→ ;"),
                CommandEntry("hyphen", effect: "→ - (also \u{201c}dash\u{201d})"),
                CommandEntry("apostrophe", effect: "→ '"),
                CommandEntry("ellipsis", effect: "→ …"),
                CommandEntry("open paren", effect: "→ ( (also \u{201c}parenthesis\u{201d}, \u{201c}parentheses\u{201d})"),
                CommandEntry("close paren", effect: "→ ) (also \u{201c}parenthesis\u{201d}, \u{201c}parentheses\u{201d}, \u{201c}closed paren\u{201d})"),
                CommandEntry("open quote", effect: "→ \u{201c}"),
                CommandEntry("close quote", effect: "→ \u{201d} (also \u{201c}end quote\u{201d}, \u{201c}closed quote\u{201d})"),
                CommandEntry("open bracket", effect: "→ ["),
                CommandEntry("close bracket", effect: "→ ]"),
                CommandEntry("forward slash", effect: "→ /"),
                CommandEntry("em dash", effect: "→ —"),
            ]
        ),
        CommandSection(
            title: "Formatting",
            icon: "arrow.turn.down.left",
            settingsKeyPath: \.spokenCommandsEnabled,
            entries: [
                CommandEntry("new line",
                              effect: "Inserts a line break (also \u{201c}next line\u{201d}, \u{201c}line break\u{201d}, \u{201c}insert line\u{201d})"),
                CommandEntry("new paragraph",
                              effect: "Inserts a paragraph break (also \u{201c}next paragraph\u{201d}, \u{201c}skip a line\u{201d})"),
            ]
        ),
        CommandSection(
            title: "Spoken numbers",
            icon: "textformat.123",
            settingsKeyPath: \.numberFormattingEnabled,
            entries: [
                CommandEntry("eleven point six",
                              effect: "Spoken numbers become digits",
                              example: "→ \u{201c}11.6\u{201d}"),
            ]
        ),
        CommandSection(
            title: "Spoken lists",
            icon: "list.number",
            settingsKeyPath: \.numberedListsEnabled,
            entries: [
                CommandEntry("one milk two eggs three bread",
                              effect: "Three or more counted items become a numbered list",
                              example: "→ \u{201c}1. Milk\n2. Eggs\n3. Bread\u{201d}"),
                CommandEntry("bullet milk bullet eggs bullet bread",
                              effect: "Two or more \u{201c}bullet\u{201d} items become a bulleted list",
                              example: "→ \u{201c}- Milk\n- Eggs\n- Bread\u{201d}"),
            ]
        ),
        CommandSection(
            title: "Voice editing",
            icon: "eraser",
            settingsKeyPath: \.voiceEditingEnabled,
            entries: [
                CommandEntry("scratch that",
                              effect: "Deletes your last dictation (also \u{201c}scratch this\u{201d}, \u{201c}delete that\u{201d}, \u{201c}delete this\u{201d}, \u{201c}remove that\u{201d})"),
                CommandEntry("delete the last word",
                              effect: "Deletes just the last word (also \u{201c}delete last word\u{201d})"),
                CommandEntry("delete the last sentence",
                              effect: "Deletes the last sentence (also \u{201c}delete last sentence\u{201d})"),
                CommandEntry("delete the last line",
                              effect: "Deletes the last line (also \u{201c}delete last line\u{201d})"),
                CommandEntry("capitalize that",
                              effect: "Title-cases the last dictation (also \u{201c}cap that\u{201d}, \u{201c}capitalize this\u{201d}, \u{201c}cap this\u{201d})"),
                CommandEntry("all caps that",
                              effect: "Uppercases the last dictation (also \u{201c}all caps this\u{201d}, \u{201c}uppercase that\u{201d}, \u{201c}make that uppercase\u{201d}, \u{201c}make that all caps\u{201d})"),
                CommandEntry("lowercase that",
                              effect: "Lowercases the last dictation (also \u{201c}lowercase this\u{201d}, \u{201c}make that lowercase\u{201d})"),
                CommandEntry("use what i said",
                              effect: "Reverts to the pre-cleanup words (also \u{201c}use what i actually said\u{201d}, \u{201c}undo the cleanup\u{201d}, \u{201c}undo that cleanup\u{201d})"),
            ]
        ),
        CommandSection(
            title: "Voice commands",
            icon: "command",
            settingsKeyPath: \.voiceControlEnabled,
            entries: [
                CommandEntry("switch to [mode] mode",
                              effect: "Activates a Mode by name (also \u{201c}use [mode] mode\u{201d}, or just \u{201c}[mode] mode\u{201d})",
                              example: "\u{201c}switch to writing mode\u{201d}"),
                CommandEntry("auto mode",
                              effect: "Returns to Auto mode (also \u{201c}switch to auto mode\u{201d}, \u{201c}use auto mode\u{201d})"),
                CommandEntry("open scratchpad",
                              effect: "Opens the floating scratchpad (also \u{201c}show scratchpad\u{201d}, \u{201c}open notes\u{201d}, \u{201c}show notes\u{201d})"),
                CommandEntry("new note",
                              effect: "Starts a fresh scratchpad note (also \u{201c}new scratchpad note\u{201d}, \u{201c}create a note\u{201d}, \u{201c}create a new note\u{201d})"),
            ]
        ),
        CommandSection(
            title: "Submit",
            icon: "return",
            settingsKeyPath: nil,
            entries: [
                CommandEntry("press enter",
                              effect: "Sends Return after the dictation lands (also \u{201c}press return\u{201d}, \u{201c}hit enter\u{201d}, \u{201c}hit return\u{201d})"),
            ]
        ),
        CommandSection(
            title: answersSectionTitle,
            icon: "questionmark.bubble",
            settingsKeyPath: \.askEnabled,
            entries: [
                CommandEntry("copy that",
                              effect: "Copies the answer to the clipboard (also \u{201c}copy it\u{201d}, \u{201c}copy the answer\u{201d})"),
                CommandEntry("insert that",
                              effect: "Types the answer at your cursor (also \u{201c}insert it\u{201d}, \u{201c}insert the answer\u{201d}, \u{201c}type that\u{201d})"),
                CommandEntry("pin that",
                              effect: "Keeps the answer card open (also \u{201c}pin it\u{201d}, \u{201c}keep that\u{201d})"),
                CommandEntry("dismiss",
                              effect: "Closes the answer card (also \u{201c}close\u{201d}, \u{201c}dismiss that\u{201d}, \u{201c}close that\u{201d})"),
                CommandEntry("try again",
                              effect: "Re-asks the question (also \u{201c}ask again\u{201d}, \u{201c}retry\u{201d})"),
                CommandEntry("read that",
                              effect: "Reads the answer aloud (also \u{201c}read it\u{201d}, \u{201c}speak that\u{201d}, \u{201c}read that aloud\u{201d}, \u{201c}say it aloud\u{201d}, \u{201c}read the answer\u{201d})"),
                CommandEntry("stop talking",
                              effect: "Stops the read-aloud (also \u{201c}stop reading\u{201d}, \u{201c}stop speaking\u{201d})"),
                CommandEntry("think harder",
                              effect: "Prefix that asks for a slower, more thorough answer (also \u{201c}think hard\u{201d})",
                              example: "\u{201c}think harder, what's the fastest sort for this?\u{201d}"),
            ]
        ),
    ]
}
