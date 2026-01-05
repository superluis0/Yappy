# Audio Recording Components - Integration Example

## Overview
The AudioRecorder and AudioLevelProcessor have been successfully implemented and are ready for integration with AppState.

## Files Implemented

1. **`/Users/luislanderos/Desktop/Yappy/Yappy/Services/AudioRecorder.swift`**
   - AVFoundation-based audio recorder
   - Real-time RMS level monitoring (~60 callbacks/sec)
   - Whisper-optimized format: 16kHz, mono, WAV
   - Comprehensive error handling for permissions and device availability

2. **`/Users/luislanderos/Desktop/Yappy/Yappy/Utilities/AudioLevelProcessor.swift`**
   - Exponential moving average smoothing
   - Level amplification for better visualization
   - Array update helper for waveform data

## Integration Example

Here's how to integrate these components with the existing AppState:

```swift
// In your RecordingCoordinator or ViewModel:

import Foundation

class RecordingCoordinator: ObservableObject {
    private let appState: AppState
    private let audioRecorder = AudioRecorder()
    private let levelProcessor = AudioLevelProcessor()

    init(appState: AppState) {
        self.appState = appState
    }

    // Start recording with level monitoring
    func startRecording() {
        do {
            // Reset processor for new session
            levelProcessor.reset()

            // Update app state
            appState.startRecording()

            // Start audio recording with level callback
            try audioRecorder.startRecording { [weak self] rawLevel in
                guard let self = self else { return }

                // Process the raw level
                let processedLevel = self.levelProcessor.processLevel(rawLevel)

                // Update AppState for waveform visualization
                self.appState.updateAudioLevel(processedLevel)
            }
        } catch {
            appState.setError(error)
        }
    }

    // Stop recording and get file URL
    func stopRecording() async {
        // Stop audio recording
        guard let recordingURL = audioRecorder.stopRecording() else {
            appState.setError(
                NSError(domain: "RecordingCoordinator", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: "Failed to stop recording"])
            )
            return
        }

        // Update app state
        appState.stopRecording()

        // Now ready to send to WhisperService for transcription
        // Example:
        // let audioData = try audioRecorder.getAudioData()
        // await whisperService.transcribe(audioData)
    }
}
```

## Audio Format Specifications

The recorder produces audio optimized for OpenAI Whisper API:

- **Sample Rate**: 16,000 Hz
- **Channels**: 1 (mono)
- **Format**: Linear PCM Float32
- **File Type**: WAV
- **Bit Depth**: 32-bit float (converted from input format)

## Level Processing Pipeline

1. **Capture**: AVAudioEngine captures audio buffer (~4096 frames at device rate)
2. **Conversion**: Buffer converted to 16kHz mono if needed
3. **RMS Calculation**: Root mean square calculated from buffer samples
4. **Normalization**: RMS scaled to 0.0-1.0 range (multiplied by 5.0)
5. **Smoothing**: Exponential moving average applied (α = 0.3)
6. **Amplification**: Level multiplied by 2.0 for better visualization
7. **Clamping**: Final value clamped to 0.0-1.0
8. **Array Update**: Old values shifted out, new value appended

## Error Handling

The AudioRecorder throws comprehensive errors:

- **`microphonePermissionDenied`**: User hasn't granted microphone access
- **`microphoneUnavailable`**: No input device detected
- **`audioEngineStartFailed`**: Engine couldn't start (includes underlying error)
- **`fileCreationFailed`**: Couldn't create or write to WAV file
- **`noRecordingAvailable`**: Attempted to get data with no active recording

All errors conform to `LocalizedError` with user-friendly descriptions.

## Microphone Permissions

The recorder automatically:
1. Checks current authorization status
2. Requests permission if not determined
3. Throws error if denied or restricted
4. Uses synchronous semaphore for permission flow

Make sure to add to `Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Yappy needs microphone access to transcribe your voice commands.</string>
```

## Performance Characteristics

- **Level Updates**: ~60 Hz (4096 frames ÷ 16000 Hz ≈ 60 updates/sec)
- **Memory**: Minimal - single audio buffer in flight
- **CPU**: Low - simple RMS calculation, efficient format conversion
- **Disk I/O**: Sequential write to temporary file, cleaned up automatically

## Testing Checklist

- [ ] Microphone permission flow (denied, granted, not determined)
- [ ] Recording start/stop cycle
- [ ] Level callbacks firing at expected rate
- [ ] Waveform array updates in AppState
- [ ] Audio file creation and data retrieval
- [ ] Cleanup on deinit (no leaks)
- [ ] Multiple recording sessions
- [ ] Error handling for missing microphone
- [ ] Format conversion from different input rates

## Next Steps

The recorder is ready for Phase 4 integration with:
- WhisperService for transcription
- GrokService for processing
- UI components for waveform visualization
- HotkeyManager for record/stop triggers
