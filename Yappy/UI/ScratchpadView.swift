//
//  ScratchpadView.swift
//  Yappy
//

import SwiftUI

/// A lightweight notepad shown in the floating Scratchpad panel: a sidebar of
/// notes plus a plain-text editor. Dictation lands here for free when the panel
/// is focused (text is pasted into the first responder). Notes persist locally.
struct ScratchpadView: View {
    @ObservedObject var store: NotesStore
    @State private var selectedID: UUID?

    private var selectedNote: Note? {
        if let selectedID, let note = store.notes.first(where: { $0.id == selectedID }) {
            return note
        }
        return store.notes.first
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 280)
            editor
                .frame(minWidth: 280)
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear {
            if selectedID == nil { selectedID = store.notes.first?.id }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scratchpad").font(.headline)
                Spacer()
                Button {
                    let note = store.create()
                    selectedID = note.id
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New note")
                .accessibilityLabel("New note")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.notes.isEmpty {
                Spacer()
                Text("No notes yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(selection: $selectedID) {
                    ForEach(store.notes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.displayTitle)
                                .lineLimit(1)
                            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(note.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                delete(note)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let note = selectedNote {
            TextEditor(text: bodyBinding(note))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No note selected")
                    .foregroundStyle(.secondary)
                Button("New note") {
                    let note = store.create()
                    selectedID = note.id
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private func bodyBinding(_ note: Note) -> Binding<String> {
        Binding(
            get: { store.notes.first(where: { $0.id == note.id })?.body ?? "" },
            set: { store.update(note, body: $0) }
        )
    }

    private func delete(_ note: Note) {
        let wasSelected = selectedNote?.id == note.id
        store.delete(note)
        if wasSelected { selectedID = store.notes.first?.id }
    }
}
