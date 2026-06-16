//
//  ModesView.swift
//  Yappy
//

import SwiftUI

/// Manage dictation modes — named profiles for tone, cleanup, and formatting.
/// The Auto mode is built in and read-only.
struct ModesView: View {
    @ObservedObject var store: ModeStore
    @ObservedObject var settings: Settings

    @State private var editing: Mode?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(store.modes) { mode in
                    row(for: mode)
                }
                Button {
                    let new = Mode(name: "New Mode")
                    store.add(new)
                    editing = new
                } label: {
                    Label("Add mode", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)

                adaptiveSection
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { mode in
            ModeEditor(mode: mode) { store.update($0) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Modes")
                .font(.largeTitle.bold())
            Text("Profiles that set tone, cleanup, and formatting. Switch from the menu bar, or let a mode activate itself for a kind of app. \u{201c}Auto\u{201d} follows your global settings.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(for mode: Mode) -> some View {
        let isActive = activeModeID == mode.id

        return HStack(spacing: 12) {
            Image(systemName: mode.symbolName)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.name).fontWeight(.medium)
                    if isActive {
                        Text("Active").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(subtitle(for: mode))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !isActive {
                Button("Use") { settings.activeModeID = mode.id.uuidString }
                    .buttonStyle(.borderless)
            }
            if !mode.isAuto {
                Button { editing = mode } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                Button { store.delete(mode) } label: {
                    Image(systemName: "trash").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    private var activeModeID: UUID? {
        guard let raw = settings.activeModeID, let id = UUID(uuidString: raw) else { return Mode.autoID }
        return store.modes.contains { $0.id == id } ? id : Mode.autoID
    }

    private func subtitle(for mode: Mode) -> String {
        if mode.isAuto { return "Follows your global settings and per-app tone" }
        var parts = ["Tone: \(mode.tone.displayName)"]
        if let category = mode.autoTriggerCategory {
            parts.append("auto for \(category.displayName)")
        }
        return parts.joined(separator: " \u{00b7} ")
    }

    // MARK: - Adaptive per-app modes

    @ViewBuilder
    private var adaptiveSection: some View {
        Divider().padding(.vertical, 8)
        Toggle("Adapt to the app I'm using", isOn: $settings.adaptiveModeEnabled)
        Text("When you're on Auto, Yappy uses the mode you last picked while in a given app. An explicit mode selection still applies everywhere until you switch back to Auto.")
            .font(.caption).foregroundStyle(.secondary)

        if settings.adaptiveModeEnabled {
            let learned = settings.appModeOverrides.compactMap { pair -> (bundle: String, mode: Mode)? in
                guard let mode = store.modes.first(where: { $0.id.uuidString == pair.value }) else { return nil }
                return (pair.key, mode)
            }.sorted { $0.bundle < $1.bundle }

            if learned.isEmpty {
                Text("No per-app modes learned yet — pick a mode from the menu bar while using an app.")
                    .font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
            } else {
                ForEach(learned, id: \.bundle) { item in
                    HStack(spacing: 6) {
                        Text(appName(for: item.bundle))
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(item.mode.name).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            settings.appModeOverrides.removeValue(forKey: item.bundle)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this app's mode")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Best-effort friendly app name for a bundle id; falls back to the id itself.
    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

// MARK: - Editor

private struct ModeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var mode: Mode
    @State private var extraTermsText: String
    let onSave: (Mode) -> Void

    init(mode: Mode, onSave: @escaping (Mode) -> Void) {
        _mode = State(initialValue: mode)
        _extraTermsText = State(initialValue: mode.extraDictionaryTerms.joined(separator: ", "))
        self.onSave = onSave
    }

    private enum CleanupChoice: String, CaseIterable, Identifiable {
        case inherit = "Inherit"
        case on = "On"
        case off = "Off"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Mode") {
                    TextField("Name", text: $mode.name)
                    TextField("SF Symbol", text: $mode.symbolName)
                    Picker("Tone", selection: $mode.tone) {
                        ForEach(ToneStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Cleanup & formatting") {
                    Picker("AI cleanup", selection: cleanupBinding) {
                        ForEach(CleanupChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Write spoken numbers as digits", isOn: $mode.numberFormatting)
                    Toggle("Format spoken numbered lists", isOn: $mode.numberedLists)
                    Toggle("Remove filler words", isOn: $mode.fillerRemoval)
                    Toggle("Spoken formatting commands", isOn: $mode.spokenCommands)
                    Toggle("Spoken punctuation", isOn: $mode.spokenPunctuation)
                }
                Section {
                    Picker("Auto-activate for", selection: autoTriggerBinding) {
                        Text("Never").tag(AppCategory?.none)
                        ForEach(AppCategory.allCases, id: \.self) { Text($0.displayName).tag(AppCategory?.some($0)) }
                    }
                } header: {
                    Text("Auto-activate")
                } footer: {
                    Text("When set, this mode turns on automatically in that kind of app (unless you've picked a mode explicitly).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Extra dictionary terms (comma-separated)", text: $extraTermsText)
                } header: {
                    Text("Vocabulary")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    mode.extraDictionaryTerms = extraTermsText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onSave(mode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mode.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
    }

    private var cleanupBinding: Binding<CleanupChoice> {
        Binding(
            get: {
                switch mode.cleanupEnabledOverride {
                case .none: return .inherit
                case .some(true): return .on
                case .some(false): return .off
                }
            },
            set: { choice in
                switch choice {
                case .inherit: mode.cleanupEnabledOverride = nil
                case .on: mode.cleanupEnabledOverride = true
                case .off: mode.cleanupEnabledOverride = false
                }
            }
        )
    }

    private var autoTriggerBinding: Binding<AppCategory?> {
        Binding(get: { mode.autoTriggerCategory }, set: { mode.autoTriggerCategory = $0 })
    }
}
