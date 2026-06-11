<div align="center">

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

</div>

---

## Why Yappy

Most dictation apps stream your microphone to a server. Yappy doesn't. It runs NVIDIA's **Parakeet** speech model directly on the **Apple Neural Engine** (via [FluidAudio](https://github.com/FluidInference/FluidAudio)) — so transcription is fast, private, and works on a plane with the Wi‑Fi off.

It stays out of your way until you need it: a single global hotkey, a small recording pill that fades in only while you talk, and text that lands wherever your cursor already is — your editor, Slack, the browser, a terminal, anywhere.

<div align="center">
<img src="Documentation/assets/how-it-works.png" alt="Hold the hotkey, speak naturally, release — text lands at your cursor" width="820">
</div>

## A real app, not just a menu bar blip

Open Yappy and you land on a home that actually tells you something: how much time dictation has saved you, your stats, a heatmap of *when* you dictate, the apps you use it in most, and your searchable history — all stored locally.

<div align="center">
<img src="Documentation/assets/home.png" alt="Yappy home — time saved, stats, a when-you-dictate heatmap, top apps, and searchable history" width="640">
</div>

Everything is configurable in one place — hotkeys, Command Mode, optional AI cleanup, and permissions.

<div align="center">
<img src="Documentation/assets/settings.png" alt="Yappy settings — hotkeys, Command Mode, AI cleanup, and permissions" width="640">
</div>

## Features

**Local transcription** — Parakeet TDT 0.6B (English) on the Apple Neural Engine, roughly 120× real-time on Apple Silicon. The model downloads once (~443 MB) and never phones home again.

**Universal insertion** — pastes at the cursor in any app, including Electron apps, web views, and terminals where direct insertion fails. Your clipboard is snapshotted and restored, so nothing you copied gets clobbered.

**Numbers written the way you'd type them** — *"three thirty pm"* becomes `3:30 PM`, *"twenty dollars and fifty cents"* becomes `$20.50`, *"twenty twenty six"* becomes `2026`, *"twenty third"* becomes `23rd`, *"version eleven point six point zero"* becomes `11.6.0`. All local and deterministic — no LLM involved — and deliberately conservative, so *"wait a second"* and *"one in a million"* stay exactly as you said them.

**Clean transcripts** — standalone fillers (*"um"*, *"uh"*) are stripped and the punctuation around them healed; say *"new line"* or *"new paragraph"* to insert real line breaks while you dictate. Both are toggles, and low-confidence noise decodes are discarded instead of inserted as garbage.

**Command Mode** — select text anywhere, hold the command hotkey, and speak an instruction: *"make this concise"*, *"translate to Spanish"*, *"turn this into a bulleted list."* The selection is rewritten in place. Powered by a local LM Studio model; if it isn't running, your text is left untouched.

**Voice editing** — fix what you just said, hands-free: *"scratch that"* undoes the last insertion, *"delete the last word"* trims it, *"all caps that"* / *"capitalize that"* recases it. It only fires on a whole-utterance command (so *"scratch that idea"* stays prose) and won't delete the wrong thing if your cursor has moved on.

**Dictation modes** — named profiles (Email, Code, Journal…) that bundle tone, AI-cleanup, formatting, and an extra vocabulary. Switch from the menu bar, or let a mode activate itself automatically for a kind of app. The built-in *Auto* mode just follows your global settings.

**Voice shortcuts** — say a cue and Yappy expands it to canned text: an email signature, a calendar link, a block of boilerplate.

**Context-aware tone** — optional cleanup adapts to the app you're typing in: formal in Mail, casual in Messages, and strictly verbatim in code editors so nothing gets reworded.

**Custom dictionary** — teach Yappy your names, jargon, and acronyms. Type the spellings it tends to mishear, or **train them by voice** — say a word a few times and Yappy learns how *it* hears you, then corrects those mishearings back to your spelling automatically. Deterministic and fully on-device; recordings are analyzed in memory and never saved.

**Activity at a glance** — a "time saved versus typing" headline, words-per-minute, streaks and personal records, a day-by-hour heatmap of when you dictate, the apps you use it in most, and a shareable *"Year in Voice"* recap.

**Polished hotkeys** — hold Right ⌘, double-tap Right ⌘, or hold Right ⌥. A debounced state machine ignores key repeats and accidental taps, so it never fires when you don't mean it. Press **Esc** mid-dictation to cancel cleanly.

**Considered details** — a molten-glass recording pill whose glow breathes with your voice, a menu bar icon that animates while recording, and subtle custom start/stop/done sounds.

**Private by design** — audio is transcribed on-device and never written to disk; no telemetry, no account. After the one-time model download, the only network traffic is to your own LM Studio on `localhost` (and only if you turn cleanup on). A privacy panel on the home screen reflects this state at a glance.

## Quick start

Requires Xcode 15+ and macOS 14+ (Apple Silicon recommended).

```bash
git clone https://github.com/superluis0/Yappy.git
cd Yappy
xcodebuild -project Yappy.xcodeproj -scheme Yappy -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/Yappy-*/Build/Products/Release/Yappy.app /Applications/
open /Applications/Yappy.app
```

A short first-run flow walks you through the two permissions Yappy needs:

- **Microphone** — to hear you.
- **Accessibility** — to detect the hotkey and paste text.

Then hold **Right ⌘** anywhere and start talking.

> **Tip:** if another FluidAudio app (such as VoiceInk) has already downloaded Parakeet, Yappy reuses it from `~/Library/Application Support/FluidAudio/Models/` — no second download.

## Optional: AI cleanup with LM Studio

Yappy can tidy up filler words and punctuation, and power Command Mode, using a model you run locally in [LM Studio](https://lmstudio.ai) — entirely offline, no API keys.

1. Open LM Studio, load a model, and start its local server (default `http://localhost:1234`).
2. In Yappy → Settings, enable **AI Cleanup** and pick the model.

If LM Studio isn't reachable, dictation degrades gracefully: the raw transcript is inserted and nothing breaks.

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
| Command Mode / cleanup | `Services/LMStudioService.swift` | Local OpenAI-compatible calls; graceful fallback |
| Custom dictionary | `Core/DictionaryStore.swift` | Terms fed to FluidAudio CTC vocabulary boosting |
| Pill & windows | `UI/` | Floating pill, home window, settings, onboarding |

## Tests

```bash
xcodebuild -project Yappy.xcodeproj -scheme Yappy test
```

Covers the hotkey state machine, settings persistence and migration, dictation history and stats, voice-shortcut expansion, and app-context classification.

## Built with

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet, CoreML, and the Apple Neural Engine inference stack.
- [LM Studio](https://lmstudio.ai) — optional, local LLM cleanup.

## License

MIT — see [LICENSE](LICENSE).
