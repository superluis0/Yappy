//
//  SoundPlayer.swift
//  Yappy
//

import AppKit

/// Plays Yappy's bundled UI sound cues, falling back to system sounds if the
/// resources are missing. Sounds are cached so repeated cues don't re-read disk.
@MainActor
final class SoundPlayer {
    enum Cue: String {
        case recordStart = "record-start"
        case recordStop = "record-stop"
        case success
        /// Played when a dictation fails (transcription or insertion threw) so a
        /// failed session sounds distinct from a successful one. No bundled
        /// `record-fail.wav` ships today; the system fallback below is the cue.
        case failure = "record-fail"

        /// System-sound fallback when the bundled resource can't be loaded.
        var fallbackName: NSSound.Name? {
            switch self {
            case .recordStart: return "Tink"
            case .recordStop: return "Pop"
            case .success: return nil // silent fallback — better than a jarring beep
            // "Basso" is macOS's canonical low error thud: clearly reads as
            // "something went wrong" without the harshness of "Sosumi"/"Funk".
            case .failure: return "Basso"
            }
        }
    }

    private var cache: [Cue: NSSound] = [:]
    private var fileSound: NSSound?
    private var fileDelegate: FileSoundDelegate?
    private var warmupSound: NSSound?
    private(set) var lastPlaybackAt: Date?

    private static let warmupWAVData: Data = {
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples = Int(sampleRate) * 60 / 1000
        let dataSize = numSamples * 2
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            data.append(Data(bytes: &le, count: MemoryLayout<T>.size))
        }
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(numChannels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }()

    func play(_ cue: Cue, volume: Float) {
        guard let sound = sound(for: cue) else { return }
        sound.volume = volume
        // A cached NSSound ignores play() while already playing; stop first so
        // rapid start/stop sessions never drop a cue.
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
        lastPlaybackAt = Date()
    }

    func warmOutputDevice() {
        guard fileSound == nil else { return }
        guard let sound = NSSound(data: Self.warmupWAVData) else { return }
        sound.volume = 0.01
        warmupSound = sound
        if sound.play() {
            lastPlaybackAt = Date()
        }
    }

    private func sound(for cue: Cue) -> NSSound? {
        if let cached = cache[cue] {
            return cached
        }

        // Individually-copied resources land flat in Contents/Resources; check
        // there first, then the Sounds subdirectory for folder-reference setups.
        let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav")
            ?? Bundle.main.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "Sounds")

        let sound: NSSound?
        if let url {
            sound = NSSound(contentsOf: url, byReference: true)
        } else if let fallback = cue.fallbackName {
            sound = NSSound(named: fallback)
        } else {
            sound = nil
        }

        if let sound {
            cache[cue] = sound
        }
        return sound
    }

    func prepareFile(url: URL) -> NSSound? {
        NSSound(contentsOf: url, byReference: false)
    }

    func playPrepared(_ sound: NSSound, volume: Float, onFinish: @escaping @MainActor (Bool) -> Void) {
        stopFile()

        let delegate = FileSoundDelegate { [weak self, weak sound] finished in
            if self?.fileSound === sound {
                self?.fileSound = nil
                self?.fileDelegate = nil
            }
            onFinish(finished)
        }
        sound.volume = volume
        sound.delegate = delegate
        fileSound = sound
        fileDelegate = delegate

        if sound.play() {
            lastPlaybackAt = Date()
        } else {
            delegate.finish(false)
        }
    }

    func playFile(url: URL, volume: Float, onFinish: @escaping @MainActor (Bool) -> Void) {
        guard let sound = prepareFile(url: url) else {
            onFinish(false)
            return
        }

        playPrepared(sound, volume: volume, onFinish: onFinish)
    }

    func stopFile() {
        guard let sound = fileSound else { return }
        let delegate = fileDelegate
        sound.stop()
        delegate?.finish(false)
        fileSound = nil
        fileDelegate = nil
    }
}

private final class FileSoundDelegate: NSObject, NSSoundDelegate, @unchecked Sendable {
    private var didFinish = false
    private let onFinish: @MainActor (Bool) -> Void

    init(onFinish: @escaping @MainActor (Bool) -> Void) {
        self.onFinish = onFinish
    }

    func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        finish(finishedPlaying)
    }

    func finish(_ finished: Bool) {
        guard !didFinish else { return }
        didFinish = true
        let onFinish = onFinish
        Task { @MainActor in
            onFinish(finished)
        }
    }
}
