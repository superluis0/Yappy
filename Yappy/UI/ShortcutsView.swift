//
//  ShortcutsView.swift
//  Yappy
//

import SwiftUI

/// Manage voice shortcuts: speak a cue → Yappy expands it to canned text.
struct ShortcutsView: View {
    @ObservedObject var store: ShortcutStore
    @State private var editing: VoiceShortcut?
    @State private var showingEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if store.shortcuts.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(store.shortcuts) { shortcut in
                            row(shortcut)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingEditor) {
            ShortcutEditor(shortcut: editing) { result in
                if store.shortcuts.contains(where: { $0.id == result.id }) {
                    store.update(result)
                } else {
                    store.add(result)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice shortcuts")
                    .font(.largeTitle.bold())
                Text("Speak a cue and Yappy types the full text — signatures, links, boilerplate.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editing = nil
                showingEditor = true
            } label: {
                Label("New", systemImage: "plus")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No shortcuts yet")
                .foregroundStyle(.secondary)
            Text("Add one, then say its trigger while dictating.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func row(_ shortcut: VoiceShortcut) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { shortcut.enabled },
                set: { var s = shortcut; s.enabled = $0; store.update(s) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                Text("“\(shortcut.trigger)”")
                    .font(.body.weight(.medium))
                Text(shortcut.expansion)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()

            Button {
                editing = shortcut
                showingEditor = true
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)

            Button(role: .destructive) {
                store.delete(shortcut)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .opacity(shortcut.enabled ? 1 : 0.55)
    }
}

/// Add/edit sheet for a single shortcut.
private struct ShortcutEditor: View {
    let shortcut: VoiceShortcut?
    let onSave: (VoiceShortcut) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var expansion: String

    init(shortcut: VoiceShortcut?, onSave: @escaping (VoiceShortcut) -> Void) {
        self.shortcut = shortcut
        self.onSave = onSave
        _trigger = State(initialValue: shortcut?.trigger ?? "")
        _expansion = State(initialValue: shortcut?.expansion ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(shortcut == nil ? "New shortcut" : "Edit shortcut")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("When I say").font(.callout).foregroundStyle(.secondary)
                TextField("e.g. my email", text: $trigger)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Type this").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $expansion)
                    .frame(height: 120)
                    .font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTrigger.isEmpty, !expansion.isEmpty else { return }
                    if var existing = shortcut {
                        existing.trigger = trimmedTrigger
                        existing.expansion = expansion
                        onSave(existing)
                    } else {
                        onSave(VoiceShortcut(trigger: trimmedTrigger, expansion: expansion))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
