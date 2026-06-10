// Generates Yappy's UI sound cues as 44.1 kHz 16-bit mono WAVs.
// One-off tool, not part of any build target. Run from the repo root:
//
//   swift Scripts/generate_sounds.swift
//
// Writes record-start.wav, record-stop.wav, and success.wav into
// Yappy/Resources/Sounds/ (overwriting existing files).

import AVFoundation
import Foundation

let sampleRate = 44_100.0
let outputDir = URL(fileURLWithPath: "Yappy/Resources/Sounds", isDirectory: true)

/// One sine "blip": fast attack, exponential decay, slight 2nd harmonic for warmth.
func tone(frequency: Double, duration: Double, peak: Double, startAt: Double, into buffer: inout [Double]) {
    let start = Int(startAt * sampleRate)
    let count = Int(duration * sampleRate)
    let attack = Int(0.005 * sampleRate)
    for i in 0..<count where start + i < buffer.count {
        let t = Double(i) / sampleRate
        let envelope: Double
        if i < attack {
            envelope = Double(i) / Double(attack)
        } else {
            envelope = exp(-6.0 * (t - 0.005) / duration)
        }
        let fundamental = sin(2 * .pi * frequency * t)
        let harmonic = 0.25 * sin(2 * .pi * frequency * 2 * t)
        buffer[start + i] += peak * envelope * (fundamental + harmonic) / 1.25
    }
}

func write(_ samples: [Double], to filename: String) throws {
    let url = outputDir.appendingPathComponent(filename)
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                               channels: 1, interleaved: true)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channel = buffer.int16ChannelData![0]
    for (i, sample) in samples.enumerated() {
        channel[i] = Int16(max(-1.0, min(1.0, sample)) * 32_766)
    }
    try file.write(from: buffer)
    print("wrote \(url.path)")
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// record-start: rising two-note blip (E5 → A5), ~190 ms, ≈ −12 dBFS peak.
var start = [Double](repeating: 0, count: Int(0.20 * sampleRate))
tone(frequency: 659.25, duration: 0.10, peak: 0.25, startAt: 0.0, into: &start)
tone(frequency: 880.0, duration: 0.11, peak: 0.25, startAt: 0.07, into: &start)
try write(start, to: "record-start.wav")

// record-stop: the falling inverse (A5 → E5).
var stop = [Double](repeating: 0, count: Int(0.20 * sampleRate))
tone(frequency: 880.0, duration: 0.10, peak: 0.25, startAt: 0.0, into: &stop)
tone(frequency: 659.25, duration: 0.11, peak: 0.25, startAt: 0.07, into: &stop)
try write(stop, to: "record-stop.wav")

// success: soft A-major arpeggio (A4, C#5, E5), quieter (≈ −16 dBFS).
var success = [Double](repeating: 0, count: Int(0.26 * sampleRate))
tone(frequency: 440.0, duration: 0.12, peak: 0.16, startAt: 0.0, into: &success)
tone(frequency: 554.37, duration: 0.12, peak: 0.16, startAt: 0.05, into: &success)
tone(frequency: 659.25, duration: 0.14, peak: 0.16, startAt: 0.10, into: &success)
try write(success, to: "success.wav")

print("done")
