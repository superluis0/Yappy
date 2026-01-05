# Yappy Testing & Verification Guide

## ✅ Build Verification

### Opening the Project

```bash
cd /Users/luislanderos/Desktop/Yappy
open Yappy.xcodeproj
```

### Expected Build Results

The project should build successfully with:
- ✅ 17 Swift source files
- ✅ No compilation errors
- ✅ All dependencies resolved (native frameworks only)
- ✅ Proper entitlements configured
- ✅ Info.plist configured correctly

---

## 🧪 Phase-by-Phase Testing

### Phase 1-2: Foundation & State Management

**Test AppState:**
1. Create AppState instance
2. Verify initial values:
   - `isRecording = false`
   - `isProcessing = false`
   - `audioLevels` array has 40 zeros
   - `currentTranscription = ""`
3. Call `updateAudioLevel(0.5)`
4. Verify array shifted left and new value appended

**Test Settings:**
1. Create Settings instance
2. Set API keys
3. Verify `isConfigured` returns true
4. Verify UserDefaults persistence
5. Test hotkey option changes

**Expected Results:**
- ✅ State updates trigger UI refresh (ObservableObject)
- ✅ Settings persist across app restarts
- ✅ All computed properties work correctly

---

### Phase 3: Audio Recording

**Test AudioRecorder:**
1. Launch app and check microphone permission prompt
2. Grant permission
3. Call `startRecording(levelCallback:)`
4. Speak into microphone
5. Verify level callback fires ~60 times/sec
6. Verify levels are in 0.0-1.0 range
7. Call `stopRecording()`
8. Verify WAV file created in temp directory
9. Verify file is valid 16kHz mono WAV

**Test AudioLevelProcessor:**
1. Create processor
2. Feed sequence of raw levels
3. Verify smoothing works (no sudden jumps)
4. Verify levels stay in 0.0-1.0 range
5. Test `updateLevelArray` maintains 40 elements

**Expected Results:**
- ✅ Audio records in correct format (16kHz mono WAV)
- ✅ Level updates are smooth and responsive
- ✅ No audio artifacts or distortion
- ✅ Temp files cleaned up properly

---

### Phase 4: Hotkey Detection

**Test HotkeyManager:**

**Prerequisites:**
1. System Settings → Privacy & Security → Accessibility
2. Add Yappy to allowed apps

**Test Double-Tap Mode:**
1. Set `hotkeyOption = .rightCommandDoubleTap`
2. Tap right ⌘ twice quickly (<0.3s apart)
3. Verify `onActivate()` callback fires
4. While recording, tap right ⌘ twice again
5. Verify `onDeactivate()` callback fires

**Test Hold Mode:**
1. Set `hotkeyOption = .rightCommandHold`
2. Press and hold right ⌘
3. Verify `onActivate()` callback fires immediately
4. Release right ⌘
5. Verify `onDeactivate()` callback fires

**Test Right Option:**
1. Set `hotkeyOption = .rightOptionHold`
2. Repeat hold mode tests with right ⌥

**Edge Cases:**
- Left ⌘ should NOT trigger (only right ⌘)
- Very fast taps (>0.3s apart) should not activate
- Multiple quick taps should only activate once

**Expected Results:**
- ✅ Only right modifier keys trigger hotkey
- ✅ Double-tap timing is comfortable (~0.3s)
- ✅ No interference with system shortcuts
- ✅ Permission prompts guide user correctly

---

### Phase 5: API Services

**Test WhisperService:**

**Prerequisites:**
- Valid OpenAI API key in Settings

**Test Cases:**
1. Record short audio (2-3 seconds)
2. Get audio data
3. Call `transcribe(audioData:)`
4. Verify returned text matches speech
5. Test with empty audio data → should throw error
6. Test with invalid API key → should get clear error message

**Test GrokService:**

**Prerequisites:**
- Valid xAI API key in Settings

