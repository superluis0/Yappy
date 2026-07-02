//
//  AudioRecorder.swift
//  Yappy
//

import AVFoundation
import Foundation
import os

/// Captures microphone input with AVAudioEngine into an in-memory buffer of
/// 16 kHz mono Float32 samples — the format Parakeet expects — so transcription
/// can start the instant recording stops, with no temp files.
final class AudioRecorder {
    // MARK: - Properties

    /// Notice-level so device-change teardowns are persisted to the log store —
    /// a dictation that silently vanishes must leave a diagnosable trace.
    private static let logger = Logger(subsystem: "com.yappy.app", category: "audio")

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let samplesLock = NSLock()

    /// Samples handed off when an `AVAudioEngineConfigurationChange` (e.g. AirPods
    /// connecting, an input-device switch) forces us to tear the engine down
    /// mid-recording. The notification arrives on a non-main thread and ends
    /// capture before the user's key-up reaches `stopRecording()`, so the
    /// captured audio is preserved here — guarded by `samplesLock`, like
    /// `samples` — for the next `stopRecording()` to return instead of losing
    /// the whole utterance. `nil` whenever a recording ended normally.
    private var finishedEarlySamples: [Float]?
    private(set) var isRecording = false
    /// Level-only monitoring for the onboarding mic test; no samples are kept.
    private(set) var isPreviewing = false

    /// Throttled audio level callback for waveform visualization (called on main).
    var onAudioLevelUpdate: ((Float) -> Void)?

    /// Raw input buffer hook (native format) for the streaming transcription
    /// path. Called on the audio thread — keep work minimal.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var lastLevelUpdate: TimeInterval = 0

    private static let targetSampleRate: Double = 16000

    private let targetFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Permission

    /// Requests microphone access without blocking. Call once at launch so the
    /// first hotkey press can start recording immediately.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Warms the audio input pipeline so the FIRST recording starts promptly.
    /// `AVAudioEngine` initializes the HAL input device lazily on first use, which
    /// can take a second or more — that's the lag before the waveform appears on
    /// the first hotkey press after launch. Touching the input node + its format
    /// here forces that setup at launch instead. No audio is captured and the
    /// engine is never started/stopped, so this can't race on-device ML (the
    /// audio-vs-ANE crash invariant is preserved). Call once at launch, off the
    /// hot path. No-op without mic permission or while recording.
    func prewarm() {
        guard Self.hasPermission, !isRecording, !isPreviewing else { return }
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        if format.sampleRate > 0 { audioEngine.prepare() }
    }

