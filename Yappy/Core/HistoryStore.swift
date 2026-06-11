//
//  HistoryStore.swift
//  Yappy
//

import Foundation
import Combine

/// A single completed dictation.
struct DictationEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let durationSeconds: Double
    let appName: String?
    /// Bundle identifier of the app dictated into (nil for legacy entries).
    let bundleID: String?

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    init(id: UUID = UUID(), date: Date = Date(), text: String, durationSeconds: Double,
         appName: String? = nil, bundleID: String? = nil) {
        self.id = id
        self.date = date
        self.text = text
        self.durationSeconds = durationSeconds
        self.appName = appName
        self.bundleID = bundleID
    }
}

/// Aggregated per-app dictation usage, for the "top apps" card.
struct AppUsage: Identifiable, Equatable {
    let appName: String
    let bundleID: String?
    let count: Int
    let words: Int

    var id: String { bundleID ?? appName }
}

/// Local, on-disk store of past dictations, newest first.
/// Persists as JSON in Application Support; capped at `Constants.historyLimit` entries.
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.yappy.historystore", qos: .utility)

    // MARK: - Initialization

    /// - Parameter fileURL: Override for tests; defaults to Application Support/Yappy/history.json.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Yappy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("history.json")
        }
        loadFromDisk()
    }

    // MARK: - Mutations

    func add(_ entry: DictationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Constants.historyLimit {
            entries.removeLast(entries.count - Constants.historyLimit)
        }
        persist()
    }

    func delete(_ entry: DictationEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clearAll() {
        entries.removeAll()
        persist()
    }

    // MARK: - Stats

    var totalWords: Int {
        entries.reduce(0) { $0 + $1.wordCount }
    }

    var dictationsToday: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    var wordsToday: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.wordCount }
    }

    /// Average speaking rate in words per minute across all dictations.
    var averageWordsPerMinute: Int {
        let totalSeconds = entries.reduce(0.0) { $0 + $1.durationSeconds }
        guard totalSeconds > 1 else { return 0 }
        return Int((Double(totalWords) / totalSeconds * 60.0).rounded())
    }

    // MARK: - Time Saved

    /// Minutes saved versus typing the same words at `typingWPM`, floored at 0.
    static func timeSavedMinutes(totalWords: Int, totalDurationSeconds: Double, typingWPM: Double = 40) -> Int {
        let typingMinutes = Double(totalWords) / typingWPM
        let speakingMinutes = totalDurationSeconds / 60.0
        return max(0, Int((typingMinutes - speakingMinutes).rounded(.down)))
    }

    /// "0m", "45m", "3h 12m".
    static func formatTimeSaved(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Minutes saved across all stored dictations.
    var timeSavedMinutes: Int {
        Self.timeSavedMinutes(
            totalWords: totalWords,
            totalDurationSeconds: entries.reduce(0.0) { $0 + $1.durationSeconds }
        )
    }

    /// The most-dictated-into apps, ordered by dictation count.
    func topApps(limit: Int = 5) -> [AppUsage] {
        var grouped: [String: (appName: String, bundleID: String?, count: Int, words: Int)] = [:]
        for entry in entries {
            let key = entry.bundleID ?? entry.appName ?? "Unknown"
            var bucket = grouped[key] ?? (entry.appName ?? "Unknown", entry.bundleID, 0, 0)
            bucket.count += 1
            bucket.words += entry.wordCount
            grouped[key] = bucket
        }
        return grouped.values
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { AppUsage(appName: $0.appName, bundleID: $0.bundleID, count: $0.count, words: $0.words) }
    }

    /// Number of consecutive days (ending today or yesterday) with at least one dictation.
    var streakDays: Int {
        let calendar = Calendar.current
        let days = Set(entries.map { calendar.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: Date())
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    // MARK: - Trend Data

    var dictationsYesterday: Int {
        entries.filter { Calendar.current.isDateInYesterday($0.date) }.count
    }

    /// Average WPM across dictations in the last 7 days.
    var averageWPMThisWeek: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let recent = entries.filter { $0.date >= cutoff }
        let secs = recent.reduce(0.0) { $0 + $1.durationSeconds }
        guard secs > 1 else { return 0 }
        return Int((Double(recent.reduce(0) { $0 + $1.wordCount }) / secs * 60).rounded())
    }

    /// Average WPM across dictations in the 7 days before last week (days 8–14 ago).
    var averageWPMLastWeek: Int {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: -7, to: Date())!
        let start = cal.date(byAdding: .day, value: -14, to: Date())!
        let prior = entries.filter { $0.date >= start && $0.date < end }
        let secs = prior.reduce(0.0) { $0 + $1.durationSeconds }
        guard secs > 1 else { return 0 }
        return Int((Double(prior.reduce(0) { $0 + $1.wordCount }) / secs * 60).rounded())
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([DictationEntry].self, from: data) else {
            return
        }
        entries = loaded
    }

    private func persist() {
        let snapshot = entries
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
