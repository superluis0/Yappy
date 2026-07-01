//
//  HomeView.swift
//  Yappy

import SwiftUI

/// Home tab: stats cards on top, recent dictations below.
struct HomeView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: Settings
    @ObservedObject var shortcutStore: ShortcutStore

    @State private var editingSuggestion: ShortcutSuggestion?
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
            VStack(alignment: .leading, spacing: 22) {
                header
                timeSavedCard
                gettingStartedCard
                milestoneLine
                statsGrid
                if !history.entries.isEmpty {
                    heatmapCard
                    topAppsCard
                    recordsCard
                    recapButton
                }
                suggestionsCard
                privacyCard
                historySection
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 46)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .sheet(isPresented: $showRecap) { RecapView(history: history) }
        .sheet(item: $editingSuggestion) { suggestion in
            ShortcutEditor(shortcut: VoiceShortcut(trigger: "", expansion: suggestion.phrase)) { result in
                shortcutStore.add(result)
            }
        }
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
        VStack(alignment: .leading, spacing: 3) {
            Text("Home")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Brand.ink)
            Text("Hold \(hotkeyHint) and start talking — your words appear wherever your cursor is.")
                .font(.system(size: 13.5))
                .foregroundStyle(Brand.ink3)
        }
    }

    private var hotkeyHint: String {
        switch settings.hotkeyOption {
        case .rightCommandHold: return "Right ⌘"
        case .rightCommandDoubleTap: return "Right ⌘ (double-tap)"
        case .rightOptionHold: return "Right ⌥"
        case .rightControlHold: return "Right ⌃"
        }
    }

    // MARK: - Stats

    /// Full-width hero: how much time talking has saved over typing.
    @ViewBuilder
    private var timeSavedCard: some View {
        let minutes = history.timeSavedMinutes
        if minutes > 0 {
            GlassCard(tint: Color.accentColor.opacity(0.14)) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: 48, height: 48)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HistoryStore.formatTimeSaved(minutes: statsAppeared ? minutes : 0))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                            .contentTransition(.numericText(value: Double(statsAppeared ? minutes : 0)))
                        Text("Saved vs typing it out")
                            .font(.caption)
                            .foregroundStyle(Brand.ink4)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Getting started

    /// The four onboarding-discovery items, each with whether it's done. "Dictate
    /// your first words" and "Add a dictionary term" derive from live state; the
    /// other two read persisted flags set when the user first does the action.
    private var gettingStartedItems: [GettingStartedItem] {
        [
            GettingStartedItem(
                title: "Dictate your first words",
                subtitle: nil,
                done: !history.entries.isEmpty
            ),
            GettingStartedItem(
                title: "Try a mode",
                subtitle: "Switch tone per app",
                done: settings.hasTriedMode
            ),
            GettingStartedItem(
                title: "Add a dictionary term",
                subtitle: "Teach it your jargon",
                done: settings.hasAddedDictionaryTerm
            ),
            GettingStartedItem(
                title: "Open the scratchpad",
                subtitle: "\u{2325}\u{21E7}S",
                done: settings.hasOpenedScratchpad
            ),
        ]
    }

    /// A guided "getting started" checklist that keeps nudging discovery after
    /// onboarding closes. Disappears entirely once every item is done.
    @ViewBuilder
    private var gettingStartedCard: some View {
        let items = gettingStartedItems
        if !items.allSatisfy(\.done) {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel(icon: "checklist", title: "Getting started")
                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            if index > 0 {
                                Divider().overlay(Color.white.opacity(0.07))
                            }
                            checklistRow(item)
                        }
                    }
                }
            }
        }
    }

    private func checklistRow(_ item: GettingStartedItem) -> some View {
        HStack(spacing: 11) {
            checklistMark(done: item.done)
            HStack(spacing: 5) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.done ? Brand.ink3 : Brand.ink)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Brand.ink4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The 19pt circular status mark: a filled green check when done, a hollow
    /// hairline circle when still to do (mirrors the mockup `.ci .mark`).
    @ViewBuilder
    private func checklistMark(done: Bool) -> some View {
        if done {
            ZStack {
                Circle().fill(Brand.ready)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 19, height: 19)
        } else {
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
                .frame(width: 19, height: 19)
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
                .foregroundStyle(Brand.ink3)
        }
    }

    // MARK: - Heatmap

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(icon: "calendar", title: "When you dictate")
            GlassCard {
                HeatmapView(rows: history.cachedHeatmapRows)
            }
        }
    }

    // MARK: - Personal Records

    @ViewBuilder
    private var recordsCard: some View {
        let r = history.personalRecords
        if r.hasAny {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel(icon: "trophy", title: "Personal records")
                GlassCard {
                    HStack(spacing: 20) {
                        if r.fastestWPM > 0 { recordItem("speedometer", "\(r.fastestWPM)", "Top WPM") }
                        if r.longestStreakDays > 0 { recordItem("flame.fill", "\(r.longestStreakDays)d", "Best streak") }
                        if r.biggestDayWords > 0 { recordItem("calendar", "\(r.biggestDayWords)", "Biggest day") }
                        if r.longestDictationWords > 0 { recordItem("text.alignleft", "\(r.longestDictationWords)", "Longest") }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func recordItem(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon).font(.callout).foregroundStyle(Color.accentColor)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.ink)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Brand.ink4)
        }
    }

    private var recapButton: some View {
        Button { showRecap = true } label: {
            Label("Your Year in Voice", systemImage: "sparkles")
                .font(.callout.weight(.medium))
                .foregroundStyle(recapHover ? Color.accentColor : Brand.ink3)
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
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(icon: "lock.shield", title: "Privacy")
            GlassCard(tint: Brand.ready.opacity(0.10)) {
                VStack(alignment: .leading, spacing: 8) {
                    privacyLine("Audio is transcribed on this Mac and never written to disk.")
                    privacyLine("No telemetry, no account, no analytics.")
                    privacyLine(settings.cleanupEnabled
                        ? "AI cleanup runs on-device with Apple Intelligence \u{2014} nothing leaves this Mac."
                        : "Nothing you say leaves this Mac.")
                }
            }
        }
    }

    private func privacyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(Brand.ready)
            Text(text)
                .font(.caption)
                .foregroundStyle(Brand.ink3)
        }
    }

    // MARK: - Top Apps

    @ViewBuilder
    private var topAppsCard: some View {
        let apps = history.topApps(limit: 5)
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel(icon: "chart.bar", title: "Top apps")
                GlassCard {
                    let maxCount = apps.map(\.count).max() ?? 1
                    VStack(spacing: 10) {
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
                                        .foregroundStyle(Brand.ink4)
                                }
                                Text(app.appName)
                                    .font(.callout)
                                    .foregroundStyle(Brand.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: 110, alignment: .leading)
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.7))
                                        .frame(width: max(8, geo.size.width * CGFloat(app.count) / CGFloat(maxCount)),
                                               height: 6)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                .frame(height: 16)
                                Text("\(app.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Brand.ink4)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }
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
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // Single line so all four cards stay the same height and aligned,
            // even when the window is narrow; the text scales down instead of
            // wrapping to a second line.
            Text(label)
                .font(.caption)
                .foregroundStyle(Brand.ink4)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let delta = trend, delta != 0 {
                HStack(spacing: 2) {
                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                    Text("\(abs(delta))")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(delta > 0 ? Brand.ready : Brand.danger)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(16)
        .glassPanel(cornerRadius: 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .clipShape(.rect(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                 bottomTrailingRadius: 0, topTrailingRadius: 0))
        }
    }

    // MARK: - Suggestions

    /// Repeated dictations worth turning into shortcuts (excludes existing
    /// shortcuts and ones the user dismissed).
    private var suggestions: [ShortcutSuggestion] {
        HistoryInsights.suggestedShortcuts(
            from: history.entries,
            existing: shortcutStore.shortcuts,
            dismissedKeys: settings.dismissedSuggestions
        )
    }

    @ViewBuilder
    private var suggestionsCard: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel(icon: "wand.and.stars", title: "Suggestions")
                GlassCard(tint: Color.accentColor.opacity(0.10)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("You dictate these a lot — turn them into a shortcut you can speak.")
                            .font(.caption)
                            .foregroundStyle(Brand.ink3)

                        ForEach(suggestions) { suggestion in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\u{201c}\(suggestion.phrase)\u{201d}")
                                        .font(.callout)
                                        .foregroundStyle(Brand.ink)
                                        .lineLimit(2)
                                    Text("dictated \(suggestion.count) times")
                                        .font(.caption2)
                                        .foregroundStyle(Brand.ink4)
                                }
                                Spacer()
                                Button("Add shortcut") { editingSuggestion = suggestion }
                                    .controlSize(.small)
                                Button {
                                    settings.dismissedSuggestions.insert(suggestion.id)
                                } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .help("Dismiss")
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionLabel(icon: "clock", title: "Recent dictations")
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
        GlassCard {
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 36))
                    .foregroundStyle(Brand.ink4)
                Text("No dictations yet")
                    .foregroundStyle(Brand.ink3)
                Text("Hold \(hotkeyHint) anywhere and start speaking.")
                    .font(.caption)
                    .foregroundStyle(Brand.ink4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private func historyRow(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .lineLimit(3)
                .foregroundStyle(Brand.ink)
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
            .foregroundStyle(Brand.ink3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 10)
        .opacity(pendingDeleteEntry?.id == entry.id ? 0.4 : 1)
        .grayscale(pendingDeleteEntry?.id == entry.id ? 0.4 : 0)
        .animation(.easeOut(duration: 0.2), value: pendingDeleteEntry?.id == entry.id)
        .onHover { hovering in
            hoveredEntryID = hovering ? entry.id : nil
        }
    }
}

// MARK: - Getting-started checklist model

/// One row of the Home getting-started checklist: a title, an optional subtitle,
/// and whether the user has completed it. Rows are informational for now (no tap
/// navigation — that needs sidebar selection state and is a deliberate follow-up).
private struct GettingStartedItem {
    let title: String
    let subtitle: String?
    let done: Bool
}