**Test Cases:**
1. Transcribe: "hello world this is a test"
2. Call `cleanup(text:)` with transcription
3. Verify result: "Hello world, this is a test." (proper caps/punctuation)
4. Test with empty string → should return empty
5. Test with invalid API key → should get clear error message

**Expected Results:**
- ✅ Transcription accuracy is good for clear speech
- ✅ Cleanup improves formatting noticeably
- ✅ Error messages are user-friendly
- ✅ Retry logic handles transient failures

---

### Phase 6: Text Insertion

**Test TextInserter:**

1. Open TextEdit with some text
2. Copy text to clipboard
3. Click in TextEdit to position cursor
4. Call `insert(text: "Hello from Yappy")`
5. Verify text appears at cursor position
6. Verify original clipboard restored after 100ms

**Edge Cases:**
- Insert into password field → should work
- Insert into terminal → should work
- Insert into browser → should work
- Insert with clipboard containing image → should preserve image after

**Expected Results:**
- ✅ Text appears in active application
- ✅ Original clipboard restored
- ✅ Works across all macOS apps
- ✅ No clipboard flicker visible to user

---

### Phase 7: Waveform UI

**Test WaveformWindow:**
1. Launch app
2. Trigger hotkey to start recording
3. Verify waveform window appears at bottom-center of screen
4. Verify window is click-through (can click behind it)
5. Verify translucent HUD appearance
6. Speak into microphone
7. Verify bars animate in real-time with speech
8. Stop recording
9. Verify "processing" animation (bars collapse/pulse)
10. Verify window fades out when done

**Multi-Display Test:**
1. If multiple monitors, move active window between them
2. Trigger hotkey
3. Verify waveform appears on correct screen

**Expected Results:**
- ✅ Waveform centered horizontally, 30px from bottom
- ✅ Bars animate smoothly with speech levels
- ✅ Processing animation is distinct from recording
- ✅ Window appears above full-screen apps
- ✅ No performance impact on other apps

---

### Phase 8: Menu Bar & Settings UI

**Test MenuBarView:**
1. Click menu bar icon
2. Verify popover appears
3. Verify status shows "Ready" (green) when idle
4. Start recording
5. Verify status shows "Recording" (red)
6. Stop and process
7. Verify status shows "Processing" (orange)
8. Verify warning appears if API keys missing
9. Click "Settings..." → should open settings window
10. Click "Quit" → should quit app

**Test SettingsView:**

**API Keys Section:**
1. Enter OpenAI API key → verify saved
2. Enter xAI API key → verify saved
3. Clear keys → verify warning in menu bar

**Hotkey Section:**
1. Select each hotkey option
2. Verify selection persists after restart
3. Test each option actually works

**General Section:**
1. Toggle "Enable text cleanup"
2. Verify setting saved
3. Record and verify cleanup applied/skipped accordingly
4. Toggle "Launch at login"
5. Verify SMAppService registers/unregisters

**Permissions Section:**
1. Check microphone status indicator
2. If denied, click "Request Permission"
3. Check accessibility status indicator
4. If denied, click "Open System Settings"
5. Verify status updates after granting permissions

**Expected Results:**
- ✅ All settings persist across restarts
- ✅ Permission status updates in real-time
- ✅ UI is responsive and polished
- ✅ Settings take effect immediately

---

### Phase 9: End-to-End Integration

**Complete Flow Test:**

1. **Setup:**
   - Enter API keys
   - Grant microphone permission
   - Grant accessibility permission
   - Select hotkey option

2. **Record & Transcribe:**
   - Open TextEdit
   - Position cursor
   - Trigger hotkey (double-tap or hold)
   - Speak clearly: "Testing Yappy transcription service"
   - Release/tap hotkey again
   - Wait for processing

3. **Verify:**
   - Text appears in TextEdit at cursor
   - Capitalization and punctuation correct
   - Waveform showed during recording
   - Processing animation showed during API calls
   - No errors or crashes

