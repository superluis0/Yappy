//
//  HeatmapView.swift
//  Yappy
//

import SwiftUI

/// "When you dictate" — a day-of-week × hour-of-day heatmap of activity.
struct HeatmapView: View {
    private let rows: [HeatmapWeekday]
    private let weekdaySymbols: [String]

    private let spacing: CGFloat = 3
    private let cell: CGFloat = 16
    private let labelWidth: CGFloat = 34

    init(entries: [DictationEntry], calendar: Calendar = .current) {
        // Computed once per HomeView invalidation (entries change), not per frame.
        self.rows = HeatmapModel.hourlyRows(entries: entries, calendar: calendar)
        self.weekdaySymbols = calendar.shortWeekdaySymbols
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When you dictate")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: spacing) {
                ForEach(rows) { row in
                    HStack(spacing: spacing) {
                        Text(weekdayLabel(row.weekday))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: labelWidth, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(forLevel: row.hours[hour].level))
                                .frame(width: cell, height: cell)
                                .help(tooltip(row: row, hour: hour))
                        }
                    }
                }
                hourAxis
            }

            legend
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var hourAxis: some View {
        HStack(spacing: spacing) {
            Color.clear.frame(width: labelWidth, height: 12)
            ForEach(0..<24, id: \.self) { hour in
                if hour % 6 == 0 {
                    Text(hourLabel(hour))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                } else {
                    Color.clear.frame(width: cell)
                }
            }
        }
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
            Text("Less").font(.caption2).foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(forLevel: level))
                    .frame(width: 9, height: 9)
            }
            Text("More").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Labels

    private func weekdayLabel(_ weekday: Int) -> String {
        // shortWeekdaySymbols is 0-indexed by weekday-1 ("Sun"=0).
        let symbol = weekdaySymbols[(weekday - 1) % weekdaySymbols.count]
        return String(symbol.prefix(3))
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case 1..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }

    private func tooltip(row: HeatmapWeekday, hour: Int) -> String {
        let cell = row.hours[hour]
        let day = weekdayLabel(row.weekday)
        let time = hourLabel(hour)
        guard cell.count > 0 else { return "No dictations · \(day) \(time)" }
        return "\(cell.count) dictation\(cell.count == 1 ? "" : "s") · \(cell.words) words · \(day) \(time)"
    }
}