    /// True if the clip contains real speech energy rather than silence or room
    /// tone. Guards against the brief near-silent recordings (a quick key tap)
    /// that make the speech model emit phantom filler words.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        guard samples.count >= 1600 else { return false } // < 0.1 s — nothing there
        var sumSquares: Float = 0
        var voiced = 0
        for sample in samples {
            sumSquares += sample * sample
            if abs(sample) > Constants.speechVoiceFloor { voiced += 1 }
        }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        // Count voiced samples against an ABSOLUTE floor (~0.15 s), not a
        // fraction of the whole clip: a fraction grows the speech required as
        // the hold lengthens, so a short real answer after a long silent hold
        // would be dropped. The RMS floor still rejects a brief loud click,
        // whose few voiced samples fall below this floor.
        let voicedFloor = Int(Constants.speechVoicedMinSeconds * Self.targetSampleRate)
        return rms >= Constants.speechRMSFloor && voiced >= voicedFloor
    }

    // MARK: - Recording

    /// Starts capturing. Returns false if permission is missing or the engine fails.
    func startRecording() -> Bool {
        guard !isRecording else { return false }
        guard Self.hasPermission else { return false }
        guard let targetFormat else { return false }

        // A real dictation always wins over the onboarding level preview.
        if isPreviewing {
            stopLevelPreview()
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return false
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return false
        }
        self.converter = converter

        samplesLock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.targetSampleRate) * 60)
        finishedEarlySamples = nil // drop any leftover early-handoff from a prior session
        samplesLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // The tap's buffer is only valid during this callback — the engine
            // reuses its memory afterward. The streaming consumer reads buffers
            // asynchronously, so it must get an owned copy. `process` runs here
            // synchronously and can use the live buffer directly.
            if let onBuffer = self.onBuffer, let copy = Self.copy(of: buffer) {
                onBuffer(copy)
            }
            self.process(buffer: buffer)
        }

        do {
            try audioEngine.start()
            isRecording = true
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            return false
        }
    }

    /// Stops capturing and returns the recorded 16 kHz mono samples.
    @discardableResult
    func stopRecording() -> [Float] {
        // A mid-recording device change (see `handleConfigurationChange`) already
        // tore the engine down and stashed everything captured up to that point.
        // Return that instead of the empty result the `isRecording` guard below
        // would otherwise give, so the key-up still transcribes what was heard.
        samplesLock.lock()
        if let earlySamples = finishedEarlySamples {
            finishedEarlySamples = nil
            samples.removeAll(keepingCapacity: false)
            samplesLock.unlock()
            return earlySamples
        }
        samplesLock.unlock()

        guard isRecording else { return [] }
        isRecording = false

        // Removing the tap first blocks until any in-flight tap callback finishes,
        // so no further samples are appended once it returns — the drain and
        // snapshot below then see a stable buffer.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()

        samplesLock.lock()
        drainConverterTailLocked()
        converter = nil
        let recorded = samples
        samples.removeAll(keepingCapacity: false)
        samplesLock.unlock()

        return recorded
    }

    // MARK: - Level Preview (onboarding mic test)

    /// Starts a level-only monitoring session: the tap feeds `onAudioLevelUpdate`
    /// but no audio is converted or stored. Used by onboarding's "Yappy is
    /// listening" waveform.
    @discardableResult
    func startLevelPreview() -> Bool {
        guard !isRecording, !isPreviewing, Self.hasPermission else { return false }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return false }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.emitLevel(from: buffer)
        }

        do {
            try audioEngine.start()
            isPreviewing = true
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            return false
        }
    }

    func stopLevelPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
    }

    // MARK: - Private

    /// Deep-copies a tap buffer so it can be safely used after the tap callback
    /// returns. Copies the raw audio buffer list, so it's format-agnostic.
    private static func copy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        copy.frameLength = source.frameLength

        let srcBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dstBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<srcBuffers.count {
            guard let src = srcBuffers[i].mData, let dst = dstBuffers[i].mData else { continue }
            let byteCount = Int(srcBuffers[i].mDataByteSize)
            memcpy(dst, src, byteCount)
            dstBuffers[i].mDataByteSize = srcBuffers[i].mDataByteSize
        }
        return copy
    }

    /// Handles a mid-session change to the audio graph — AirPods connecting or
    /// disconnecting, or any input-device switch, a routine macOS event. The
    /// engine stops delivering audio, so continuing to "record" would capture
    /// nothing; we tear the pipeline down fully and hand off whatever was
    /// captured so far.
    ///
    /// This notification is delivered on a **non-main** thread, so all shared
    /// state is touched under `samplesLock` (matching how the audio thread guards
    /// `samples`). The `isRecording` flag — a plain `Bool` read on the main thread
    /// — is flipped on the main queue so it stays serialized with those readers.
    @objc private func handleConfigurationChange() {
        // A change while previewing or idle is irrelevant; only a live recording
        // has captured audio to preserve. Read the flag under the lock.
        samplesLock.lock()
        let wasRecording = isRecording
        samplesLock.unlock()
        // Only act when the change actually STOPPED the engine (a real device
        // switch). This notification also fires benignly — including around the
        // engine's own start/format renegotiation — while audio keeps flowing;
        // tearing down on those killed every recording moments after it began
        // (the pill kept "listening" while the mic was dead). The engine-stopped
        // check is what distinguishes the two.
        guard wasRecording, !audioEngine.isRunning else { return }
        Self.logger.notice("Input device changed mid-recording; preserving captured audio")

        // Tear the engine down cleanly. `removeTap` blocks until any in-flight tap
        // callback returns, so no further samples are appended past this point —
        // making the drain + snapshot below race-free against the audio thread.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()

        // Drain the resampler tail (F20) and stash the full capture so the pending
        // key-up's stopRecording() returns it instead of an empty clip (F02).
        samplesLock.lock()
        drainConverterTailLocked()
        converter = nil
        finishedEarlySamples = samples
        samples.removeAll(keepingCapacity: false)
        samplesLock.unlock()

        // Flip the flag where the main thread reads it. The sample handoff above
        // is already visible via the lock, so ordering here doesn't lose audio.
        // Skip the write if a NEW session has already restarted the engine by the
        // time this lands — clearing its flag would silently kill that recording.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.audioEngine.isRunning else { return }
            self.isRecording = false
        }
    }

    /// Drains the sample-rate converter's internal tail into `samples`, so the
    /// last fraction of every clip isn't lost when the converter is discarded
    /// (F20). `AVAudioConverter` buffers input across `convert` calls; feeding it
    /// an `.endOfStream` signal and pulling once flushes those held frames.
    ///
    /// Mirrors the conversion in `process(buffer:)` but returns `.endOfStream`
    /// from the input block. Robust by design: on any converter error it leaves
    /// `samples` as-is — the main body of the recording is never lost, and it
    /// never crashes. Caller MUST hold `samplesLock`.
    private func drainConverterTailLocked() {
        guard let converter, let targetFormat else { return }

        // A generous tail capacity; the flush emits at most the converter's small
        // internal backlog, well under this.
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
            return
        }

        var signalled = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            // Report end-of-stream exactly once, then stop offering input so the
            // converter emits only its buffered tail.
            if signalled {
                outStatus.pointee = .noDataNow
                return nil
            }
            signalled = true
            outStatus.pointee = .endOfStream
            return nil
        }
        guard error == nil, let channelData = outputBuffer.floatChannelData else { return }

        let frameCount = Int(outputBuffer.frameLength)
        if frameCount > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let channelData = outputBuffer.floatChannelData else { return }

        let frameCount = Int(outputBuffer.frameLength)
        if frameCount > 0 {
            samplesLock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
            samplesLock.unlock()
        }

        emitLevel(from: buffer)
    }

    /// RMS level in 0...1, throttled to ~30 Hz on the main queue.
    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastLevelUpdate > 1.0 / 30.0 else { return }
        lastLevelUpdate = now

        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let data = UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))
        let rms = sqrt(data.reduce(0) { $0 + $1 * $1 } / Float(data.count))

        let avgPower = 20 * log10(max(rms, .leastNonzeroMagnitude))
        let minDb: Float = -60.0
        let normalized = max(0.0, min(1.0, (avgPower - minDb) / -minDb))

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevelUpdate?(normalized)
        }
    }
}
