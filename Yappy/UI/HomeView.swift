//
//  HomeView.swift
//  Yappy
//

import SwiftUI

/// Home tab: stats cards on top, recent dictations below.
struct HomeView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: Settings

    @State private var searchText = ""
    @State private var copiedEntryID: UUID?
    /// Flipped once on appear so the stat numerals roll up from zero.
    @State private var statsAppeared = false
    @State private var showRecap = false
    @State private var recapHover = false
    @State private var pendingDeleteEntry: DictationEntry?
    @State private var deleteTimer: Timer?
    @State private var hoveredEntryID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                timeSavedCard
                milestoneLine
                statsGrid
                if !history.entries.isEmpty {
                    HeatmapView(entries: history.entries)
                    topAppsCard
                    recordsCard
                    recapButton
                }
                privacyCard
                historySection
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showRecap) { RecapView(history: history) }
        .onAppear {
            guard !statsAppeared else { return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.9).delay(0.1)) {
                statsAppeared = true
            }
        }
        .overlay(alignment: .bottom) {
            if pendingDeleteEntry != nil {
                UndoToast(message: "Dictation deleted") {
                    deleteTimer?.invalidate()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        pendingDeleteEntry = nil
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pendingDeleteEntry != nil)
    }

    /// Renders the value as 0 until `statsAppeared` flips, so `.numericText`
    /// rolls the digits up on open.
    private func animatedValue(_ value: Int) -> some View {
        Text("\(statsAppeared ? value : 0)")
            .contentTransition(.numericText(value: Double(statsAppeared ? value : 0)))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Yappy")
                .font(.largeTitle.bold())
            Text("Hold \(hotkeyHint) and start talking — your words appear wherever your cursor is.")
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeyHint: String {
        switch settings.hotkeyOption {
        case .rightCommandHold: return "Right ⌘"
        case .rightCommandDoubleTap: return "Right ⌘ (double-tap)"
        case .rightOptionHold: return "Right ⌥"
        }
    }

    // MARK: - Stats

    /// Full-width hero: how much time talking has saved over typing.
    @ViewBuilder
    private var timeSavedCard: some View {
        let minutes = history.timeSavedMinutes
        if minutes > 0 {
            HStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HistoryStore.formatTimeSaved(minutes: statsAppeared ? minutes : 0))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText(value: Double(statsAppeared ? minutes : 0)))
                    Text("Saved vs typing it out")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            statCard(value: history.totalWords, label: "Words dictated", icon: "text.word.spacing",
                     accent: .blue)
            statCard(
                value: history.dictationsToday,
                label: "Dictations today",
                icon: "mic.fill",
                accent: .orange,
                trend: (history.dictationsYesterday > 0 || history.dictationsToday > 0)
                    ? history.dictationsToday - history.dictationsYesterday : nil
            )
            statCard(
                value: history.averageWordsPerMinute,
                label: "Words / minute",
                icon: "speedometer",
                accent: .green,
                trend: history.averageWPMLastWeek > 0
                    ? history.averageWPMThisWeek - history.averageWPMLastWeek : nil
            )
            statCard(value: history.streakDays, label: "Day streak", icon: "flame.fill",
                     accent: .red, pulse: history.streakDays >= 2)
        }
    }

    /// One quiet line that frames the total at human scale (nil below ~1k words).
    @ViewBuilder
    private var milestoneLine: some View {
        if let milestone = StatFraming.wordsMilestone(history.totalWords) {
            Text("That's \(milestone).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Personal Records

    @ViewBuilder
    private var recordsCard: some View {
        let r = history.personalRecords
        if r.hasAny {
            VStack(alignment: .leading, spacing: 10) {
                Text("Personal records")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    if r.fastestWPM > 0 { recordItem("speedometer", "\(r.fastestWPM)", "Top WPM") }
                    if r.longestStreakDays > 0 { recordItem("flame.fill", "\(r.longestStreakDays)d", "Best streak") }
                    if r.biggestDayWords > 0 { recordItem("calendar", "\(r.biggestDayWords)", "Biggest day") }
                    if r.longestDictationWords > 0 { recordItem("text.alignleft", "\(r.longestDictationWords)", "Longest") }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func recordItem(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon).font(.callout).foregroundStyle(.tint)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var recapButton: some View {
        Button { showRecap = true } label: {
            Label("Your Year in Voice", systemImage: "sparkles")
                .font(.callout.weight(.medium))
                .foregroundStyle(recapHover ? Color.accentColor : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.accentColor.opacity(recapHover ? 0.12 : 0))
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color.accentColor.opacity(recapHover ? 0.45 : 0.18), lineWidth: 1)
                )
                // The transient glow that signals it's clickable.
                .shadow(color: Color.accentColor.opacity(recapHover ? 0.45 : 0),
                        radius: recapHover ? 8 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { recapHover = hovering }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Private by design", systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
            privacyLine("Audio is transcribed on this Mac and never written to disk.")
            privacyLine("No telemetry, no account, no analytics.")
            privacyLine(settings.cleanupEnabled
                ? "AI cleanup talks only to LM Studio on this Mac (localhost)."
                : "Nothing you say leaves this Mac.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func privacyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Top Apps

    @ViewBuilder
    private var topAppsCard: some View {
        let apps = history.topApps(limit: 5)
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Top apps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                let maxCount = apps.map(\.count).max() ?? 1
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        if let icon = IconCache.shared.icon(forBundleID: app.bundleID) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app.badge")
                                .font(.system(size: 12))
                                .frame(width: 16, height: 16)
                                .foregroundStyle(.secondary)
                        }
                        Text(app.appName)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(.tint)
                                .frame(width: max(8, geo.size.width * CGFloat(app.count) / CGFloat(maxCount)),
                                       height: 6)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 16)
                        Text("\(app.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func statCard(value: Int, label: String, icon: String,
                          accent: Color = .accentColor, pulse: Bool = false, trend: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accent)
                .symbolEffect(.pulse, options: .repeating, isActive: pulse)
            animatedValue(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // Single line so all four cards stay the same height and aligned,
            // even when the window is narrow; the text scales down instead of
            // wrapping to a second line.
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let delta = trend, delta != 0 {
                HStack(spacing: 2) {
                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                    Text("\(abs(delta))")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(delta > 0 ? Color.green : Color.red)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(0.5))
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .clipShape(.rect(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                 bottomTrailingRadius: 0, topTrailingRadius: 0))
        }
    }

    // MARK: - History

    private var visibleEntries: [DictationEntry] {
        history.entries
    }

    private var filteredEntries: [DictationEntry] {
        guard !searchText.isEmpty else { return visibleEntries }
        return visibleEntries.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func scheduleDeletion(_ entry: DictationEntry) {
        // Commit any already-pending delete before starting a new one.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if let pending = pendingDeleteEntry { history.delete(pending) }
        }
        deleteTimer?.invalidate()
        withAnimation(.easeOut(duration: 0.15)) {
            pendingDeleteEntry = entry
        }
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if let e = self.pendingDeleteEntry { self.history.delete(e) }
                    self.pendingDeleteEntry = nil
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent dictations")
                    .font(.title3.bold())
                Spacer()
                if !history.entries.isEmpty {
                    Button("Clear All", role: .destructive) {
                        deleteTimer?.invalidate()
                        pendingDeleteEntry = nil
                        history.clearAll()
                    }
                    .controlSize(.small)
                }
            }

            Group {
                if visibleEntries.isEmpty {
                    emptyState
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Search dictations…", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)

                        LazyVStack(spacing: 8) {
                            ForEach(filteredEntries) { entry in
                                historyRow(entry)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: visibleEntries.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No dictations yet")
                .foregroundStyle(.secondary)
            Text("Hold \(hotkeyHint) anywhere and start speaking.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func historyRow(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Text(entry.date, format: .relative(presentation: .named))
                Text("\(entry.wordCount) words")
                if let appName = entry.appName {
                    if let icon = IconCache.shared.icon(forBundleID: entry.bundleID) {
                        HStack(spacing: 4) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 14, height: 14)
                            Text(appName)
                        }
                    } else {
                        Label(appName, systemImage: "app.badge")
                            .labelStyle(.titleAndIcon)
                    }
                }
                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copiedEntryID = entry.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedEntryID == entry.id { copiedEntryID = nil }
                    }
                } label: {
                    Image(systemName: copiedEntryID == entry.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                .opacity(hoveredEntryID == entry.id ? 1 : 0)
                .allowsHitTesting(hoveredEntryID == entry.id)
                .animation(.easeOut(duration: 0.12), value: hoveredEntryID == entry.id)

                Button {
                    scheduleDeletion(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
                .opacity(hoveredEntryID == entry.id ? 1 : 0)
                .allowsHitTesting(hoveredEntryID == entry.id)
                .animation(.easeOut(duration: 0.12), value: hoveredEntryID == entry.id)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .opacity(pendingDeleteEntry?.id == entry.id ? 0.4 : 1)
        .grayscale(pendingDeleteEntry?.id == entry.id ? 0.4 : 0)
        .animation(.easeOut(duration: 0.2), value: pendingDeleteEntry?.id == entry.id)
        .onHover { hovering in
            hoveredEntryID = hovering ? entry.id : nil
        }
    }
}
