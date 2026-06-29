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

    private var visibleTerms: [DictionaryTerm] {
        store.terms.filter { pendingDeleteTerm?.id != $0.id }
    }

    private func scheduleDeletion(_ term: DictionaryTerm) {
        if let pending = pendingDeleteTerm { store.remove(pending) }
        deleteTimer?.invalidate()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pendingDeleteTerm = term
        }
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            DispatchQueue.main.async {
                if let t = self.pendingDeleteTerm { self.store.remove(t) }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.pendingDeleteTerm = nil
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                enableSection
                if settings.customDictionaryEnabled {
                    termsSection
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 46)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            if pendingDeleteTerm != nil {
                UndoToast(message: "Term deleted") {
                    deleteTimer?.invalidate()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        pendingDeleteTerm = nil
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pendingDeleteTerm != nil)
        .sheet(item: $detailTerm) { term in
            TermDetailSheet(termID: term.id, store: store, transcriptionService: transcriptionService)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Dictionary")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Brand.ink)
            Text("Add names, jargon, or acronyms Yappy keeps mishearing — recognition is biased toward these terms, fully on-device.")
                .font(.system(size: 13.5))
                .foregroundStyle(Brand.ink3)
        }
    }

    // MARK: - Enable toggle section

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "character.book.closed", title: "Custom dictionary")
                .padding(.horizontal, 4).padding(.bottom, 11)

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    // Enable toggle row
                    HStack(spacing: 13) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(settings.customDictionaryEnabled
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.white.opacity(0.06))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(settings.customDictionaryEnabled
                                                     ? Color.accentColor : Brand.ink3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(settings.customDictionaryEnabled
                                                  ? Color.accentColor.opacity(0.25)
                                                  : Color.white.opacity(0.06))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable custom dictionary")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Brand.ink)
                            Text("Bias recognition toward your specific terms when active.")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.ink4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $settings.customDictionaryEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.accentColor)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)

                    if settings.customDictionaryEnabled {
                        // Divider
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 63)

                        // Add-term row
                        HStack(spacing: 10) {
                            TextField("Add a term (e.g. Kubernetes, Anthropic)", text: $newTerm)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(commit)
                            Button("Add", action: commit)
                                .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)

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
    }

    // MARK: - Terms section

    private var termsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "textformat.abc", title: "Terms")
                .padding(.horizontal, 4).padding(.bottom, 11)

            Group {
                if visibleTerms.isEmpty {
                    emptyState
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                } else {
                    termsList
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: visibleTerms.isEmpty)
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.ink3)
                Text("Type a term above and tap Add to get started.")
                    .font(.system(size: 12))
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
                ForEach(Array(visibleTerms.enumerated()), id: \.element.id) { index, term in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 63)
                    }
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
        HStack(spacing: 13) {
            // Icon chip
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "textformat")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.20))
                )

            // Text stack
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(term.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                    if term.isBuiltIn {
                        Text("built-in")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(Brand.ink4)
                    }
                }
                if !term.allAliases.isEmpty {
                    Text("also hears: " + term.allAliases.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.ink3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Actions
            Button(action: onEdit) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.ink3)
            }
            .buttonStyle(.borderless)
            .help("Edit aliases or teach pronunciation")

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.ink4)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
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
