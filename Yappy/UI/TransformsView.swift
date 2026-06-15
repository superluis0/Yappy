//
//  TransformsView.swift
//  Yappy
//

import SwiftUI

/// Manage transforms — named AI rewrites you run on selected text from the menu
/// bar, or automatically after every dictation. Requires LM Studio running.
struct TransformsView: View {
    @ObservedObject var store: TransformStore
    @ObservedObject var settings: Settings

    @State private var editing: Transform?
    @State private var showingEditor = false
    @State private var pendingDeleteTransform: Transform?
    @State private var deleteTimer: Timer?

    private var visibleTransforms: [Transform] {
        store.transforms.filter { pendingDeleteTransform?.id != $0.id }
    }

    private func scheduleDeletion(_ transform: Transform) {
        if let pending = pendingDeleteTransform { store.delete(pending) }
        deleteTimer?.invalidate()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pendingDeleteTransform = transform
        }
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            DispatchQueue.main.async {
                if let t = self.pendingDeleteTransform { self.store.delete(t) }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.pendingDeleteTransform = nil
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                autoPicker

                Group {
                    if visibleTransforms.isEmpty {
                        emptyState
                            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(visibleTransforms) { transform in
                                row(transform)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: visibleTransforms.isEmpty)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if pendingDeleteTransform != nil {
                UndoToast(message: "Transform deleted") {
                    deleteTimer?.invalidate()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        pendingDeleteTransform = nil
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pendingDeleteTransform != nil)
        .sheet(isPresented: $showingEditor) {
            TransformEditor(transform: editing) { result in
                if store.transforms.contains(where: { $0.id == result.id }) {
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
                Text("Transforms")
                    .font(.largeTitle.bold())
                Text("AI rewrites of your text. Select text in any app, then run one from the Yappy menu-bar icon \u{2192} Transforms. Requires LM Studio running.")
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

    private var autoPicker: some View {
        HStack {
            Text("Run after every dictation")
            Spacer()
            Picker("", selection: autoBinding) {
                Text("None").tag(String?.none)
                ForEach(store.enabledTransforms) { transform in
                    Text(transform.name).tag(String?.some(transform.id.uuidString))
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var autoBinding: Binding<String?> {
        Binding(
            get: {
                guard let id = settings.autoTransformID,
                      store.enabledTransforms.contains(where: { $0.id.uuidString == id }) else { return nil }
                return id
            },
            set: { settings.autoTransformID = $0 }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No transforms yet")
                .foregroundStyle(.secondary)
            Text("Add one, then run it on selected text from the menu bar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func row(_ transform: Transform) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { transform.enabled },
                set: { var t = transform; t.enabled = $0; store.update(t) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(transform.name)
                        .font(.body.weight(.medium))
                    if transform.isBuiltIn {
                        Text("built-in")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tertiary.opacity(0.5), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(transform.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()

            Button {
                editing = transform
                showingEditor = true
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)

            Button(role: .destructive) {
                scheduleDeletion(transform)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .opacity(transform.enabled ? 1 : 0.55)
    }
}

/// Add/edit sheet for a single transform.
private struct TransformEditor: View {
    let transform: Transform?
    let onSave: (Transform) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var prompt: String

    init(transform: Transform?, onSave: @escaping (Transform) -> Void) {
        self.transform = transform
        self.onSave = onSave
        _name = State(initialValue: transform?.name ?? "")
        _prompt = State(initialValue: transform?.prompt ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(transform == nil ? "New transform" : "Edit transform")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.callout).foregroundStyle(.secondary)
                TextField("e.g. Make formal", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Instruction").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .frame(height: 140)
                    .font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("What the AI should do to the selected text.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
                    if var existing = transform {
                        existing.name = trimmedName
                        existing.prompt = trimmedPrompt
                        onSave(existing)
                    } else {
                        onSave(Transform(name: trimmedName, prompt: trimmedPrompt))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty ||
                    prompt.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
