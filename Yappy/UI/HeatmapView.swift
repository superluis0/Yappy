//
//  HeatmapView.swift
//  Yappy
//

import SwiftUI

/// Contribution-style grid of dictation activity for the trailing weeks.
struct HeatmapView: View {
    private let days: [HeatmapDay]
    private let todayStart: Date

    init(entries: [DictationEntry], weeks: Int = 12) {
        // Computed once per HomeView invalidation (entries change), not per frame.
        self.days = HeatmapModel.days(entries: entries, weeks: weeks)
        self.todayStart = Calendar.current.startOfDay(for: Date())
    }

    private var weekColumns: [[HeatmapDay]] {
        stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(weekColumns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week) { day in
                            cell(day)
                        }
                    }
                }
            }

            legend
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func cell(_ day: HeatmapDay) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(color(forLevel: day.level))
            .frame(width: 11, height: 11)
            .overlay {
                if day.date == todayStart {
                    RoundedRectangle(cornerRadius: 2.5)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .help("\(day.dictations) dictation\(day.dictations == 1 ? "" : "s") · \(day.words) words on \(day.date.formatted(date: .abbreviated, time: .omitted))")
    }

    private func color(forLevel level: Int) -> Color {
        switch level {
        case 1: return .accentColor.opacity(0.25)
        case 2: return .accentColor.opacity(0.45)
        case 3: return .accentColor.opacity(0.7)
        case 4: return .accentColor
        default: return Color.primary.opacity(0.06)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(forLevel: level))
                    .frame(width: 9, height: 9)
            }
            Text("More")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
