//
//  StreamingTextInserter.swift
//  Yappy
//
//  Created on 2026-01-05.
//

import Foundation
import AppKit

/// Errors that can occur during streaming text insertion.
enum StreamingInsertionError: LocalizedError {
    case insertionFailed(Error)
    case deletionFailed
    case noTextToDelete
    
    var errorDescription: String? {
        switch self {
        case .insertionFailed(let error):
            return "Failed to insert text: \(error.localizedDescription)"
        case .deletionFailed:
            return "Failed to delete previously inserted text."
        case .noTextToDelete:
            return "No recently inserted text to delete."
        }
    }
}

/// Inserts transcribed text word-by-word directly at the cursor position.
/// Creates a "live typing" effect where text appears to type itself.
/// Tracks inserted text for deletion commands like "delete that".
final class StreamingTextInserter {
    // MARK: - Properties
    
    /// Delay between words in seconds (default: 50ms for ~20 words/sec)
    var wordDelay: TimeInterval = 0.05
    
    /// Whether streaming mode is enabled (if false, inserts all at once)
    var streamingEnabled: Bool = true
    
    // MARK: - Private Properties
    
    private let textInserter: TextInserter
    
    /// The most recently inserted text (for deletion)
    private var lastInsertedText: String = ""
    
    /// Character count of last insertion (for precise deletion)
    private var lastInsertedCharacterCount: Int = 0
    
    /// Lock for thread-safe access to insertion state
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    /// Creates a new streaming text inserter.
    ///
    /// - Parameter textInserter: The underlying text inserter to use. Defaults to a new instance.
    init(textInserter: TextInserter = TextInserter()) {
        self.textInserter = textInserter
    }
    
    // MARK: - Public Methods
    
    /// Inserts text word-by-word at the current cursor position.
    /// Creates a streaming "typing" effect where words appear one at a time.
    ///
    /// - Parameter text: The full text to insert.
    /// - Throws: `StreamingInsertionError` if insertion fails.
    @MainActor
    func insertStreaming(text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        // Reset tracking
        lock.lock()
        lastInsertedText = ""
        lastInsertedCharacterCount = 0
        lock.unlock()
        
        if streamingEnabled {
            try await insertWordByWord(trimmedText)
        } else {
            try insertAllAtOnce(trimmedText)
        }
    }
    
    /// Deletes all text that was inserted in the last `insertStreaming` call.
    /// Uses keyboard simulation to select and delete the text.
    ///
    /// - Throws: `StreamingInsertionError` if deletion fails.
    @MainActor
    func deleteLastInsertion() throws {
        lock.lock()
        let charCount = lastInsertedCharacterCount
        lock.unlock()
        
        guard charCount > 0 else {
            throw StreamingInsertionError.noTextToDelete
        }
        
        // Select the inserted text by pressing Shift+Left Arrow for each character
        // Then delete the selection
        try selectAndDelete(characterCount: charCount)
        
        // Reset tracking
        lock.lock()
        lastInsertedText = ""
        lastInsertedCharacterCount = 0
        lock.unlock()
    }
    
    /// Returns the text that was last inserted.
    var lastInserted: String {
        lock.lock()
        defer { lock.unlock() }
        return lastInsertedText
    }
    
    /// Returns the character count of the last insertion.
    var lastInsertedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lastInsertedCharacterCount
    }
    
    // MARK: - Private Methods
    
    /// Inserts text word by word with delays between each word.
    private func insertWordByWord(_ text: String) async throws {
        // Split into words while preserving spacing
        let words = text.components(separatedBy: " ")
        
        for (index, word) in words.enumerated() {
            // Add space after word (except for last word)
            let textToInsert = index < words.count - 1 ? word + " " : word
            
            // Skip empty strings
            guard !textToInsert.isEmpty else { continue }
            
            do {
                try textInserter.insert(text: textToInsert)
                
                // Track what we inserted
                lock.lock()
                lastInsertedText += textToInsert
                lastInsertedCharacterCount += textToInsert.count
                lock.unlock()
                
            } catch {
                throw StreamingInsertionError.insertionFailed(error)
            }
            
            // Wait between words (but not after the last word)
            if index < words.count - 1 && wordDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(wordDelay * 1_000_000_000))
            }
        }
    }
    
    /// Inserts all text at once (non-streaming fallback).
    private func insertAllAtOnce(_ text: String) throws {
        do {
            try textInserter.insert(text: text)
            
            lock.lock()
            lastInsertedText = text
            lastInsertedCharacterCount = text.count
            lock.unlock()
            
        } catch {
            throw StreamingInsertionError.insertionFailed(error)
        }
    }
    
    /// Selects text by simulating Shift+Left Arrow, then deletes it.
    ///
    /// - Parameter characterCount: Number of characters to select and delete.
    private func selectAndDelete(characterCount: Int) throws {
        // Use Cmd+Shift+Left to select word-by-word (faster for longer text)
        // Or for precision, use Shift+Left Arrow character by character
        
        // For efficiency, we'll select all and delete using:
        // 1. Shift + Cmd + Left Arrow to select to beginning of line, repeated
        // 2. Or simply use a series of backspaces
        
        // Simple approach: simulate backspace for each character
        // This is reliable across all apps
        try simulateBackspace(count: characterCount)
    }
    
    /// Simulates pressing the backspace key multiple times.
    ///
    /// - Parameter count: Number of backspaces to simulate.
    private func simulateBackspace(count: Int) throws {
        let backspaceKeyCode: CGKeyCode = 51  // Backspace key
        
        for _ in 0..<count {
            // Create key down event
            guard let keyDownEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: backspaceKeyCode,
                keyDown: true
            ) else {
                throw StreamingInsertionError.deletionFailed
            }
            
            // Create key up event
            guard let keyUpEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: backspaceKeyCode,
                keyDown: false
            ) else {
                throw StreamingInsertionError.deletionFailed
            }
            
            // Post events
            keyDownEvent.post(tap: .cghidEventTap)
            usleep(1000)  // 1ms delay between key down and up
            keyUpEvent.post(tap: .cghidEventTap)
            usleep(500)   // 0.5ms delay between characters
        }
    }
}

// MARK: - Convenience Extension

extension StreamingTextInserter {
    /// Inserts text and returns whether insertion was successful.
    /// Logs errors instead of throwing.
    ///
    /// - Parameter text: The text to insert.
    /// - Returns: `true` if insertion succeeded, `false` otherwise.
    @MainActor
    @discardableResult
    func insertStreamingSafely(text: String) async -> Bool {
        do {
            try await insertStreaming(text: text)
            return true
        } catch {
            print("StreamingTextInserter: Insertion failed - \(error.localizedDescription)")
            return false
        }
    }
}
