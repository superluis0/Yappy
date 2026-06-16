//
//  VoiceControlCommand.swift
//  Yappy
//

import Foundation

/// A spoken instruction to *control the app* (not edit text), said as its own
/// whole utterance — e.g. "switch to email mode", "open scratchpad", "new note".
enum VoiceControlCommand: Equatable {
    case switchToMode(id: UUID)
    case selectAutoMode
    case openScratchpad
    case newNote
}

/// Classifies a whole utterance as an app-control command, or returns nil so the
/// words are dictated normally. Exact-match only, mirroring `VoiceEditCommandParser`:
/// only the entire normalized utterance counts — never a substring — so a real
/// dictation is never swallowed. Mode matching is against the *current* mode
/// names (modes are user-defined), so the parser takes them as input.
enum VoiceControlCommandParser {

    static func parse(_ raw: String, modes: [Mode]) -> VoiceControlCommand? {
        let utterance = normalize(raw)
        guard !utterance.isEmpty else { return nil }

        switch utterance {
        case "open scratchpad", "show scratchpad", "open notes", "show notes":
            return .openScratchpad
        case "new note", "new scratchpad note", "create a note", "create a new note":
            return .newNote
        case "auto mode", "switch to auto mode", "switch to auto", "use auto mode":
            return .selectAutoMode
        default:
            break
        }

        // "switch to <name> mode" / "use <name> mode" / "<name> mode" → a custom mode.
        if let name = modeName(from: utterance) {
            for mode in modes where !mode.isAuto {
                if normalize(mode.name) == name { return .switchToMode(id: mode.id) }
            }
        }
        return nil
    }

    /// Pulls X out of "switch to X mode" / "use X mode" / "X mode"; nil otherwise.
    private static func modeName(from utterance: String) -> String? {
        var s = utterance
        if s.hasPrefix("switch to ") { s.removeFirst("switch to ".count) }
        else if s.hasPrefix("use ") { s.removeFirst("use ".count) }
        guard s.hasSuffix(" mode") else { return nil }
        s.removeLast(" mode".count)
        let name = s.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Lowercased, fillers removed, edge punctuation stripped, whitespace
    /// collapsed — identical normalization to `VoiceEditCommandParser`.
    private static func normalize(_ raw: String) -> String {
        FillerWordRemover.remove(raw).lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
