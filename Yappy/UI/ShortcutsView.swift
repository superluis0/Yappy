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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Nil under Reduce Motion, so the same call sites snap instead of springing.
    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// How long Undo stays available after a delete — announced by the toast.
    private var undoWindowSeconds: Int { 3 }

    private var visibleShortcuts: [VoiceShortcut] {
        store.shortcuts.filter { pendingDeleteShortcut?.id != $0.id }
    }

    private func scheduleDeletion(_ shortcut: VoiceShortcut) {
        if let pending = pendingDeleteShortcut { store.delete(pending) }
        deleteTimer?.invalidate()
        withAnimation(motion(.spring(response: 0.35, dampingFraction: 0.8))) {
            pendingDeleteShortcut = shortcut
        }
        deleteTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(undoWindowSeconds), repeats: false) { _ in
            DispatchQueue.main.async {
                if let s = self.pendingDeleteShortcut { self.store.delete(s) }
                withAnimation(self.motion(.spring(response: 0.35, dampingFraction: 0.8))) {
                    self.pendingDeleteShortcut = nil
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.sectionGap) {
                header
                shortcutsSection
            }
            .pageShell()
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            if pendingDeleteShortcut != nil {
                UndoToast(message: "Shortcut deleted", secondsRemaining: undoWindowSeconds) {
                    deleteTimer?.invalidate()
                    withAnimation(motion(.spring(response: 0.35, dampingFraction: 0.8))) {
                        pendingDeleteShortcut = nil
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion(.spring(response: 0.35, dampingFraction: 0.8)), value: pendingDeleteShortcut != nil)
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
                    .font(.system(size: Design.TypeScale.screenTitle, weight: .bold))
                    .foregroundStyle(Brand.ink)
                Text("Speak a cue and Yappy types the full text — signatures, links, boilerplate.")
                    .font(.system(size: Design.TypeScale.screenSubtitle))
                    .foregroundStyle(Brand.ink3)
            }
            Spacer()
            Button {
                editing = nil
                showingEditor = true
            } label: {
                Label("New", systemImage: "plus")
            }
            .primaryActionFocus()
        }
    }

    // MARK: - Shortcuts section

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SectionLabel(icon: "bolt", title: "Shortcuts")
            }
            .sectionHeader()

            GlassCard(padding: 0) {
                Group {
                    if visibleShortcuts.isEmpty {
                        emptyState
                            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(visibleShortcuts) { shortcut in
                                row(shortcut)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                    }
                }
                .animation(motion(.spring(response: 0.45, dampingFraction: 0.85)), value: visibleShortcuts.isEmpty)
                .animation(motion(.spring(response: 0.45, dampingFraction: 0.85)), value: visibleShortcuts.count)
            }
        }
    }

    // MARK: - Empty state

    /// Ready-made examples shown only in the empty state. These are NOT auto-seeded
    /// into the store — shortcuts stay opt-in; the user taps Add to create one.
    private static let exampleShortcuts: [VoiceShortcut] = [
        VoiceShortcut(trigger: "signature", expansion: "Best regards,\n[Your name]"),
        VoiceShortcut(trigger: "my address", expansion: "[Your street]\n[City, State ZIP]"),
        VoiceShortcut(trigger: "standup update", expansion: "Yesterday: \nToday: \nBlockers: ")
    ]

    /// Adds an example to the store and opens the editor on it so the user can
    /// personalize the placeholders right away.
    private func addExample(_ example: VoiceShortcut) {
        let shortcut = VoiceShortcut(trigger: example.trigger, expansion: example.expansion)
        store.add(shortcut)
        editing = shortcut
        showingEditor = true
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Try one of these")
                    .font(.system(size: Design.TypeScale.rowTitle, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                Text("Example — tap Add, then edit to make it yours.")
                    .font(.system(size: Design.TypeScale.rowSubtitle))
                    .foregroundStyle(Brand.ink4)
            }

            VStack(spacing: 10) {
                ForEach(Self.exampleShortcuts) { example in
                    exampleCard(example)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Space.cardPadding)
    }

    private func exampleCard(_ example: VoiceShortcut) -> some View {
        HStack(spacing: Design.Space.rowGap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(example.trigger)
                        .font(.system(size: Design.TypeScale.sectionTitle, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Brand.ink)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.ink4)
                }
                Text(example.expansion)
                    .font(.system(size: Design.TypeScale.rowSubtitle))
                    .foregroundStyle(Brand.ink3)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button {
                addExample(example)
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Surface.raised,
                    in: RoundedRectangle(cornerRadius: Design.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.inset, style: .continuous)
                .strokeBorder(Design.Surface.stroke)
        )
    }

    // MARK: - Shortcut row

    private func row(_ shortcut: VoiceShortcut) -> some View {
        HStack(spacing: Design.Space.rowGap) {
            // Icon chip
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .fill(shortcut.enabled ? Color.accentColor.opacity(0.18) : Design.Surface.raised)
                .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                .overlay(
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(shortcut.enabled ? Color.accentColor : Brand.ink4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(
                            shortcut.enabled ? Color.accentColor.opacity(0.25) : Design.Surface.stroke
                        )
                )

            // Trigger + expansion
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(shortcut.trigger)
                        .font(.system(size: Design.TypeScale.sectionTitle, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Brand.ink)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.ink4)
                }
                Text(shortcut.expansion)
                    .font(.system(size: Design.TypeScale.rowSubtitle))
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
            .accessibilityLabel("\(shortcut.trigger) enabled")

            // Edit button
            Button {
                editing = shortcut
                showingEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: Design.TypeScale.sectionTitle, weight: .medium))
                    .foregroundStyle(Brand.ink3)
                    .frame(width: 26, height: 26)
                    .background(Design.Surface.raised,
                                in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            }
            .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
            .accessibilityLabel("Edit \(shortcut.trigger)")

            // Delete button
            Button(role: .destructive) {
                scheduleDeletion(shortcut)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: Design.TypeScale.sectionTitle, weight: .medium))
                    .foregroundStyle(Brand.danger.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(Brand.danger.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            }
            .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
            .accessibilityLabel("Delete \(shortcut.trigger)")
        }
        .padding(.horizontal, Design.Space.rowHorizontal)
        .padding(.vertical, Design.Space.rowVertical)
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
