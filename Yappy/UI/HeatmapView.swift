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

    @State private var hoveredWeekday: Int?
    @State private var hoveredHour: Int?
    @State private var cellsAppeared = false
    /// Index into `populatedCells` for the VoiceOver adjustable cursor — the
    /// non-mouse equivalent of hovering a cell.
    @State private var axCursor = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The cells a VoiceOver user can step through with the adjustable action.
    private var populatedCells: [(weekday: Int, hour: Int)] {
        HeatmapModel.populatedCells(rows: rows)
    }

    /// Whole-grid VoiceOver label: one element instead of 168 unlabeled shapes.
    private var summaryLabel: String {
        HeatmapModel.accessibilitySummary(
            rows: rows,
            dayName: { weekdayLabel($0) },
            hourName: { hourLabel($0) }
        )
    }

    /// What the single grid element currently reads as its value — the cell the
    /// adjustable cursor (or the mouse) is on.
    private var cursorLabel: String {
        if let hovered = hoveredCellLabel { return hovered }
        let cells = populatedCells
        guard !cells.isEmpty else { return "No dictations yet" }
        let cell = cells[min(max(0, axCursor), cells.count - 1)]
        guard let row = rows.first(where: { $0.weekday == cell.weekday }) else { return "" }
        return tooltip(row: row, hour: cell.hour)
    }

    /// Moves the VoiceOver cursor one populated cell in `direction` and mirrors
    /// it into the hover state, so the visible readout and the highlight ring
    /// follow assistive technology exactly as they follow the mouse.
    private func moveCursor(_ direction: AccessibilityAdjustmentDirection) {
        let cells = populatedCells
        guard !cells.isEmpty else { return }
        let step = direction == .increment ? 1 : -1
        axCursor = min(max(0, axCursor + step), cells.count - 1)
        let cell = cells[axCursor]
        hoveredWeekday = cell.weekday
        hoveredHour = cell.hour
    }

    /// Clears any stuck hover state. Per-cell `.onHover` misses its exit event
    /// when the content scrolls out from under a stationary cursor, so we also
    /// reset at the whole-heatmap boundary and when the view leaves the screen.
    private func clearHover() {
        guard hoveredWeekday != nil || hoveredHour != nil else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.08)) {
            hoveredWeekday = nil
            hoveredHour = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if let label = hoveredCellLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            }
            .frame(height: 13)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredCellLabel)

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
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.08)) {
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
                                // `.help` alone promotes each shape into an
                                // unlabeled AX element; the grid speaks as one
                                // summarized element instead (below).
                                .accessibilityHidden(true)
                        }
                    }
                    .opacity(cellsAppeared ? 1 : 0)
                    .offset(y: (cellsAppeared || reduceMotion) ? 0 : 5)
                    // Decorative staggered cascade; Reduce Motion shows the grid at once.
                    .animation(reduceMotion
                        ? nil
                        : .spring(response: 0.4, dampingFraction: 0.85).delay(Double(offset) * 0.04),
                        value: cellsAppeared)
                }
                hourAxis
            }
            .onAppear { cellsAppeared = true }
            // One element for the whole grid, carrying the summary. The
            // adjustable action walks the populated cells so a non-mouse user
            // reaches the same detail the hover readout shows.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summaryLabel)
            .accessibilityValue(cursorLabel)
            .accessibilityHint("Swipe up or down to step through the busiest hours.")
            .accessibilityAdjustableAction(moveCursor)

            legend
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        // Catch the exit event at the heatmap boundary: individual cells miss
        // their `.onHover(false)` when the page scrolls under a still cursor.
        .onHover { hovering in
            if !hovering { clearHover() }
        }
        // And clear if the heatmap scrolls fully offscreen while hovered.
        .onDisappear { clearHover() }
    }

    private var hourAxis: some View {
        HStack(spacing: spacing) {
            Color.clear.frame(width: labelWidth, height: 12).accessibilityHidden(true)
            ForEach(0..<24, id: \.self) { hour in
                if hour % 6 == 0 {
                    Text(hourLabel(hour))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                } else {
                    // Pure layout spacer — never an AX element.
                    Color.clear.frame(width: cell).accessibilityHidden(true)
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
        // Five bare swatches between two words say nothing on their own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour key: pale for less activity, solid for more.")
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
