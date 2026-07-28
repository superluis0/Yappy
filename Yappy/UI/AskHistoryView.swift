//
//  AskHistoryView.swift
//  Yappy
//
//  Browsable history of Ask answers in the main window (sidebar → Ask). Each
//  entry renders the answer block-aware (tables, code, lists, images) via
//  AskAnswerContent — the same renderer as the pill — with copy / re-show /
//  delete actions.
//

import AppKit
import SwiftUI

struct AskHistoryView: View {
    @ObservedObject var store: AskHistoryStore
    @ObservedObject var controller: AskController
    @ObservedObject var settings: Settings

    @State private var query = ""
    @State private var backendFilter: String?
    @State private var showClearAllConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.sectionGap) {
                header

                if store.entries.isEmpty {
                    emptyState
                } else {
                    controls

                    if displayedEntries.isEmpty {
                        noMatchesState
                    } else {
                        ForEach(displayedEntries) { entry in
                            AskHistoryRow(entry: entry, controller: controller, store: store)
                        }
                    }
                }
            }
            .pageShell()
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .confirmationDialog(
            "Clear all answers?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) {
                store.clear()
                controller.clearRuntimeAndHistory()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var displayedEntries: [AskHistoryEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.entries.filter { entry in
            let matchesQuery = trimmedQuery.isEmpty
                || entry.question.localizedCaseInsensitiveContains(trimmedQuery)
                || entry.answer.localizedCaseInsensitiveContains(trimmedQuery)
            let matchesBackend = backendFilter == nil || entry.backend == backendFilter
            return matchesQuery && matchesBackend
        }
        return filtered.filter(\.isFavorite) + filtered.filter { !$0.isFavorite }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Answers").font(.system(size: Design.TypeScale.screenTitle, weight: .bold))
                    .foregroundStyle(Brand.ink)
                Text("Answers you asked by voice. Stored on this Mac only.")
                    .font(.system(size: Design.TypeScale.screenSubtitle)).foregroundStyle(Brand.ink3)
            }
            Spacer(minLength: 12)
            if !store.entries.isEmpty {
                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Design.TypeScale.rowSubtitle, weight: .semibold))
                    .foregroundStyle(Brand.ink4)
                TextField("Search questions and answers", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Design.TypeScale.sectionTitle))
                    .foregroundStyle(Brand.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.inset, style: .continuous)
                    .fill(Design.Surface.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.inset, style: .continuous)
                    .strokeBorder(Design.Surface.strokeEmphasis, lineWidth: 1)
            )

            HStack(spacing: 8) {
                BackendFilterChip(title: "All", isSelected: backendFilter == nil) {
                    backendFilter = nil
                }
                BackendFilterChip(title: "Codex", isSelected: backendFilter == "codex") {
                    backendFilter = "codex"
                }
                BackendFilterChip(title: "Grok", isSelected: backendFilter == "grok") {
                    backendFilter = "grok"
                }
            }
        }
    }

    private var emptyState: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.bubble")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No answers yet")
                            .font(.system(size: Design.TypeScale.rowTitle, weight: .semibold))
                            .foregroundStyle(Brand.ink2)
                        // Merge: C names the actual key + A's type token.
                        Text("Hold \(settings.askHotkeyOption.shortName) and ask out loud — completed answers land here.")
                            .font(.system(size: Design.TypeScale.rowSubtitle))
                            .foregroundStyle(Brand.ink3)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.exampleQuestions, id: \.self) { question in
                        HStack(spacing: 8) {
                            Image(systemName: "text.quote")
                                .font(.system(size: Design.TypeScale.micro, weight: .medium))
                                .foregroundStyle(Brand.ink4)
                            Text(question)
                                .font(.system(size: Design.TypeScale.rowSubtitle))
                                .foregroundStyle(Brand.ink4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Design.Radius.inset, style: .continuous)
                                .fill(Design.Surface.raised)
                        )
                    }
                }
            }
        }
    }

    private static let exampleQuestions = [
        "Compare the M4, M4 Pro and M4 Max chips",
        "What changed in Swift 6.2?",
        "Give me the command to rebase onto main"
    ]

    // Merge: C extracted the shared NoMatchesState (also used by Home and
    // Commands) — one empty-search component instead of three.
    private var noMatchesState: some View { NoMatchesState() }
}

private struct BackendFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Design.TypeScale.caption, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Brand.ink3)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Design.Surface.raised)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Design.Surface.strokeEmphasis)
                )
        }
        .buttonStyle(.pressCapsule)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct AskHistoryRow: View {
    let entry: AskHistoryEntry
    @ObservedObject var controller: AskController
    @ObservedObject var store: AskHistoryStore

    @State private var copied = false

    /// Short question snippet used to name this row's action buttons.
    /// VoiceOver reaches the header controls BEFORE the question text, so
    /// without this a user hears "Favorite, Copy, Show, Delete" four times over
    /// with no idea which entry they act on.
    private var entryShortTitle: String {
        let question = entry.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneLine = question.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > 48 else { return oneLine }
        return String(oneLine.prefix(48)) + "..."
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: Design.TypeScale.caption, design: .monospaced))
                        .foregroundStyle(Brand.ink4)
                    Text(entry.modelLabel ?? entry.backend)
                        .font(.system(size: Design.TypeScale.micro, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    Spacer(minLength: 0)

                    Button {
                        store.toggleFavorite(entry)
                    } label: {
                        Image(systemName: entry.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(entry.isFavorite ? Color.accentColor : Brand.ink4)
                    }
                    .buttonStyle(.borderless)
                    .help(entry.isFavorite ? "Remove favorite" : "Favorite")
                    .accessibilityLabel(entry.isFavorite
                        ? "Remove favorite from \(entryShortTitle)"
                        : "Favorite \(entryShortTitle)")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.answer, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copied ? "Copied" : "Copy answer to \(entryShortTitle)")

                    Button {
                        controller.showEntry(entry)
                    } label: {
                        Label("Show in pill", systemImage: "bubble.middle.bottom")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show answer to \(entryShortTitle) in pill")
                    .disabled(controller.isBusy)

                    Button(role: .destructive) {
                        store.remove(entry)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete answer to \(entryShortTitle)")
                }

                VStack(alignment: .leading, spacing: 10) {
                    // The question is the row's rotor landmark. It is deliberately
                    // NOT merged with the answer below: AskAnswerContent can render
                    // real controls (Copy code, Load image) and links, and grouping
                    // with children: .ignore would erase them from the tree.
                    Text(entry.question)
                        .font(.system(size: Design.TypeScale.rowTitle, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Question: \(entry.question)")
                        .accessibilityAddTraits(.isHeader)

                    AskAnswerContent(
                        text: entry.answer,
                        accent: .accentColor,
                        textPrimary: Brand.ink2,
                        textSecondary: Brand.ink3
                    )
                }

                let sources = AskSources.extract(from: entry.answer)
                if !sources.isEmpty {
                    AskSourceChips(sources: sources, textSecondary: Brand.ink3)
                }
            }
        }
    }
}
