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

    func play(_ cue: Cue, volume: Float) {
        guard let sound = sound(for: cue) else { return }
        sound.volume = volume
        // A cached NSSound ignores play() while already playing; stop first so
        // rapid start/stop sessions never drop a cue.
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
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

    func playFile(url: URL, volume: Float, onFinish: @escaping @MainActor (Bool) -> Void) {
        stopFile()

        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            onFinish(false)
            return
        }

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

        if !sound.play() {
            delegate.finish(false)
        }
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
