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
            VStack(alignment: .leading, spacing: 16) {
                header
                addField

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
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Custom dictionary")
                .font(.largeTitle.bold())
            Text("Add names, jargon, or acronyms Yappy keeps mishearing. Recognition is biased toward these terms — fully on-device.")
                .foregroundStyle(.secondary)
        }
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable custom dictionary", isOn: $settings.customDictionaryEnabled)

            if settings.customDictionaryEnabled {
                HStack {
                    TextField("Add a term (e.g. Kubernetes, Anthropic)", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)
                    Button("Add", action: commit)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("Add a term, then tap its microphone icon to type \u{201c}sounds like\u{201d} spellings or teach pronunciation by voice. Known mishearings are corrected back to your spelling \u{2014} instantly, on-device.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No terms yet")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var termsList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
            ForEach(visibleTerms) { term in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(term.text).lineLimit(1)
                        if term.isBuiltIn {
                            Text("built-in")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.tertiary.opacity(0.5), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { detailTerm = term } label: {
                            Image(systemName: "waveform.badge.mic")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Edit aliases or teach pronunciation")
                        Button {
                            scheduleDeletion(term)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                    }
                    if !term.allAliases.isEmpty {
                        Text("also hears: " + term.allAliases.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func commit() {
        store.add(newTerm)
        newTerm = ""
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
