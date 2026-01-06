//
//  VoiceCommandProcessor.swift
//  Yappy
//
//  Created on 2026-01-05.
//

import Foundation

/// Voice commands that can be detected in transcription text.
enum VoiceCommand: Equatable {
    /// Delete all recently inserted text
    case deleteThat
    /// Undo the last action (Cmd+Z)
    case undo
    /// Insert a line break
    case newLine
    /// Insert a paragraph break (double line break)
    case newParagraph
    /// Capitalize the last word or sentence
    case capitalizeThat
    /// Insert specific punctuation
    case punctuation(String)
    /// Delete the last sentence
    case scratchThat

    /// User-friendly description of the command
    var description: String {
        switch self {
        case .deleteThat: return "Delete That"
        case .undo: return "Undo"
        case .newLine: return "New Line"
        case .newParagraph: return "New Paragraph"
        case .capitalizeThat: return "Capitalize That"
        case .punctuation(let p): return "Punctuation: \(p)"
        case .scratchThat: return "Scratch That"
        }
    }
}

/// Result of processing transcription for voice commands.
struct CommandProcessingResult {
    /// The transcription text with command phrases removed
    let cleanedText: String
    
    /// Commands detected at the end of the transcription
    let commands: [VoiceCommand]
    
    /// Whether any commands were detected
    var hasCommands: Bool { !commands.isEmpty }
}

/// Processes transcription text to detect and execute voice commands.
/// Commands are detected at the END of transcription text, so saying
/// "delete that" mid-sentence won't trigger the command.
final class VoiceCommandProcessor {
    // MARK: - Properties
    
    /// Whether voice command processing is enabled
    var isEnabled: Bool = true
    
    // MARK: - Command Patterns
    
    /// Command patterns matched at the end of transcription.
    /// Order matters - more specific patterns should come first.
    private let commandPatterns: [(pattern: String, command: VoiceCommand)] = [
        // Delete commands
        ("delete that", .deleteThat),
        ("delete this", .deleteThat),
        ("erase that", .deleteThat),
        ("remove that", .deleteThat),
        
        // Undo commands
        ("undo that", .undo),
        ("undo", .undo),
        
        // Scratch (delete sentence)
        ("scratch that", .scratchThat),
        ("scratch this", .scratchThat),
        
        // Paragraph commands (check before newline)
        ("new paragraph", .newParagraph),
        ("paragraph", .newParagraph),
        
        // Line break commands
        ("new line", .newLine),
        ("newline", .newLine),
        ("next line", .newLine),
        ("line break", .newLine),
        
        // Capitalize
        ("capitalize that", .capitalizeThat),
        ("capitalize this", .capitalizeThat),
        ("cap that", .capitalizeThat),
        
        // Punctuation (inline, not end commands - these insert directly)
        ("period", .punctuation(".")),
        ("full stop", .punctuation(".")),
        ("comma", .punctuation(",")),
        ("question mark", .punctuation("?")),
        ("exclamation mark", .punctuation("!")),
        ("exclamation point", .punctuation("!")),
        ("colon", .punctuation(":")),
        ("semicolon", .punctuation(";")),
        ("dash", .punctuation("—")),
        ("hyphen", .punctuation("-")),
        ("open quote", .punctuation("\"")),
        ("close quote", .punctuation("\"")),
        ("open paren", .punctuation("(")),
        ("close paren", .punctuation(")")),
    ]
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public Methods
    
    /// Processes transcription text to detect voice commands.
    /// Commands are detected at the END of the transcription.
    ///
    /// - Parameter transcription: The raw transcription text to process.
    /// - Returns: A result containing the cleaned text and detected commands.
    func process(transcription: String) -> CommandProcessingResult {
        guard isEnabled else {
            return CommandProcessingResult(cleanedText: transcription, commands: [])
        }
        
        var cleanedText = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        var detectedCommands: [VoiceCommand] = []
        
        // Keep checking for commands at the end until none are found
        var foundCommand = true
        while foundCommand {
            foundCommand = false
            
            let lowercased = cleanedText.lowercased()
            
            for (pattern, command) in commandPatterns {
                // Check if text ends with this command pattern
                if lowercased.hasSuffix(pattern) {
                    // Remove the command from the text
                    let endIndex = cleanedText.index(cleanedText.endIndex, offsetBy: -pattern.count)
                    cleanedText = String(cleanedText[..<endIndex])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Add command to list (prepend so commands execute in spoken order)
                    detectedCommands.insert(command, at: 0)
                    foundCommand = true
                    break  // Start over to check for more commands
                }
            }
        }
        
        return CommandProcessingResult(cleanedText: cleanedText, commands: detectedCommands)
    }
    
    /// Executes a voice command using the streaming inserter.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - streamingInserter: The streaming inserter (for delete/text operations).
    /// - Throws: If the command execution fails.
    @MainActor
    func execute(
        command: VoiceCommand,
        streamingInserter: StreamingTextInserter
    ) throws {
        switch command {
        case .deleteThat:
            try streamingInserter.deleteLastInsertion()
            
        case .undo:
            try simulateUndo()
            
        case .newLine:
            try insertText("\n", using: streamingInserter)
            
        case .newParagraph:
            try insertText("\n\n", using: streamingInserter)
            
        case .capitalizeThat:
            // TODO: Implement capitalize - complex as it requires selecting and modifying
            break
            
        case .punctuation(let punct):
            try insertText(punct, using: streamingInserter)
            
        case .scratchThat:
            // Same as delete that for now - could be more aggressive in future
            try streamingInserter.deleteLastInsertion()
        }
    }
    
    // MARK: - Private Methods
    
    /// Inserts text without going through streaming (for punctuation/newlines).
    private func insertText(_ text: String, using inserter: StreamingTextInserter) throws {
        let textInserter = TextInserter()
        try textInserter.insert(text: text)
    }
    
    /// Simulates Cmd+Z to undo.
    private func simulateUndo() throws {
        let zKeyCode: CGKeyCode = 6  // 'Z' key
        
        // Key down with Command modifier
        guard let keyDownEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: zKeyCode,
            keyDown: true
        ) else {
            return
        }
        keyDownEvent.flags = .maskCommand
        
        // Key up
        guard let keyUpEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: zKeyCode,
            keyDown: false
        ) else {
            return
        }
        keyUpEvent.flags = .maskCommand
        
        // Post events
        keyDownEvent.post(tap: .cghidEventTap)
        usleep(10_000)  // 10ms delay
        keyUpEvent.post(tap: .cghidEventTap)
    }
}

// MARK: - Convenience Extension

extension VoiceCommandProcessor {
    /// Checks if a transcription contains any voice commands at the end.
    ///
    /// - Parameter transcription: The transcription to check.
    /// - Returns: `true` if at least one command was detected.
    func hasCommands(in transcription: String) -> Bool {
        process(transcription: transcription).hasCommands
    }
    
    /// Returns just the command-free text without command details.
    ///
    /// - Parameter transcription: The transcription to clean.
    /// - Returns: The transcription with command phrases removed.
    func stripCommands(from transcription: String) -> String {
        process(transcription: transcription).cleanedText
    }
}
