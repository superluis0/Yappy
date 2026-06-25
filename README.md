<div align="center">

<img src="Documentation/assets/icon.png" alt="Yappy" width="128">

<img src="Documentation/assets/hero.png" alt="Yappy — talk, it types, everywhere on your Mac" width="820">

<h3>Voice-to-text for macOS that runs entirely on your Mac.</h3>

<p>Hold a key, speak, release — your words appear at the cursor in any app, usually in under a second.<br>
No API keys. No cloud. No subscriptions. Your voice never leaves the device.</p>

<p>
<img src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
<img src="https://img.shields.io/badge/Swift-5.9-FF6B35?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.9">
<img src="https://img.shields.io/badge/Engine-Parakeet%20on%20ANE-5b8cff?style=flat-square" alt="Parakeet on the Apple Neural Engine">
<img src="https://img.shields.io/badge/Privacy-100%25%20on--device-37d39a?style=flat-square" alt="100% on-device">
<img src="https://img.shields.io/badge/License-MIT-555?style=flat-square" alt="MIT License">
</p>

<p><b><a href="https://superluis0.github.io/Yappy/">Website</a></b> &nbsp;&middot;&nbsp; <b><a href="https://github.com/superluis0/Yappy/releases/latest">Download</a></b></p>

</div>

---

## Why Yappy

