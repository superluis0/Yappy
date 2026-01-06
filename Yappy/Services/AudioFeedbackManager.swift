//
//  AudioFeedbackManager.swift
//  Yappy
//
//  Created on 2026-01-05.
//

import Foundation
import AVFoundation

/// Sound events that trigger audio feedback throughout the application.
enum SoundEvent {
    /// Recording has started - soft activation tone
    case recordingStarted
    /// Recording has stopped - confirmation tone
    case recordingStopped
    /// Text has been successfully inserted - success chime
    case textInserted
    /// Voice command was executed - quick blip
    case commandExecuted
    /// An error occurred - gentle alert
    case error
    
    /// The sound file name (without extension) in the bundle
    var fileName: String {
        switch self {
        case .recordingStarted: return "start"
        case .recordingStopped: return "stop"
        case .textInserted: return "insert"
        case .commandExecuted: return "command"
        case .error: return "error"
        }
    }
}

/// Manages premium audio feedback for Yappy.
/// Plays short, bespoke sounds for various application events.
final class AudioFeedbackManager {
    // MARK: - Properties
    
    /// Whether audio feedback is enabled
    var isEnabled: Bool = true
    
    /// Volume level for sound playback (0.0 - 1.0)
    var volume: Float = 0.5 {
        didSet {
            volume = max(0.0, min(1.0, volume))
        }
    }
    
    // MARK: - Private Properties
    
    /// Cache of preloaded audio players for instant playback
    private var audioPlayers: [SoundEvent: AVAudioPlayer] = [:]
    
    /// Fallback system sounds when custom sounds aren't available
    private let fallbackSystemSounds: [SoundEvent: NSSound.Name] = [
        .recordingStarted: .pop,
        .recordingStopped: .tink,
        .textInserted: .glass,
        .commandExecuted: .morse,
        .error: .basso
    ]
    
    // MARK: - Initialization
    
    init() {
        preloadSounds()
    }
    
    // MARK: - Public Methods
    
    /// Plays the audio feedback for the specified event.
    ///
    /// - Parameter event: The sound event to play.
    func play(_ event: SoundEvent) {
        guard isEnabled else { return }
        
        // Try custom sound first
        if let player = audioPlayers[event] {
            player.volume = volume
            player.currentTime = 0  // Reset to beginning
            player.play()
            return
        }
        
        // Fall back to system sound with volume adjustment
        playSystemSound(for: event)
    }
    
    /// Preloads all sound files for instant playback.
    /// Call this during app initialization to avoid latency on first play.
    func preloadSounds() {
        for event in [SoundEvent.recordingStarted, .recordingStopped, .textInserted, .commandExecuted, .error] {
            if let player = createPlayer(for: event) {
                player.prepareToPlay()
                audioPlayers[event] = player
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// Creates an AVAudioPlayer for the specified sound event.
    ///
    /// - Parameter event: The sound event to create a player for.
    /// - Returns: An AVAudioPlayer instance, or nil if the sound file is not found.
    private func createPlayer(for event: SoundEvent) -> AVAudioPlayer? {
        // Try to find custom sound file in bundle
        let extensions = ["wav", "aif", "aiff", "mp3", "m4a"]
        
        for ext in extensions {
            if let url = Bundle.main.url(forResource: event.fileName, withExtension: ext) {
                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    return player
                } catch {
                    print("AudioFeedbackManager: Failed to create player for \(event.fileName).\(ext): \(error)")
                }
            }
        }
        
        return nil
    }
    
    /// Plays a system sound as fallback when custom sounds aren't available.
    ///
    /// - Parameter event: The sound event to play.
    private func playSystemSound(for event: SoundEvent) {
        guard let soundName = fallbackSystemSounds[event] else { return }
        
        if let sound = NSSound(named: soundName) {
            sound.volume = volume
            sound.play()
        }
    }
}

// MARK: - Convenience Extension

extension AudioFeedbackManager {
    /// Plays a sound only if a condition is met.
    ///
    /// - Parameters:
    ///   - event: The sound event to play.
    ///   - condition: A condition that must be true for the sound to play.
    func play(_ event: SoundEvent, if condition: Bool) {
        guard condition else { return }
        play(event)
    }
}
