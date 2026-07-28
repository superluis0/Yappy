//
//  DictionaryView.swift
//  Yappy
//

import SwiftUI

/// Manage the custom dictionary — terms that bias transcription toward your
/// names, jargon, and acronyms.
struct DictionaryView: View {
    @ObservedObject var store: DictionaryStore
    @ObservedObject var settings: Settings
    @ObservedObject var transcriptionService: ParakeetTranscriptionService

    @State private var newTerm = ""
    @State private var detailTerm: DictionaryTerm?
    @State private var pendingDeleteTerm: DictionaryTerm?
    @State private var deleteTimer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Nil under Reduce Motion, so the same call sites snap instead of springing.
    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// How long Undo stays available after a delete — announced by the toast.
    private var undoWindowSeconds: Int { 3 }

    private var visibleTerms: [DictionaryTerm] {
        store.terms.filter { pendingDeleteTerm?.id != $0.id }
    }

    private func scheduleDeletion(_ term: DictionaryTerm) {
        if let pending = pendingDeleteTerm { store.remove(pending) }
        deleteTimer?.invalidate()
        withAnimation(motion(.spring(response: 0.35, dampingFraction: 0.8))) {
            pendingDeleteTerm = term
        }
        deleteTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(undoWindowSeconds), repeats: false) { _ in
            DispatchQueue.main.async {
                if let t = self.pendingDeleteTerm { self.store.remove(t) }
                withAnimation(self.motion(.spring(response: 0.35, dampingFraction: 0.8))) {
                    self.pendingDeleteTerm = nil
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.sectionGap) {
                header
                enableSection
                boostSection
                if !store.suggestions.isEmpty {
                    suggestionsSection
                }
                if settings.customDictionaryEnabled {
                    termsSection
                }
            }
            // A5: the Terms section appears/disappears with the toggle above it —
            // animate the reveal so the page doesn't jump hundreds of points in
            // one frame. Only the transition changes; the toggle still writes
            // straight to `settings`. (Merge: B's animation + A's page shell,
            // which replaced the hand-rolled padding block it was written over.)
            .animation(motion(.easeOut(duration: 0.24)), value: settings.customDictionaryEnabled)
            .pageShell()
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            if pendingDeleteTerm != nil {
                UndoToast(message: "Term deleted", secondsRemaining: undoWindowSeconds) {
                    deleteTimer?.invalidate()
                    withAnimation(motion(.spring(response: 0.35, dampingFraction: 0.8))) {
                        pendingDeleteTerm = nil
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion(.spring(response: 0.35, dampingFraction: 0.8)), value: pendingDeleteTerm != nil)
        .sheet(item: $detailTerm) { term in
            TermDetailSheet(termID: term.id, store: store, transcriptionService: transcriptionService)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Dictionary")
                .font(.system(size: Design.TypeScale.screenTitle, weight: .bold))
                .foregroundStyle(Brand.ink)
            Text("Add names, jargon, or acronyms Yappy keeps mishearing — recognition is biased toward these terms, fully on-device.")
                .font(.system(size: Design.TypeScale.screenSubtitle))
                .foregroundStyle(Brand.ink3)
        }
    }

    // MARK: - Enable toggle section

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "character.book.closed", title: "Custom dictionary")
                .sectionHeader()

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    // Enable toggle row
                    HStack(spacing: Design.Space.rowGap) {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .fill(settings.customDictionaryEnabled
                                  ? Color.accentColor.opacity(0.18)
                                  : Design.Surface.raised)
                            .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                            .overlay(
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(settings.customDictionaryEnabled
                                                     ? Color.accentColor : Brand.ink3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                                    .strokeBorder(settings.customDictionaryEnabled
                                                  ? Color.accentColor.opacity(0.25)
                                                  : Design.Surface.raised)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable custom dictionary")
                                .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                                .foregroundStyle(Brand.ink)
                            Text("Bias recognition toward your specific terms when active.")
                                .font(.system(size: Design.TypeScale.rowSubtitle))
                                .foregroundStyle(Brand.ink4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $settings.customDictionaryEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.accentColor)
                            .accessibilityLabel("Enable custom dictionary")
                    }
                    .padding(.horizontal, Design.Space.rowHorizontal).padding(.vertical, Design.Space.rowVertical)

                    if settings.customDictionaryEnabled {
                        // Add-term row
                        HStack(spacing: 10) {
                            TextField("Add a term (e.g. Kubernetes, Anthropic)", text: $newTerm)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(commit)
                            Button("Add", action: commit)
                                .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                                .primaryActionFocus()
                        }
                        .padding(.horizontal, Design.Space.rowHorizontal).padding(.vertical, Design.Space.rowVertical)

                        // Caption
                        Text("Add a term, then tap its microphone icon to type \u{201c}sounds like\u{201d} spellings or teach pronunciation by voice. Known mishearings are corrected back to your spelling — instantly, on-device.")
                            .font(.caption)
                            .foregroundStyle(Brand.ink4)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
                }
            }
        }
        // A5: the add-term rows below the switch appear/disappear with it.
        .animation(motion(.easeOut(duration: 0.24)), value: settings.customDictionaryEnabled)
    }

    // MARK: - Speech-model boosting section

    private var boostSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "waveform.and.magnifyingglass", title: "Speech model")
                .sectionHeader()

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: Design.Space.rowGap) {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .fill(settings.vocabularyBoostingEnabled
                                  ? Color.accentColor.opacity(0.18)
                                  : Design.Surface.raised)
                            .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                            .overlay(
                                Image(systemName: "waveform.and.magnifyingglass")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(settings.vocabularyBoostingEnabled
                                                     ? Color.accentColor : Brand.ink3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                                    .strokeBorder(settings.vocabularyBoostingEnabled
                                                  ? Color.accentColor.opacity(0.25)
                                                  : Design.Surface.raised)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Boost my terms in the speech model")
                                .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                                .foregroundStyle(Brand.ink)
                            Text("Makes recognition prefer your dictionary terms while dictating (Parakeet, English). Downloads a 98 MB helper model the first time.")
                                .font(.system(size: Design.TypeScale.rowSubtitle))
                                .foregroundStyle(Brand.ink4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $settings.vocabularyBoostingEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.accentColor)
                            .accessibilityLabel("Boost my terms in the speech model")
                    }
                    .padding(.horizontal, Design.Space.rowHorizontal).padding(.vertical, Design.Space.rowVertical)

                    if settings.transcriptionModel == .nemotron {
                        // Warning: boosting is a Parakeet-only feature and does
                        // nothing while Nemotron is the active model.
                        HStack(spacing: Design.Space.rowGap) {
                            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                                .fill(Brand.danger.opacity(0.18))
                                .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                                .overlay(
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                                        .foregroundStyle(Brand.danger)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                                        .strokeBorder(Brand.danger.opacity(0.25))
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Boost has no effect with Nemotron")
                                    .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                                    .foregroundStyle(Brand.ink)
                                Text("Term boosting works with the Parakeet (English) model. Switch models in Settings to use it.")
                                    .font(.system(size: Design.TypeScale.rowSubtitle))
                                    .foregroundStyle(Brand.ink4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, Design.Space.rowHorizontal).padding(.vertical, Design.Space.rowVertical)
                    }
                }
            }
        }
        // A5: the Nemotron caveat row appears when the model picker changes.
        .animation(motion(.easeOut(duration: 0.24)), value: settings.transcriptionModel)
    }

    // MARK: - Suggestions section (learn-from-corrections)

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "sparkles", title: "Suggestions")
                .sectionHeader()

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(store.suggestions) { suggestion in
                        SuggestionRow(suggestion: suggestion) {
                            withAnimation(motion(.spring(response: 0.35, dampingFraction: 0.85))) {
                                store.acceptSuggestion(suggestion)
                            }
                        } onDismiss: {
                            withAnimation(motion(.spring(response: 0.35, dampingFraction: 0.85))) {
                                store.dismissSuggestion(suggestion)
                            }
                        }
                    }
                }
            }

            Text("Learned from your corrections — accepted spellings improve recognition.")
                .font(.caption)
                .foregroundStyle(Brand.ink4)
                .padding(.horizontal, 4)
                .padding(.top, 9)
        }
    }

    // MARK: - Terms section

    private var termsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "textformat.abc", title: "Terms")
                .sectionHeader()

            Group {
                if visibleTerms.isEmpty {
                    emptyState
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                } else {
                    termsList
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                }
            }
            .animation(motion(.spring(response: 0.45, dampingFraction: 0.85)), value: visibleTerms.isEmpty)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        GlassCard {
            VStack(spacing: 10) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                Text("No terms yet")
                    .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                    .foregroundStyle(Brand.ink3)
                Text("Type a term above and tap Add to get started.")
                    .font(.system(size: Design.TypeScale.rowSubtitle))
                    .foregroundStyle(Brand.ink4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    // MARK: - Terms list

    private var termsList: some View {
        GlassCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(visibleTerms) { term in
                    TermRow(term: term) {
                        detailTerm = term
                    } onDelete: {
                        scheduleDeletion(term)
                    }
                }
            }
        }
    }

    // MARK: - Commit

    private func commit() {
        store.add(newTerm)
        newTerm = ""
    }
}

