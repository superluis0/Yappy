//
//  AudioRecorder.swift
//  Yappy
//

import AVFoundation
import Foundation

/// Captures microphone input with AVAudioEngine into an in-memory buffer of
/// 16 kHz mono Float32 samples — the format Parakeet expects — so transcription
/// can start the instant recording stops, with no temp files.
final class AudioRecorder {
    // MARK: - Properties

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let samplesLock = NSLock()
    private(set) var isRecording = false

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

    // MARK: - Recording

    /// Starts capturing. Returns false if permission is missing or the engine fails.
    func startRecording() -> Bool {
        guard !isRecording else { return false }
        guard Self.hasPermission else { return false }
        guard let targetFormat else { return false }

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
        guard isRecording else { return [] }
        isRecording = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        converter = nil

        samplesLock.lock()
        let recorded = samples
        samples.removeAll(keepingCapacity: false)
        samplesLock.unlock()

        return recorded
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

    @objc private func handleConfigurationChange() {
        // Input device changed/unplugged mid-recording: stop cleanly.
        // The recorded samples up to this point remain available via stopRecording().
        if isRecording, !audioEngine.isRunning {
            isRecording = false
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
