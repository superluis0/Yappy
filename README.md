# Yappy 🎤

**A blazingly fast voice-to-text macOS menu bar app powered by AI**

Yappy is a native macOS application that transcribes your voice in real-time using OpenAI's Whisper API and enhances the output with Grok AI via OpenRouter. Trigger recording with a customizable hotkey, speak naturally, and watch as your words appear instantly in any application.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

---

## ✨ Features

### Core Features
- **⚡ Ultra-Fast Transcription**: Optimized network layer and parallel processing for minimal latency
- **🎯 Global Hotkey Activation**: Double-tap or hold Right Command/Option - works anywhere on macOS
- **🎨 Beautiful Waveform Visualization**: Real-time animated audio level display during recording
- **🤖 AI-Powered Cleanup**: Optional Grok-based text enhancement (grammar, punctuation, filler word removal)
- **📝 Universal Text Insertion**: Works in any macOS app - TextEdit, Slack, browsers, terminals, etc.
- **🔒 Privacy-Focused**: Audio processed via API, no permanent storage
- **⚙️ Menu Bar Integration**: Unobtrusive, no dock icon, always accessible
- **🎛️ Customizable Settings**: Configure API keys, hotkeys, and cleanup behavior

### Premium Features (New!)
- **🎙️ Voice Commands**: Say "delete that", "new line", "period", etc. for hands-free editing
- **✍️ Streaming Text**: Watch your words appear one-by-one at your cursor
- **🔊 Audio Feedback**: Subtle sounds for recording start/stop and actions
- **🎨 Custom Orange Waveform Icon**: Beautiful branded menu bar icon

---

## 🚀 Quick Start

### Prerequisites

- macOS 13.0 (Ventura) or later
- [OpenAI API key](https://platform.openai.com/api-keys)
- [OpenRouter API key](https://openrouter.ai/keys) (for text cleanup feature)

### Installation

#### From Pre-built App
1. Download the latest release from the Releases page
2. Drag Yappy.app to your Applications folder
3. Launch Yappy from Applications or Spotlight

#### Building from Source
```bash
# Clone the repository
git clone https://github.com/superluis0/Yappy.git
cd Yappy/Yappy

# Build
xcodebuild -project ../Yappy.xcodeproj -scheme Yappy -configuration Release build

# Install to Applications
cp -R ~/Library/Developer/Xcode/DerivedData/Yappy-*/Build/Products/Release/Yappy.app /Applications/

# Launch
open /Applications/Yappy.app
```

### Grant Permissions
After launching Yappy, grant these permissions:

1. **Microphone**: 
   - Try to record (triggers the permission prompt)
   - Or: System Settings → Privacy & Security → Microphone → Enable Yappy

2. **Accessibility** (required for hotkey & text insertion):
   - System Settings → Privacy & Security → Accessibility
   - Click **+** → Select **Yappy.app** → Enable

### Configure API Keys
1. Click the Yappy menu bar icon (orange waveform)
2. Click "Settings..."
3. Go to "API Keys" tab
4. Enter your OpenAI API key
5. Enter your OpenRouter API key
6. Click Save

---

## 🎯 Usage

### Basic Recording

1. **Start Recording**: Hold Right ⌘ (or your configured hotkey)
2. **Speak**: Watch the waveform animate as you speak
3. **Stop Recording**: Release the key
4. **Result**: Text appears at your cursor position

### Voice Commands (Optional)

Say these at the end of your dictation:
- **"delete that"** - Removes the text you just inserted
- **"new line"** - Inserts a line break
- **"new paragraph"** - Inserts two line breaks
- **"undo"** - Triggers Cmd+Z
- **"period" / "comma" / "question mark"** - Inserts punctuation

### Hotkey Options

Configure in Settings → General:
- **Hold Right ⌘** (Default): Press and hold to record, release to finish
- **Double-tap Right ⌘**: Tap twice to start, tap twice to stop
- **Hold Right ⌥**: Alternative using Right Option key

---

## ⚙️ Settings

### General Tab
- **Hotkey Selection**: Choose your preferred activation method
- **Launch at Login**: Start Yappy automatically
- **AI Transcription Cleanup**: Enable/disable Grok enhancement

### API Keys Tab
- **OpenAI API Key**: For Whisper speech-to-text
- **OpenRouter API Key**: For Grok text cleanup

### Permissions
- Direct links to System Settings for Microphone and Accessibility

---

## 🏗️ Architecture

### Project Structure

```
Yappy/
├── App/
│   ├── YappyApp.swift              # SwiftUI app entry point
│   ├── AppDelegate.swift           # Main coordinator & flow control
│   ├── SettingsView.swift          # Settings window UI
│   └── TranscriptionService.swift  # Unified API service
│
├── Core/
│   ├── AppState.swift              # Observable app state
│   ├── Settings.swift              # UserDefaults-backed settings
│   └── Constants.swift             # App-wide constants
│
├── Services/
│   ├── AudioRecorder.swift         # AVFoundation audio capture
│   ├── AudioFeedbackManager.swift  # Sound effects (NEW)
│   ├── StreamingTextInserter.swift # Word-by-word insertion (NEW)
│   ├── VoiceCommandProcessor.swift # Voice commands (NEW)
│   ├── WhisperService.swift        # OpenAI Whisper API
│   ├── GrokService.swift           # Grok cleanup API
│   └── TextInserter.swift          # Text insertion via paste
│
├── UI/
│   ├── WaveformView.swift          # Animated waveform
│   └── WaveformWindowController.swift
│
└── Resources/
    ├── AppIcon.icns                # App icon
    └── Sounds/                     # Audio feedback sounds
```

### Technology Stack

- **Language**: Swift 5.9+
- **UI Framework**: SwiftUI + AppKit
- **Audio**: AVFoundation
- **State Management**: Combine + ObservableObject
- **APIs**: OpenAI Whisper, OpenRouter (Grok)

---

## 🔐 Privacy & Security

- **No Data Storage**: Audio files deleted immediately after transcription
- **API-Only Processing**: Audio sent via HTTPS, not stored by Yappy
- **Local Settings**: Stored in UserDefaults
- **Clipboard Preservation**: Original clipboard restored after insertion

---

## 🐛 Troubleshooting

| Issue | Solution |
|-------|----------|
| App not in menu bar | Check if running: `pgrep Yappy` |
| Hotkey doesn't work | Enable Accessibility in System Settings |
| No transcription | Check API keys and Microphone permission |
| "Invalid API key" | Verify keys have no extra spaces |
| Text doesn't insert | Click in target app first, check Accessibility |

---

## 📋 API Costs

- **OpenAI Whisper**: ~$0.006 per minute of audio
- **OpenRouter (Grok)**: Variable, optional (can be disabled)

Example: 30-second recording ≈ $0.003

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

MIT License - see LICENSE file for details.

---

**Made with ❤️ using Swift and SwiftUI**

*Yappy - Because typing is so 2023* 🎤✨