// MARK: - Term Row

private struct TermRow: View {
    let term: DictionaryTerm
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Design.Space.rowGap) {
            // Icon chip
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                .overlay(
                    Image(systemName: "textformat")
                        .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.20))
                )

            // Text stack
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(term.text)
                        .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                    if term.isBuiltIn {
                        Text("built-in")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Design.Surface.raised, in: Capsule())
                            .foregroundStyle(Brand.ink4)
                    }
                }
                if !term.allAliases.isEmpty {
                    Text("also hears: " + term.allAliases.joined(separator: ", "))
                        .font(.system(size: Design.TypeScale.rowSubtitle))
                        .foregroundStyle(Brand.ink3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Actions
            Button(action: onEdit) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: Design.TypeScale.rowTitle))
                    .foregroundStyle(Brand.ink3)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
            .help("Edit aliases or teach pronunciation")
            .accessibilityLabel("Edit aliases or teach pronunciation for \(term.text)")

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Design.TypeScale.rowTitle))
                    .foregroundStyle(Brand.ink4)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
            .accessibilityLabel("Delete \(term.text)")
        }
        .padding(.horizontal, Design.Space.rowHorizontal).padding(.vertical, 11)
    }
}

// MARK: - Suggestion Row

/// A single mined "did you mean" correction: what Yappy heard vs. what the user
/// meant, with Add (accept) and Dismiss actions. Accepting is the only way the
/// pair enters the dictionary — nothing is applied automatically.
private struct SuggestionRow: View {
    let suggestion: AliasSuggestion
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Design.Space.rowGap) {
            // Icon chip
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.20))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Heard \u{201c}\(suggestion.heard)\u{201d} — did you mean \u{201c}\(suggestion.corrected)\u{201d}?")
                    .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Add it so Yappy corrects this next time.")
                    .font(.system(size: Design.TypeScale.rowSubtitle))
                    .foregroundStyle(Brand.ink4)
            }

            Spacer(minLength: 8)

            Button("Add", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Add \u{201c}\(suggestion.heard)\u{201d} as a spelling of \u{201c}\(suggestion.corrected)\u{201d}")

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Design.TypeScale.rowTitle))
                    .foregroundStyle(Brand.ink4)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
            .help("Dismiss")
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.horizontal, Design.Space.rowHorizontal).padding(.vertical, 11)
    }
}

