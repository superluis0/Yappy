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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                addField

                if store.terms.isEmpty {
                    emptyState
                } else {
                    termsList
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

                if transcriptionService.dictionaryDownloading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Downloading dictionary model (97 MB, one time)…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("The first use downloads a 97 MB helper model. Works best with the live-caption (streaming) path.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
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
            ForEach(store.terms, id: \.self) { term in
                HStack {
                    Text(term).lineLimit(1)
                    Spacer()
                    Button {
                        store.remove(term)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
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
