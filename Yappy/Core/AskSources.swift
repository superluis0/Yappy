//
//  AskSources.swift
//  Yappy
//
//  Extracts cited http(s) links from Ask answer markdown for a compact
//  source-chip row. Conservative and deterministic: skips fenced code,
//  dedupes by host, caps at five.
//

import Foundation

struct AskSource: Equatable, Identifiable {
    let url: URL
    let host: String
    var id: String { url.absoluteString }
}

enum AskSources {
    private static let trailingPunctuation = CharacterSet(charactersIn: ").,;\"'>]")

    static func extract(from markdown: String) -> [AskSource] {
        let segments = markdown.components(separatedBy: "```")
        var seenHosts = Set<String>()
        var sources: [AskSource] = []

        for (index, segment) in segments.enumerated() {
            guard index % 2 == 0 else { continue }
            for raw in urlsInSegment(segment) {
                guard let url = URL(string: raw),
                      let host = normalizedHost(url) else { continue }
                guard !seenHosts.contains(host) else { continue }
                seenHosts.insert(host)
                sources.append(AskSource(url: url, host: host))
                if sources.count >= 5 { return sources }
            }
        }
        return sources
    }

    // MARK: - Scanning

    private static func urlsInSegment(_ text: String) -> [String] {
        var results: [String] = []
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "[" {
                var end = index
                if let url = parseMarkdownLink(in: text, startingAt: index, end: &end) {
                    results.append(url)
                    index = end
                    continue
                }
            }
            var end = index
            if let url = parseBareURL(in: text, startingAt: index, end: &end) {
                results.append(url)
                index = end
                continue
            }
            index = text.index(after: index)
        }
        return results
    }

    private static func parseMarkdownLink(
        in text: String, startingAt start: String.Index, end: inout String.Index
    ) -> String? {
        var index = start
        guard text[index] == "[" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex, text[index] != "]" {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "]" else { return nil }
        index = text.index(after: index)

        guard index < text.endIndex, text[index] == "(" else { return nil }
        index = text.index(after: index)

        let urlStart = index
        while index < text.endIndex, text[index] != ")" {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == ")" else { return nil }

        let urlString = String(text[urlStart..<index])
        end = text.index(after: index)
        guard urlString.hasPrefix("https://") else { return nil }
        return urlString
    }

    private static func parseBareURL(
        in text: String, startingAt start: String.Index, end: inout String.Index
    ) -> String? {
        let remainder = text[start...]
        guard remainder.hasPrefix("https://") else { return nil }

        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || "<>[]()\"'".contains(character) { break }
            index = text.index(after: index)
        }

        let raw = String(text[start..<index])
        let cleaned = stripTrailing(from: raw)
        end = index
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func stripTrailing(from string: String) -> String {
        var result = string
        while let last = result.unicodeScalars.last, trailingPunctuation.contains(last) {
            result.removeLast()
        }
        if result.hasSuffix("…") {
            result = String(result.dropLast())
        }
        return result
    }

    private static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host
    }
}