// MARK: - Term Detail

/// Edit a term's manual "sounds like" aliases, review learned ones, and launch
/// voice training.
private struct TermDetailSheet: View {
    let termID: UUID
    @ObservedObject var store: DictionaryStore
    @ObservedObject var transcriptionService: ParakeetTranscriptionService

    @Environment(\.dismiss) private var dismiss
    @State private var aliasesText = ""
    @State private var showTraining = false

    private var term: DictionaryTerm? { store.terms.first { $0.id == termID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let term {
                Text(term.text).font(.title2.bold())

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sounds like").font(.headline)
                    Text("Spellings Yappy should correct back to \u{201c}\(term.text)\u{201d}, comma-separated.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. Lewis, Louie", text: $aliasesText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.setAliases(splitAliases, for: term) }
                }

                if !term.learnedAliases.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Learned from your voice").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                            ForEach(term.learnedAliases, id: \.self) { alias in
                                HStack(spacing: 6) {
                                    Text(alias).lineLimit(1)
                                    Button { removeLearned(alias, from: term) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove alias \(alias)")
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.quaternary.opacity(0.4), in: Capsule())
                            }
                        }
                    }
                }

                Button {
                    store.setAliases(splitAliases, for: term)
                    showTraining = true
                } label: {
                    Label("Teach pronunciation", systemImage: "waveform.badge.mic")
                }
                .controlSize(.large)
            } else {
                Text("Term removed").foregroundStyle(.secondary)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Done") {
                    if let term { store.setAliases(splitAliases, for: term) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 380)
        .onAppear { aliasesText = term?.aliases.joined(separator: ", ") ?? "" }
        .sheet(isPresented: $showTraining) {
            if let term {
                DictionaryTrainingView(term: term, transcriptionService: transcriptionService) { learned in
                    store.addLearnedAliases(learned, to: term)
                }
            }
        }
    }

    private var splitAliases: [String] {
        aliasesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func removeLearned(_ alias: String, from term: DictionaryTerm) {
        var updated = term
        updated.learnedAliases.removeAll { $0.caseInsensitiveCompare(alias) == .orderedSame }
        store.update(updated)
    }
}