Most dictation apps stream your microphone to a server. Yappy doesn't. It runs NVIDIA's **Parakeet** speech model directly on the **Apple Neural Engine** (via [FluidAudio](https://github.com/FluidInference/FluidAudio)) — so transcription is fast, private, and works on a plane with the Wi‑Fi off.

It stays out of your way until you need it: a single global hotkey, a small recording pill that fades in only while you talk, and text that lands wherever your cursor already is — your editor, Slack, the browser, a terminal, anywhere.

<div align="center">
<img src="Documentation/assets/how-it-works.png" alt="Hold the hotkey, speak naturally, release — text lands at your cursor" width="820">
</div>

## A real app, not just a menu bar blip

Open Yappy and you land on a home that actually tells you something: how much time dictation has saved you, your stats and personal records, a heatmap of *when* you dictate, the apps you use it in most, and your searchable history — all stored locally.

<div align="center">
<img src="Documentation/assets/home.png" alt="Yappy home — time saved, stats, a when-you-dictate heatmap, top apps, and personal records" width="420">
</div>

Build dictation **modes** for different contexts — and teach Yappy the names and jargon it mishears, either by typing the spellings or training them with your voice so it learns how *it* hears you.

<div align="center">
<img src="Documentation/assets/modes.png" alt="Yappy modes — Auto, Email, Code, and Journal profiles" width="560">
</div>

<div align="center">
<img src="Documentation/assets/dictionary.png" alt="Yappy custom dictionary, showing the spellings it learned to correct" width="560">
</div>

Everything is configurable in one place — hotkey, sounds, number formatting, numbered lists, filler removal, spoken commands, spoken punctuation, voice editing, voice commands, Command Mode, Transforms, adaptive per-app modes, optional AI cleanup (with self-correction), and permissions.

<div align="center">
<img src="Documentation/assets/settings.png" alt="Yappy settings — hotkey, sounds, number formatting, filler removal, spoken commands, and voice editing" width="560">
</div>

## Features

**Local transcription** — Parakeet TDT 0.6B (English) on the Apple Neural Engine, roughly 120× real-time on Apple Silicon. The model downloads once (~443 MB) and never phones home again.

**Universal insertion** — pastes at the cursor in any app, including Electron apps, web views, and terminals where direct insertion fails. Your clipboard is snapshotted and restored, so nothing you copied gets clobbered.

**Numbers written the way you'd type them** — *"three thirty pm"* becomes `3:30 PM`, *"twenty dollars and fifty cents"* becomes `$20.50`, *"twenty twenty six"* becomes `2026`, *"twenty third"* becomes `23rd`, *"version eleven point six point zero"* becomes `11.6.0`. All local and deterministic — no LLM involved — and deliberately conservative, so *"wait a second"* and *"one in a million"* stay exactly as you said them.

**Spoken lists** — count off items and Yappy formats them: *"one milk two eggs three bread"* becomes a clean numbered list. Conservative by design — it only kicks in for a real run that starts at one, so a stray count inside a sentence stays put.

**Clean transcripts** — standalone fillers (*"um"*, *"uh"*) are stripped and the punctuation around them healed; say *"new line"* or *"new paragraph"* to insert real line breaks while you dictate. Both are toggles, and low-confidence noise decodes are discarded instead of inserted as garbage.

**Spoken punctuation** — dictate the marks you want: *"comma"*, *"period"*, *"question mark"*, *"open paren … close paren."* It matches whole words only, so plurals and embedded words are safe — and it's a toggle if you'd rather say those words literally.

**Command Mode** — select text anywhere, hold the command hotkey, and speak an instruction: *"make this concise"*, *"translate to Spanish"*, *"turn this into a bulleted list."* The selection is rewritten in place. Powered by on-device **Apple Intelligence** (macOS 26+) or a local **LM Studio** model; if neither is available, your text is left untouched.

**Backtrack** — change your mind mid-sentence and Yappy keeps the correction: *"let's meet at 2, actually 3"* lands as *"Let's meet at 3."* Part of the optional AI cleanup, so it rides along with whatever else cleanup is doing.

**Transforms** — reusable AI rewrites of selected text. Two ship built in — **Polish** (tighten for clarity) and **Prompt Engineer** (restructure into a clean AI prompt) — and you can add your own. Run one from the menu bar on any selection, or set one to run automatically after every dictation. Powered by on-device Apple Intelligence or your local LM Studio model.

**On-device AI cleanup** — polish transcripts with a local model that fixes punctuation, capitalization, and filler. Choose the engine in Settings: **Apple Intelligence** (fully on-device, macOS 26+, nothing to install), a local **LM Studio** model, or **Automatic** (Apple Intelligence when available, otherwise LM Studio). The same engine powers Command Mode, Transforms, and backtrack.

**Automatic updates** — Yappy keeps itself current via [Sparkle](https://sparkle-project.org), with EdDSA-signed releases verified before they're applied. No surprise dialogs: when a new version is ready a calm banner slides in over the window, an *Update to Yappy …* item appears at the top of the menu bar, and a dot marks the menu-bar icon — install on your own schedule with one click. After an update, a short *What's New* card recaps what changed. Check manually any time from the menu bar or **Settings → Software Update**.

**Voice editing** — fix what you just said, hands-free: *"scratch that"* undoes the last insertion, *"delete the last word"* trims it, *"all caps that"* / *"capitalize that"* recases it. It only fires on a whole-utterance command (so *"scratch that idea"* stays prose) and won't delete the wrong thing if your cursor has moved on.

**Voice commands** — drive the app by voice, spoken as their own utterance: *"switch to email mode"*, *"open scratchpad"*, *"new note."* Exact-match only (like voice editing), so a real dictation is never swallowed. A toggle.

**Dictation modes** — named profiles (Email, Code, Journal…) that bundle tone, AI-cleanup, formatting, and an extra vocabulary. Switch from the menu bar, or let a mode activate itself automatically for a kind of app. The built-in *Auto* mode follows your global settings — and, optionally, **learns**: it remembers the mode you last picked in each app and reapplies it there (an explicit pick still wins everywhere until you switch back to Auto).

**Voice shortcuts** — say a cue and Yappy expands it to canned text: an email signature, a calendar link, a block of boilerplate.

**Smart suggestions** — Yappy notices phrases you dictate over and over and offers, right on the home screen, to turn them into a shortcut — one click to add, or dismiss. Drawn entirely from your local history.

**Scratchpad** — a floating notepad a keystroke away (**⌥⇧S**), always on top like a sticky note. Jot or dictate into it without leaving whatever app you're in; notes are kept locally with a simple sidebar, and sync nowhere.

**Context-aware tone** — optional cleanup adapts to the app you're typing in: formal in Mail, casual in Messages, and strictly verbatim in code editors so nothing gets reworded.

**Custom dictionary** — teach Yappy your names, jargon, and acronyms. It comes pre-loaded with common developer and tool names — Supabase, Vercel, Cloudflare, Kubernetes, and more — so they transcribe right the first time. Add your own by typing the spellings it tends to mishear, or **train them by voice** — say a word a few times and Yappy learns how *it* hears you, then corrects those mishearings back to your spelling automatically. Deterministic and fully on-device; recordings are analyzed in memory and never saved.

**Activity at a glance** — a "time saved versus typing" headline, words-per-minute, streaks and personal records, a day-by-hour heatmap of when you dictate, the apps you use it in most, and a shareable *"Year in Voice"* recap.

**Polished hotkeys** — hold Right ⌘, double-tap Right ⌘, or hold Right ⌥. A debounced state machine ignores key repeats and accidental taps, so it never fires when you don't mean it. Press **Esc** mid-dictation to cancel cleanly.

**Considered details** — a molten-glass recording pill whose glow breathes with your voice, a menu bar icon that animates while recording, and subtle custom start/stop/done sounds.

**Private by design** — audio is transcribed on-device and never written to disk; no telemetry, no account. After the one-time model download, the only network traffic is to your own LM Studio on `localhost` (and only if you turn cleanup on). A privacy panel on the home screen reflects this state at a glance.

## Download

The easiest way to run Yappy — no Xcode required. macOS 14+ (Apple Silicon recommended).

1. Download the latest **`Yappy.dmg`** from the [**Releases**](https://github.com/superluis0/Yappy/releases/latest) page.
2. Open the DMG and drag **Yappy** into your **Applications** folder.
3. Double-click **Yappy** to launch it.

Yappy is signed with an Apple Developer ID and notarized by Apple, so it opens cleanly — no "unidentified developer" or "cannot check it for malicious software" warnings, and no terminal workarounds.

A short first-run flow walks you through the two permissions Yappy needs:

- **Microphone** — to hear you.
- **Accessibility** — to detect the hotkey and paste text.

Then hold **Right ⌘** anywhere and start talking.

## Build from source

Prefer to build it yourself? Requires Xcode 15+ and macOS 14+.

```bash
git clone https://github.com/superluis0/Yappy.git
cd Yappy
open Yappy.xcodeproj
```

Then press **Run** (⌘R) in Xcode — dependencies (FluidAudio) resolve automatically via Swift Package Manager on the first build.

> **Tip:** if another FluidAudio app (such as VoiceInk) has already downloaded Parakeet, Yappy reuses it from `~/Library/Application Support/FluidAudio/Models/` — no second download.

> **Maintainer shortcut:** `Scripts/rebuild-install.sh` rebuilds the Release app, verifies it's signed with the same Apple Developer ID as public releases (so Microphone/Accessibility grants survive across dev builds **and** Sparkle updates), and installs + relaunches it — refusing to install if the signature is wrong. Use `--test` to gate on the unit suite first, or `--build-only` to just verify a build. This requires the maintainer's Developer ID certificate.

> **Cutting a public release:** `Scripts/release-dmg.sh` builds a Developer ID–signed, notarized, stapled `Yappy.dmg` into `dist/` (the download that opens with no Gatekeeper warnings), and with `--publish <tag>` uploads it to a GitHub Release. Needs a one-time `notarytool` keychain profile — run `Scripts/release-dmg.sh --help` for setup. Maintainer-only.

## AI cleanup: on-device or LM Studio

Yappy can tidy up filler words, punctuation, and phrasing — and power Command Mode and Transforms — with a local LLM. Enable **AI Cleanup** under Settings and pick the **engine**:

- **Apple Intelligence** *(macOS 26+, recommended)* — fully on-device via Apple's Foundation Models. Nothing to install; just turn on Apple Intelligence in System Settings.
- **LM Studio** — a model you run locally in [LM Studio](https://lmstudio.ai) (start its server, default `http://localhost:1234`). Works on any supported macOS.
- **Automatic** — uses Apple Intelligence when it's available, otherwise falls back to LM Studio.

Everything stays on your machine — no API keys, no cloud. Cleanup degrades gracefully: if no engine is available, the raw transcript is inserted and nothing breaks.

## Privacy

- Audio is transcribed on-device and held only in memory — the recording itself is never written to disk.
- Your dictation history, shortcuts, and custom dictionary are stored locally in plain JSON under `~/Library/Application Support/Yappy/`, readable only by your macOS account. Clear your history anytime from the home window.
- No telemetry, no analytics, no account.
- The single one-time network request is the model download from Hugging Face. After that, Yappy runs fully offline (LM Studio calls, if enabled, stay on `localhost`).

## Architecture

| Area | Files | Role |
|------|-------|------|
| Transcription | `Services/ParakeetTranscriptionService.swift` | Loads & pre-warms Parakeet; batch transcription on release |
| Audio capture | `App/AudioRecorder.swift` | AVAudioEngine → in-memory 16 kHz mono Float32 |
| Hotkeys | `Services/HotkeyManager.swift` | One CGEvent tap + a pure, unit-tested state machine |
| Text insertion | `Services/TextInserter.swift` | Cmd+V paste with change-count-safe clipboard restore |
| Command Mode / cleanup / transforms | `Services/CleanupCoordinator.swift`, `FoundationModelsCleanupProvider.swift`, `LMStudioService.swift` | Routes cleanup, backtrack, Command Mode & transforms to on-device Apple Intelligence or local LM Studio; graceful fallback |
| Transcript formatting | `Services/TranscriptPipeline.swift` + `Spoken*Formatter.swift` | Fillers, numbers, lists, line breaks, punctuation — deterministic, on-device |
| Custom dictionary | `Core/DictionaryStore.swift`, `Core/BuiltInDictionary.swift` | Built-in dev terms + learned aliases corrected back to canonical spelling |
| Transforms | `Core/TransformStore.swift`, `UI/TransformsView.swift` | Named AI rewrites; menu-bar or auto-after-dictation |
| Scratchpad | `UI/ScratchpadController.swift`, `Core/NotesStore.swift` | Floating notepad (⌥⇧S) with local note storage |
| Pill & windows | `UI/` | Floating pill, home window, settings, onboarding |

## Tests

```bash
xcodebuild -project Yappy.xcodeproj -scheme Yappy test
```

Covers the hotkey state machine, settings persistence and migration, the transcript pipeline (numbers, lists, spoken punctuation), the custom dictionary and its built-in dev terms, transforms and notes stores, AI-cleanup prompt assembly, history-based shortcut suggestions, voice-command parsing, adaptive per-app mode resolution, dictation history and stats, voice-shortcut expansion, and app-context classification.

## Built with

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet, CoreML, and the Apple Neural Engine inference stack.
- [LM Studio](https://lmstudio.ai) — optional, local LLM cleanup.

## License

MIT — see [LICENSE](LICENSE).
