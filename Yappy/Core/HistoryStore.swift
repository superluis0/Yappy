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
    /// The transcript as it stood *before* AI cleanup (the user's raw words).
    /// Nil when cleanup didn't run or didn't change anything, and nil for legacy
    /// entries written before this field existed — the optional lets synthesized
    /// Codable decode old history.json blobs that lack the key.
    let rawTranscript: String?

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    init(id: UUID = UUID(), date: Date = Date(), text: String, durationSeconds: Double,
         appName: String? = nil, bundleID: String? = nil, rawTranscript: String? = nil) {
        self.id = id
        self.date = date
        self.text = text
        self.durationSeconds = durationSeconds
        self.appName = appName
        self.bundleID = bundleID
        self.rawTranscript = rawTranscript
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

    // MARK: - Lifetime stats
    //
    // The headline numbers (words dictated, time saved) are LIFETIME counters:
    // they only ever increase, persist in a sidecar file next to history.json,
    // and survive Clear All, per-entry deletes, the entry cap, and retention
    // pruning. Deleting conversations clears the list, never the record of use.

    private(set) var totalWords = 0
    private(set) var totalDurationSeconds: Double = 0

    private struct LifetimeStats: Codable {
        var words: Int
        var durationSeconds: Double
    }

    // MARK: - Cached derived stats
    //
    // These depend only on `entries`, so they're recomputed once per mutation
    // (in `recomputeDerived`) rather than scanned on every HomeView render.
    // Date-relative stats (today/yesterday/this-week/streak) stay computed below
    // so they remain correct across midnight without a mutation.

    private(set) var cachedTopApps: [AppUsage] = []
    private(set) var cachedHeatmapRows: [HeatmapWeekday] = []
    private(set) var cachedPersonalRecords: PersonalRecords = .empty

    /// How many days of history to keep; `0` means keep forever. Set from
    /// `Settings.historyRetentionDays` by the app; applied on load and on `add`.
    var retentionDays: Int = 0

    private let fileURL: URL
    /// Sidecar for the lifetime counters ("history.stats.json" beside
    /// "history.json"), so clearing the entries file can never take the
    /// lifetime stats with it.
    private let statsFileURL: URL
    private let ioQueue = DispatchQueue(label: "com.yappy.historystore", qos: .utility)
    private var derivedRecomputeScheduled = false
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Initialization

    /// - Parameter fileURL: Override for tests; defaults to Application Support/Yappy/history.json.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Yappy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Dictation transcripts can be sensitive, so keep the containing
            // directory owner-only (best-effort; never fatal if it can't be set).
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            self.fileURL = dir.appendingPathComponent("history.json")
        }
        self.statsFileURL = self.fileURL
            .deletingPathExtension()
            .appendingPathExtension("stats.json")
        loadFromDisk()
        loadLifetimeStats()
        recomputeDerived()
    }

    // MARK: - Mutations

    func add(_ entry: DictationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Constants.historyLimit {
            entries.removeLast(entries.count - Constants.historyLimit)
        }
        entries = Self.applyingRetention(to: entries, days: retentionDays, now: Date())
        // Lifetime counters accumulate here and only here — O(1), so it stays
        // off the deferred path even though add() is latency-sensitive.
        totalWords += entry.wordCount
        totalDurationSeconds += entry.durationSeconds
        persistLifetimeStats()
        scheduleRecomputeDerived()
        persist()
    }

    /// Removes one conversation from the list. The lifetime stats deliberately
    /// keep counting it — the words were dictated; deleting the transcript
    /// shouldn't rewrite the record of use.
    func delete(_ entry: DictationEntry) {
        entries.removeAll { $0.id == entry.id }
        recomputeDerived()
        persist()
    }

    /// Clears the conversation list only. Lifetime stats (words dictated, time
    /// saved) are untouched — that's the point of the sidecar.
    func clearAll() {
        entries.removeAll()
        recomputeDerived()
        persist()
    }

    /// Recomputes the entries-derived caches. Called on every mutation and load.
    /// Lifetime counters are NOT derived here — they accumulate in `add` and
    /// persist independently, so pruning or clearing entries can't shrink them.
    private func recomputeDerived() {
        cachedTopApps = Self.computeTopApps(entries)
        cachedHeatmapRows = HeatmapModel.hourlyRows(entries: entries)
        cachedPersonalRecords = PersonalRecords.compute(from: entries)
    }

    /// Defers the (expensive) derived-stats recompute to the next main-actor
    /// turn, coalescing rapid successive calls into a single recompute. Used by
    /// `add()` specifically because `add()` sits on the release-to-paste latency
    /// path: the caller pastes the text immediately after `add()` returns, so
    /// keeping this off the synchronous path shaves the recompute's cost off
    /// every dictation. Stats lag by one runloop tick, which is not observable
    /// in the UI, and persistence/durability are unaffected — persist() already
    /// snapshots `entries`, which is fully updated before this returns.
    private func scheduleRecomputeDerived() {
        guard !derivedRecomputeScheduled else { return }
        derivedRecomputeScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.derivedRecomputeScheduled = false
            self.recomputeDerived()
        }
    }

    /// Test-only hook: synchronously runs the pending derived-stats recompute
    /// so tests can assert on stats immediately after `add()` without waiting
    /// for the deferred main-actor turn. No-op in production code paths beyond
    /// what `add()` already schedules.
    func recomputeDerivedNowForTesting() {
        derivedRecomputeScheduled = false
        recomputeDerived()
    }

    // MARK: - Stats

    var dictationsToday: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    var wordsToday: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.wordCount }
    }

    /// Average speaking rate in words per minute across all dictations.
    var averageWordsPerMinute: Int {
        guard totalDurationSeconds > 1 else { return 0 }
        return Int((Double(totalWords) / totalDurationSeconds * 60.0).rounded())
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
        Self.timeSavedMinutes(totalWords: totalWords, totalDurationSeconds: totalDurationSeconds)
    }

    /// The most-dictated-into apps, ordered by dictation count (cached).
    func topApps(limit: Int = 5) -> [AppUsage] {
        Array(cachedTopApps.prefix(limit))
    }

    /// Groups all entries by app into the full ranked list (cached by `recomputeDerived`).
    private static func computeTopApps(_ entries: [DictationEntry]) -> [AppUsage] {
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
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let loaded = try Self.decoder.decode([DictationEntry].self, from: data)
            entries = Self.applyingRetention(to: loaded, days: retentionDays, now: Date())
        } catch {
            VLog.store("failed to decode HistoryStore (\(data.count) bytes): \(error.localizedDescription)")
        }
    }

    private func persist() {
        let snapshot = entries
        let url = fileURL
        ioQueue.async {
            do {
                let data = try Self.encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
                // The atomic write swaps in a fresh file with default (0644,
                // world-readable) perms, so re-tighten to owner-only after every
                // write. Transcripts are sensitive; best-effort, never fatal.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                VLog.store("failed to write HistoryStore: \(error.localizedDescription)")
            }
        }
    }

    /// Loads the lifetime counters, seeding them for pre-sidecar installs: the
    /// first run takes whichever is larger, the persisted counters or the sum
    /// of the entries on disk — so an existing user's numbers carry over
    /// exactly, and the counters can never load LOWER than what the visible
    /// history already proves happened.
    private func loadLifetimeStats() {
        let entriesWords = entries.reduce(0) { $0 + $1.wordCount }
        let entriesDuration = entries.reduce(0.0) { $0 + $1.durationSeconds }
        var stats = LifetimeStats(words: 0, durationSeconds: 0)
        if let data = try? Data(contentsOf: statsFileURL),
           let loaded = try? Self.decoder.decode(LifetimeStats.self, from: data) {
            stats = loaded
        }
        totalWords = max(stats.words, entriesWords)
        totalDurationSeconds = max(stats.durationSeconds, entriesDuration)
        // Write the seeded values back so the migration happens exactly once.
        if totalWords != stats.words || totalDurationSeconds != stats.durationSeconds {
            persistLifetimeStats()
        }
    }

    private func persistLifetimeStats() {
        let snapshot = LifetimeStats(words: totalWords, durationSeconds: totalDurationSeconds)
        let url = statsFileURL
        ioQueue.async {
            do {
                let data = try Self.encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                VLog.store("failed to write lifetime stats: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Retention

    /// Returns `entries` with anything older than `days` dropped. Returns the
    /// input unchanged when `days <= 0` (0 = keep forever). Pure: no I/O, no
    /// mutation of `self`, so it's trivially testable.
    static func applyingRetention(to entries: [DictationEntry], days: Int, now: Date) -> [DictationEntry] {
        guard days > 0 else { return entries }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.date >= cutoff }
    }
}