4. **Repeat in Different Apps:**
   - Safari address bar
   - Mail compose window
   - Terminal
   - Slack message field
   - VS Code editor

**Expected Results:**
- ✅ Transcription is accurate
- ✅ Text appears in correct location
- ✅ Works in all tested applications
- ✅ UI feedback is clear and responsive
- ✅ No lag or stuttering

---

## 🐛 Edge Cases to Verify

### Concurrent Operations
- [ ] Start recording while processing → should block with message
- [ ] Trigger hotkey rapidly multiple times → should handle gracefully
- [ ] Start recording, quit app → should clean up resources

### Short/Empty Recordings
- [ ] Record for <0.5 seconds → should discard without API call
- [ ] Record silence → should handle empty transcription
- [ ] Record but don't speak → should not paste empty text

### Permission Scenarios
- [ ] Launch without microphone permission → guide to settings
- [ ] Launch without accessibility permission → guide to settings
- [ ] Revoke permissions while running → graceful degradation
- [ ] Grant permissions while running → resume functionality

### API Failures
- [ ] Invalid OpenAI key → clear error message
- [ ] Invalid xAI key → clear error message
- [ ] Network offline → "Check internet" message
- [ ] API rate limit hit → appropriate error handling

### Multi-Display
- [ ] Record on primary display → waveform appears correctly
- [ ] Record on secondary display → waveform appears correctly
- [ ] Move between displays during recording → waveform follows

### System State
- [ ] Computer goes to sleep during recording → handle gracefully
- [ ] Screen locks during processing → complete processing
- [ ] Low disk space → handle temp file creation failure
- [ ] Low memory → degrade gracefully

---

## 📋 Final Checklist

### Functionality
- [ ] App launches as menu bar app (no dock icon)
- [ ] Status icon appears in menu bar
- [ ] All hotkey modes work correctly
- [ ] Audio recording works with good quality
- [ ] Transcription is accurate
- [ ] Text cleanup improves formatting
- [ ] Text insertion works in all apps
- [ ] Waveform visualization is smooth
- [ ] Settings persist correctly
- [ ] Permissions are requested properly

### Performance
- [ ] No lag when triggering hotkey
- [ ] Real-time waveform updates smoothly
- [ ] Transcription completes in reasonable time
- [ ] No memory leaks during extended use
- [ ] CPU usage is minimal when idle

### UI/UX
- [ ] Menu bar icon is clear and appropriate
- [ ] Waveform window is beautiful and unobtrusive
- [ ] Settings window is intuitive
- [ ] Error messages are helpful
- [ ] Status indicators are accurate
- [ ] Animations are smooth

### Robustness
- [ ] No crashes in normal use
- [ ] Errors are handled gracefully
- [ ] Resources are cleaned up properly
- [ ] Works across system restarts
- [ ] Handles permission denials well

---

## 🚀 Known Limitations

1. **Xcode Build Tool**: Currently requires full Xcode installation (not just Command Line Tools)
2. **API Keys Required**: Both OpenAI and xAI API keys needed for full functionality
3. **macOS Version**: Requires macOS 13.0+ (Ventura or later)
4. **Permissions**: Requires microphone and accessibility permissions
5. **Internet Required**: For API calls (offline mode not supported)

---

## 📝 Next Steps After Testing

1. Test with actual API keys
2. Verify all edge cases
3. Test on clean macOS install
4. Test with different microphone hardware
5. Verify multi-display support
6. Test all hotkey combinations
7. Measure performance under load
8. Test extended recording sessions
9. Verify memory usage is stable
10. Test integration with various apps

---

## 🎉 Success Criteria

The app is production-ready when:

✅ All functionality tests pass
✅ All edge cases are handled
✅ No crashes or errors in normal use
✅ UI is polished and responsive
✅ Performance is excellent
✅ Error messages are clear
✅ Permissions are handled well
✅ Works across all common macOS apps

---

**Yappy is ready for testing!** 🎤✨
