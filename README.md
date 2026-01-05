# Yappy 🎤

**A blazingly fast voice-to-text macOS menu bar app powered by AI**

Yappy is a native macOS application that transcribes your voice in real-time using OpenAI's Whisper API and enhances the output with Grok AI via OpenRouter. Trigger recording with a customizable hotkey, speak naturally, and watch as your words appear instantly in any application.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

---

## ✨ Features

- **⚡ Ultra-Fast Transcription**: Optimized network layer and parallel processing for minimal latency
- **🎯 Global Hotkey Activation**: Double-tap or hold Right Command/Option - works anywhere on macOS
- **🎨 Beautiful Waveform Visualization**: Real-time animated audio level display during recording
- **🤖 AI-Powered Cleanup**: Optional Grok-based text enhancement (grammar, punctuation, filler word removal)
- **📝 Universal Text Insertion**: Works in any macOS app - TextEdit, Slack, browsers, terminals, etc.
- **🔒 Privacy-Focused**: Audio processed via API, no permanent storage
- **⚙️ Menu Bar Integration**: Unobtrusive, no dock icon, always accessible
- **🎛️ Customizable Settings**: Configure API keys, hotkeys, and cleanup behavior

---

## 🚀 Quick Start

### Prerequisites

- macOS 13.0 (Ventura) or later
- Xcode 14.0+ (for building from source)
- [OpenAI API key](https://platform.openai.com/api-keys)
- [OpenRouter API key](https://openrouter.ai/keys) (for text cleanup feature)

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/superluis0/Yappy.git
   cd Yappy
   ```

2. **Open in Xcode:**
   ```bash
   open Yappy.xcodeproj
   ```

3. **Build and Run:**
   - Select the "Yappy" scheme
   - Press `⌘R` or click the Run button

4. **Grant Permissions:**
   - **Microphone**: Required for audio recording (prompted automatically)
   - **Accessibility**: Required for global hotkey detection
     - System Settings → Privacy & Security → Accessibility → Add Yappy

5. **Configure API Keys:**
   - Click the Yappy menu bar icon
   - Click "Settings..."
   - Enter your OpenAI API key
   - Enter your OpenRouter API key
   - Choose your preferred hotkey option

---

## 🎯 Usage

1. **Start Recording:**
   - Double-tap Right ⌘ (default) or use your configured hotkey
   - A beautiful waveform overlay appears at the bottom of your screen

2. **Speak Clearly:**
   - Watch the waveform animate as you speak
   - Audio is captured in high-quality 16kHz mono WAV format

3. **Finish Recording:**
   - Double-tap Right ⌘ again (or release if using hold mode)
   - Processing animation shows while transcription happens

4. **Get Results:**
   - Transcribed text appears at your cursor position
   - Original clipboard is preserved
   - Waveform disappears automatically

### Hotkey Options

- **Double-tap Right ⌘** (Recommended): Tap twice quickly to start, tap twice again to stop
- **Hold Right ⌘**: Press and hold to record, release to finish
- **Hold Right ⌥**: Alternative for Right Option key

---

## 🏗️ Architecture

### Project Structure

```
Yappy/
├── App/
│   ├── YappyApp.swift              # SwiftUI app entry point
│   ├── AppDelegate.swift           # Main coordinator & flow control
│   └── TranscriptionService.swift  # Unified API service (Whisper + Grok)
│
├── Core/
│   ├── AppState.swift              # Observable app state management
│   ├── Settings.swift              # UserDefaults-backed settings
│   └── Constants.swift             # App-wide constants
│
├── Services/
│   ├── AudioRecorder.swift         # AVFoundation audio capture
│   ├── HotkeyManager.swift         # Global hotkey detection
│   ├── WhisperService.swift        # OpenAI Whisper API client
│   ├── GrokService.swift           # Grok cleanup API client
│   └── TextInserter.swift          # System-wide text insertion
│
├── UI/
│   ├── MenuBarView.swift           # Menu bar popover interface
│   ├── SettingsView.swift          # Settings window
│   ├── WaveformWindow.swift        # Floating overlay window
│   ├── WaveformView.swift          # Animated waveform visualization
│   └── VisualEffectBackground.swift # macOS blur effects
│
├── Utilities/
│   ├── AudioLevelProcessor.swift   # Audio level smoothing
│   └── KeyCodes.swift              # macOS virtual key codes
│
└── Resources/
    └── Assets.xcassets             # App icons & assets
```

### Technology Stack

- **Language**: Swift 5.9+
- **UI Framework**: SwiftUI + AppKit
- **Audio**: AVFoundation
- **Hotkeys**: CoreGraphics (CGEvent tap)
- **State Management**: Combine + ObservableObject
- **Networking**: URLSession with optimized configuration
- **APIs**: OpenAI Whisper, OpenRouter (Grok)

---

## ⚙️ Configuration

### Settings

Access settings by clicking the menu bar icon → "Settings..."

**API Keys:**
- OpenAI API Key (required) - Used for Whisper speech-to-text
- OpenRouter API Key (optional) - Used for Grok text cleanup

**Hotkey Options:**
- Right Command (Hold)
- Right Command (Double Tap) - Default
- Right Option (Hold)

**General:**
- Enable text cleanup - Toggle Grok-based enhancement
- Launch at login - Auto-start with macOS

**Permissions:**
- Real-time microphone and accessibility permission status
- Direct links to System Settings for easy configuration

### Performance Optimizations

Yappy is built for speed with:

- **Optimized URLSession Configuration**:
  - Ephemeral sessions for faster startup
  - HTTP/2 pipelining enabled
  - 6 concurrent connections per host
  - Reduced timeouts (15s request, 30s resource)

- **Efficient Audio Processing**:
  - 16kHz sample rate (Whisper-optimized)
  - Mono channel recording
  - Minimal buffer overhead

- **Smart Network Layer**:
  - Connection pooling and reuse
  - Automatic retry with backoff
  - Early error detection

---

## 🔐 Privacy & Security

- **No Data Storage**: Audio files are deleted immediately after transcription
- **API-Only Processing**: Audio sent to OpenAI/OpenRouter via HTTPS, not stored by Yappy
- **Local Settings**: API keys stored in UserDefaults (consider Keychain for production)
- **Clipboard Preservation**: Original clipboard restored after text insertion
- **Sandboxing Disabled**: Required for global hotkey and text insertion features

### API Key Security

⚠️ **Important**: Keep your API keys secure:
- Never commit API keys to version control
- Use environment variables or secure vaults in production
- Monitor API usage on OpenAI and OpenRouter dashboards
- Revoke and regenerate keys if compromised

---

## 🧪 Development

### Building from Source

```bash
# Clone the repository
git clone https://github.com/superluis0/Yappy.git
cd Yappy

# Open in Xcode
open Yappy.xcodeproj

# Build
# Press ⌘B in Xcode or:
xcodebuild -project Yappy.xcodeproj -scheme Yappy -configuration Release

# Run
# Press ⌘R in Xcode
```

### Project Requirements

- Xcode 14.0+
- macOS 13.0+ deployment target
- Swift 5.9+
- No external dependencies (uses only native frameworks)

### Code Quality

- Comprehensive inline documentation
- Error handling with typed errors
- ObservableObject pattern for reactive state
- Dependency injection for testability
- Memory-safe with weak references

---

## 📋 API Usage & Costs

### OpenAI Whisper API

- **Model**: `whisper-1`
- **Pricing**: ~$0.006 per minute of audio
- **Format**: WAV, 16kHz mono
- **Response**: Plain text or JSON

**Example 30-second recording**: ~$0.003

### OpenRouter (Grok)

- **Model**: `x-ai/grok-beta` (via OpenRouter)
- **Pricing**: Variable based on OpenRouter rates
- **Usage**: Optional text cleanup/enhancement
- **Can be disabled**: Set "Enable text cleanup" to OFF

---

## 🐛 Troubleshooting

### Common Issues

**App doesn't appear in menu bar**
- Check that LSUIElement is set to true in Info.plist
- Restart Yappy or log out and back in

**Hotkey not working**
- Grant Accessibility permission: System Settings → Privacy & Security → Accessibility
- Ensure no other app is using the same hotkey
- Try a different hotkey option in Settings

**"Invalid API key" error**
- Verify API keys are correct (no extra spaces)
- Check API key has sufficient credits
- Ensure API key has correct permissions

**Transcription fails**
- Check internet connection
- Verify microphone is working
- Ensure recording is at least 0.5 seconds
- Check OpenAI API status

**Text doesn't insert**
- Try clicking in the target application first
- Check Accessibility permissions
- Some sandboxed apps may have restrictions

---

## 📚 Documentation

- [BUILD_SUMMARY.md](BUILD_SUMMARY.md) - Complete implementation details
- [TESTING_GUIDE.md](TESTING_GUIDE.md) - Comprehensive testing checklist
- [INTEGRATION_EXAMPLE.md](INTEGRATION_EXAMPLE.md) - Code usage examples

---

## 🛣️ Roadmap

### Planned Features

- [ ] Local Whisper model support (offline mode)
- [ ] Multiple language support
- [ ] Recording history
- [ ] Custom Grok prompts
- [ ] Keyboard shortcut customization
- [ ] App icon and branding
- [ ] DMG installer
- [ ] iOS companion app

### Performance Improvements

- [ ] Parallel Whisper+Grok execution
- [ ] Streaming audio upload
- [ ] Predictive API warming
- [ ] Circular buffer for audio levels

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Guidelines

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

---

## 🙏 Acknowledgments

- **OpenAI** for the Whisper speech-to-text API
- **xAI** for Grok AI model
- **OpenRouter** for unified AI model access
- **Apple** for excellent native macOS frameworks

---

## 📬 Contact & Support

- **GitHub Issues**: [Report bugs or request features](https://github.com/superluis0/Yappy/issues)
- **Repository**: [github.com/superluis0/Yappy](https://github.com/superluis0/Yappy)

---

**Made with ❤️ using Swift and SwiftUI**

*Yappy - Because typing is so 2023* 🎤✨
