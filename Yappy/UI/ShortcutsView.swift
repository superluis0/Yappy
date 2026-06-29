//
//  ShortcutsView.swift
//  Yappy

import SwiftUI

/// Manage voice shortcuts: speak a cue → Yappy expands it to canned text.
struct ShortcutsView: View {
    @ObservedObject var store: ShortcutStore
    @State private var editing: VoiceShortcut?
    @State private var showingEditor = false
    @State private var pendingDeleteShortcut: VoiceShortcut?
    @State private var deleteTimer: Timer?

    private var visibleShortcuts: [VoiceShortcut] {
        store.shortcuts.filter { pendingDeleteShortcut?.id != $0.id }
    }

    private func scheduleDeletion(_ shortcut: VoiceShortcut) {
        if let pending = pendingDeleteShortcut { store.delete(pending) }
        deleteTimer?.invalidate()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pendingDeleteShortcut = shortcut
        }
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            DispatchQueue.main.async {
                if let s = self.pendingDeleteShortcut { self.store.delete(s) }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.pendingDeleteShortcut = nil
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                shortcutsSection
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
            if pendingDeleteShortcut != nil {
                UndoToast(message: "Shortcut deleted") {
                    deleteTimer?.invalidate()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        pendingDeleteShortcut = nil
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pendingDeleteShortcut != nil)
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Shortcuts")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Brand.ink)
                Text("Speak a cue and Yappy types the full text — signatures, links, boilerplate.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Brand.ink3)
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

    // MARK: - Shortcuts section

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SectionLabel(icon: "bolt", title: "Shortcuts")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 11)

            GlassCard(padding: 0) {
                Group {
                    if visibleShortcuts.isEmpty {
                        emptyState
                            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(visibleShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                if index > 0 {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.07))
                                        .frame(height: 1)
                                        .padding(.leading, 16)
                                }
                                row(shortcut)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: visibleShortcuts.isEmpty)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: visibleShortcuts.count)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Brand.ink4)
                )
            Text("No shortcuts yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.ink3)
            Text("Add one, then say its trigger while dictating.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.ink4)
                .multilineTextAlignment(.center)
            Button {
                editing = nil
                showingEditor = true
            } label: {
                Label("Add shortcut", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
    }

    // MARK: - Shortcut row

    private func row(_ shortcut: VoiceShortcut) -> some View {
        HStack(spacing: 13) {
            // Icon chip
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(shortcut.enabled ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.06))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(shortcut.enabled ? Color.accentColor : Brand.ink4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            shortcut.enabled ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06)
                        )
                )

            // Trigger + expansion
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(shortcut.trigger)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Brand.ink)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.ink4)
                }
                Text(shortcut.expansion)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.ink3)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            // Enable toggle
            Toggle("", isOn: Binding(
                get: { shortcut.enabled },
                set: { var s = shortcut; s.enabled = $0; store.update(s) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.accentColor)
            .controlSize(.small)

            // Edit button
            Button {
                editing = shortcut
                showingEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.ink3)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.borderless)

            // Delete button
            Button(role: .destructive) {
                scheduleDeletion(shortcut)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.danger.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(Brand.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(shortcut.enabled ? 1 : 0.55)
    }
}

/// Add/edit sheet for a single shortcut. Also reused by the Home "Suggestions"
/// card to turn a repeated dictation into a shortcut.
struct ShortcutEditor: View {
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
