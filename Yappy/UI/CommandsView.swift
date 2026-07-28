//
//  CommandsView.swift
//  Yappy
//

import SwiftUI

/// The Commands cheat sheet: every built-in spoken phrase Yappy understands,
/// grouped by feature and mined verbatim from the parser that recognizes it
/// (see `CommandCatalog`). Read-only — this tab documents behavior, it doesn't
/// configure it (that's Settings, one tap away via each section's badge).
struct CommandsView: View {
    @ObservedObject var settings: Settings
    /// Shared sidebar-selection state, so a section's "Off in Settings" badge
    /// can jump straight to the Settings tab.
    @ObservedObject var windowState: MainWindowState

    @State private var searchText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.sectionGap) {
                header
                searchField
                if filteredSections.isEmpty {
                    NoMatchesState()
                } else {
                    ForEach(filteredSections, id: \.title) { section in
                        sectionCard(section)
                    }
                }
            }
            .pageShell()
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Commands")
                .font(.system(size: Design.TypeScale.screenTitle, weight: .bold))
                .foregroundStyle(Brand.ink)
            Text("Everything you can say while dictating — no memorizing required.")
                .font(.system(size: Design.TypeScale.screenSubtitle))
                .foregroundStyle(Brand.ink3)
        }
    }

    private var searchField: some View {
        TextField("Search commands…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
    }

    // MARK: - Sections

    /// All sections, minus Answers when the feature itself is off — those card
    /// commands have no surface anywhere in the app until Answers is enabled,
    /// unlike the other sections (whose behavior still exists, just off).
    private var visibleSections: [CommandSection] {
        CommandCatalog.sections.filter { section in
            guard section.title == CommandCatalog.answersSectionTitle else { return true }
            return settings.askEnabled
        }
    }

    private var filteredSections: [CommandSection] {
        visibleSections.compactMap(filtered)
    }

    /// The section filtered down to entries matching the search text, or nil
    /// when nothing in it matches (so the section is omitted entirely).
    private func filtered(_ section: CommandSection) -> CommandSection? {
        guard !searchText.isEmpty else { return section }
        let entries = section.entries.filter {
            $0.phrase.localizedCaseInsensitiveContains(searchText)
                || $0.effect.localizedCaseInsensitiveContains(searchText)
        }
        guard !entries.isEmpty else { return nil }
        return CommandSection(title: section.title, icon: section.icon,
                              settingsKeyPath: section.settingsKeyPath, entries: entries)
    }

    @ViewBuilder
    private func sectionCard(_ section: CommandSection) -> some View {
        // Merge: C moved filtering up into `filteredSections` (so an empty
        // search shows NoMatchesState); A supplied the visual shell — unified
        // section header, no in-card dividers.
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(icon: section.icon, title: section.title)
                Spacer()
                if isEnabled(section) == false {
                    offBadge
                }
            }
            .sectionHeader()
            GlassCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                        entryRow(entry)
                    }
                }
            }
        }
    }

    /// Whether the section's own toggle is on; nil when the section has no
    /// toggle (always on, e.g. Dictation basics or Submit).
    private func isEnabled(_ section: CommandSection) -> Bool? {
        guard let keyPath = section.settingsKeyPath else { return nil }
        return settings[keyPath: keyPath]
    }

    private var offBadge: some View {
        Button {
            windowState.select(.settings)
        } label: {
            Text("Off in Settings")
                .font(.system(size: Design.TypeScale.micro, weight: .semibold))
                .foregroundStyle(Brand.ink3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Design.Surface.raised))
                .overlay(Capsule().strokeBorder(Design.Surface.strokeEmphasis))
        }
        .buttonStyle(.pressCapsule)
        .help("Turn this on in Settings")
    }

    // MARK: - Rows

    private func entryRow(_ entry: CommandEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Spoken phrases wear the quoted chip; physical actions (hold the
            // hotkey, press Esc) render as plain labels so nobody says them.
            Text(entry.isSpoken ? "\u{201c}\(entry.phrase)\u{201d}" : entry.phrase)
                .font(.system(size: Design.TypeScale.rowSubtitle, weight: .medium,
                              design: entry.isSpoken ? .monospaced : .default))
                .foregroundStyle(Brand.ink2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    entry.isSpoken ? Design.Surface.raised : Color.clear,
                    in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                )
                .frame(minWidth: 170, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.effect)
                    .font(.system(size: Design.TypeScale.rowSubtitle))
                    .foregroundStyle(Brand.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if let example = entry.example {
                    Text(example)
                        .font(.system(size: Design.TypeScale.caption))
                        .foregroundStyle(Brand.ink4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.rowHorizontal).padding(.vertical, 10)
    }
}
