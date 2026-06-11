//
//  RecapView.swift
//  Yappy
//

import SwiftUI
import AppKit

/// A quiet, end-of-year-style summary of the user's dictation — restrained, lots
/// of whitespace, one accent. Reachable from Home; exportable as an image.
struct RecapView: View {
    @ObservedObject var history: HistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { card.padding(28) }
            Divider()
            HStack {
                Button("Save Image…", action: exportImage)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 600)
    }

    // MARK: - The card (also what gets exported)

    private var card: some View {
        let recap = Recap(history: history)
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Year in Voice")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("The last 12 months, entirely on your Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            stat(value: recap.wordsText, label: "words spoken into existence",
                 footnote: StatFraming.wordsMilestone(recap.words))
            stat(value: recap.timeSavedText, label: "saved versus typing",
                 footnote: StatFraming.timeSavedRelatable(minutes: recap.timeSavedMinutes))
            stat(value: "\(recap.dictations)", label: "dictations", footnote: nil)

            if !recap.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recap.highlights, id: \.label) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.value).fontWeight(.semibold)
                                Text(item.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }

            Text("Yappy")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(value: String, label: String, footnote: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
            Text(label).font(.callout).foregroundStyle(.secondary)
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Export

    @MainActor private func exportImage() {
        let renderer = ImageRenderer(content:
            card
                .padding(28)
                .frame(width: 460)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Yappy Year in Voice.png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}

// MARK: - Derived data

private struct Recap {
    let words: Int
    let dictations: Int
    let timeSavedMinutes: Int
    let highlights: [(icon: String, value: String, label: String)]

    init(history: HistoryStore) {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast
        let recent = history.entries.filter { $0.date >= cutoff }
        let source = recent.isEmpty ? history.entries : recent

        words = source.reduce(0) { $0 + $1.wordCount }
        dictations = source.count
        let duration = source.reduce(0.0) { $0 + $1.durationSeconds }
        timeSavedMinutes = HistoryStore.timeSavedMinutes(totalWords: words, totalDurationSeconds: duration)

        var items: [(String, String, String)] = []
        let records = PersonalRecords.compute(from: source, calendar: calendar)
        if records.fastestWPM > 0 {
            items.append(("speedometer", "\(records.fastestWPM) WPM", "your fastest dictation"))
        }
        if let hour = HeatmapModel.busiestHour(entries: source, calendar: calendar) {
            items.append(("clock", Recap.hourLabel(hour), "when you talk most"))
        }
        if let weekday = HeatmapModel.busiestWeekday(entries: source, calendar: calendar) {
            let name = calendar.weekdaySymbols[(weekday - 1) % 7]
            items.append(("calendar", name, "your busiest day"))
        }
        if records.longestStreakDays >= 2 {
            items.append(("flame.fill", "\(records.longestStreakDays) days", "your longest streak"))
        }
        highlights = items.map { (icon: $0.0, value: $0.1, label: $0.2) }
    }

    var wordsText: String {
        words >= 1000 ? String(format: "%.1fk", Double(words) / 1000.0).replacingOccurrences(of: ".0k", with: "k")
                      : "\(words)"
    }
    var timeSavedText: String { HistoryStore.formatTimeSaved(minutes: timeSavedMinutes) }

    static func hourLabel(_ hour: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12) \(hour < 12 ? "AM" : "PM")"
    }
}
