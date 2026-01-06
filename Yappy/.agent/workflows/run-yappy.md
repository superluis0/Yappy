---
description: build, install, and run Yappy
---

# Build and Run Yappy

This workflow builds Yappy, installs it to Applications, and launches it.

## Quick Update (After Code Changes)

// turbo-all

1. Quit Yappy if running:
```bash
pkill -x Yappy || true
```

2. Build Release version:
```bash
cd /Users/luislanderos/Desktop/Yappy/Yappy && xcodebuild -project ../Yappy.xcodeproj -scheme Yappy -configuration Release build 2>&1 | grep -E "(error:|warning:|BUILD)"
```

3. Install to Applications (with icons):
```bash
mkdir -p ~/Library/Developer/Xcode/DerivedData/Yappy-*/Build/Products/Release/Yappy.app/Contents/Resources && \
cp /Users/luislanderos/Desktop/Yappy/Yappy/AppIcon.icns ~/Library/Developer/Xcode/DerivedData/Yappy-*/Build/Products/Release/Yappy.app/Contents/Resources/ && \
cp /Users/luislanderos/Desktop/Yappy/Yappy/MenuBarIcon.png ~/Library/Developer/Xcode/DerivedData/Yappy-*/Build/Products/Release/Yappy.app/Contents/Resources/ && \
cp /Users/luislanderos/Desktop/Yappy/Yappy/MenuBarIcon@2x.png ~/Library/Developer/Xcode/DerivedData/Yappy-*/Build/Products/Release/Yappy.app/Contents/Resources/ && \
cp -R ~/Library/Developer/Xcode/DerivedData/Yappy-*/Build/Products/Release/Yappy.app /Applications/ && \
rm -rf ~/Library/Developer/Xcode/DerivedData/Yappy-*/Build/Products/*/Yappy.app
```

4. Launch Yappy:
```bash
open /Applications/Yappy.app
```

## First-Time Setup

After installing Yappy for the first time:

1. Click the Yappy icon in the menu bar (waveform icon, top-right)
2. Open **Settings**
3. Go to the **Permissions** section and grant all permissions:
   - **Microphone Access** - for voice recording
   - **Accessibility Access** - for hotkey detection and text insertion
4. Enter your API keys:
   - **OpenAI API Key** (for Whisper transcription)
   - **xAI API Key** (for Grok text cleanup)

## Usage

- **Hold Right Command** (default) to start recording
- **Release** to stop and transcribe
- Text appears at your cursor location

## Troubleshooting

| Issue | Solution |
|-------|----------|
| App not in menu bar | Check if running: `pgrep Yappy` |
| Hotkey doesn't work | Enable Accessibility in System Settings |
| No transcription | Check API keys and Microphone permission |
