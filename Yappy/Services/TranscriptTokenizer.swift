//
//  TranscriptTokenizer.swift
//  Yappy
//

import Foundation

/// Splits transcript text into alternating runs of letters (words) and
/// everything else (gaps), preserving every character so the input can be
/// rebuilt exactly. Shared by the transcript-cleanup stages.
enum TranscriptTokenizer {

    enum Token {
        case word(String)
        case gap(String)

        var text: String {
            switch self {
            case .word(let w): return w
            case .gap(let g): return g
            }
        }

        var isWord: Bool {
            if case .word = self { return true }
            return false
        }
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsLetter: Bool?

        for char in text {
            let isLetter = char.isLetter
            if currentIsLetter == nil {
                currentIsLetter = isLetter
                current.append(char)
            } else if isLetter == currentIsLetter {
                current.append(char)
            } else {
                tokens.append(currentIsLetter! ? .word(current) : .gap(current))
                current = String(char)
                currentIsLetter = isLetter
            }
        }
        if let currentIsLetter, !current.isEmpty {
            tokens.append(currentIsLetter ? .word(current) : .gap(current))
        }
        return tokens
    }

    static func render(_ tokens: [Token]) -> String {
        tokens.map(\.text).joined()
    }

    static func isSpaceOnly(_ gap: String) -> Bool {
        !gap.isEmpty && gap.allSatisfy { $0 == " " }
    }
}
