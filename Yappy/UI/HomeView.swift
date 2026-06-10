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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statsGrid
                if !history.entries.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        HeatmapView(entries: history.entries)
                        topAppsCard
                            .frame(width: 240)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                historySection
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            statCard(value: "\(history.totalWords)", label: "Words dictated", icon: "text.word.spacing")
            statCard(value: "\(history.dictationsToday)", label: "Dictations today", icon: "mic.fill")
            statCard(value: "\(history.averageWordsPerMinute)", label: "Words / minute", icon: "speedometer")
            statCard(value: "\(history.streakDays)", label: "Day streak", icon: "flame.fill")
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
                            .frame(width: 86, alignment: .leading)
                        Capsule()
                            .fill(.tint)
                            .frame(width: max(8, 90 * CGFloat(app.count) / CGFloat(maxCount)), height: 5)
                        Spacer(minLength: 0)
                        Text("\(app.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
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
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - History

    private var filteredEntries: [DictationEntry] {
        guard !searchText.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
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
                        history.clearAll()
                    }
                    .controlSize(.small)
                }
            }

            if history.entries.isEmpty {
                emptyState
            } else {
                TextField("Search dictations…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)

                LazyVStack(spacing: 8) {
                    ForEach(filteredEntries) { entry in
                        historyRow(entry)
                    }
                }
            }
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

                Button {
                    history.delete(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
