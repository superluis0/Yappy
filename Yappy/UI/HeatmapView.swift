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

    @State private var hoveredWeekday: Int? = nil
    @State private var hoveredHour: Int? = nil
    @State private var cellsAppeared = false

    /// Rows are precomputed and cached by HistoryStore (recomputed only when
    /// entries change), so building this view never rescans the full history.
    init(rows: [HeatmapWeekday], calendar: Calendar = .current) {
        self.rows = rows
        self.weekdaySymbols = calendar.shortWeekdaySymbols
    }

    private var hoveredCellLabel: String? {
        guard let weekday = hoveredWeekday, let hour = hoveredHour,
              let row = rows.first(where: { $0.weekday == weekday }) else { return nil }
        return tooltip(row: row, hour: hour)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text("When you dictate")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let label = hoveredCellLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoveredCellLabel)

            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                    HStack(spacing: spacing) {
                        Text(weekdayLabel(row.weekday))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: labelWidth, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(forLevel: row.hours[hour].level))
                                .frame(width: cell, height: cell)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                                    if hoveredWeekday == row.weekday && hoveredHour == hour {
                                        RoundedRectangle(cornerRadius: 2)
                                            .strokeBorder(.primary.opacity(0.45), lineWidth: 1)
                                    }
                                }
                                .onHover { hovering in
                                    withAnimation(.easeOut(duration: 0.08)) {
                                        if hovering {
                                            hoveredWeekday = row.weekday
                                            hoveredHour = hour
                                        } else if hoveredWeekday == row.weekday && hoveredHour == hour {
                                            hoveredWeekday = nil
                                            hoveredHour = nil
                                        }
                                    }
                                }
                                .help(tooltip(row: row, hour: hour))
                        }
                    }
                    .opacity(cellsAppeared ? 1 : 0)
                    .offset(y: cellsAppeared ? 0 : 5)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85).delay(Double(offset) * 0.04),
                               value: cellsAppeared)
                }
                hourAxis
            }
            .onAppear { cellsAppeared = true }

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
        case 1: return .accentColor.opacity(0.3)
        case 2: return .accentColor.opacity(0.52)
        case 3: return .accentColor.opacity(0.75)
        case 4: return .accentColor
        default: return Color.primary.opacity(0.09)
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
