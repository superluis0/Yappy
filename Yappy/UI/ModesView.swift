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
            VStack(alignment: .leading, spacing: 26) {
                header
                modesSection
                adaptiveSection
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 46)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .sheet(item: $editing) { mode in
            ModeEditor(mode: mode) { store.update($0) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Modes")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Brand.ink)
            Text("Per-app dictation profiles — tune tone, cleanup, and formatting for every context.")
                .font(.system(size: 13.5))
                .foregroundStyle(Brand.ink3)
        }
    }

    // MARK: - Modes card

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "slider.horizontal.3", title: "Modes")
                .padding(.horizontal, 4)
                .padding(.bottom, 11)

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(store.modes.enumerated()), id: \.element.id) { index, mode in
                        if index > 0 {
                            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 63)
                        }
                        modeRow(for: mode)
                    }

                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 63)

                    // Add mode button
                    Button {
                        let new = Mode(name: "New Mode")
                        store.add(new)
                        editing = new
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Image(systemName: "plus")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.22))
                                )
                            Text("Add mode")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func modeRow(for mode: Mode) -> some View {
        let isActive = activeModeID == mode.id

        return HStack(spacing: 13) {
            // Icon chip — accent-tinted when active
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.06))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isActive ? Color.accentColor : Brand.ink3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.06))
                )

            // Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Brand.ink)
                    if isActive {
                        Text("Active")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(subtitle(for: mode))
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.ink4)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            // Trailing controls
            HStack(spacing: 4) {
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                } else {
                    Button("Use") { settings.activeModeID = mode.id.uuidString }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }

                if !mode.isAuto {
                    Button {
                        editing = mode
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(Brand.ink3)
                    }
                    .buttonStyle(.borderless)

                    Button {
                        store.delete(mode)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(Brand.ink4)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Computed helpers

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

    // MARK: - Adaptive per-app modes section

    @ViewBuilder
    private var adaptiveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "wand.and.stars", title: "Adaptive modes")
                .padding(.horizontal, 4)
                .padding(.bottom, 11)

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    // Adaptive toggle row
                    HStack(spacing: 13) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(settings.adaptiveModeEnabled
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.white.opacity(0.06))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Image(systemName: "app.badge")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(settings.adaptiveModeEnabled
                                                     ? Color.accentColor : Brand.ink3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(settings.adaptiveModeEnabled
                                                  ? Color.accentColor.opacity(0.25)
                                                  : Color.white.opacity(0.06))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Adapt to the app I'm using")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Brand.ink)
                            Text("When on Auto, Yappy uses the mode you last picked in each app. An explicit mode selection overrides until you switch back.")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.ink4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Toggle("", isOn: $settings.adaptiveModeEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.accentColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    // Per-app overrides (shown when adaptive is on)
                    if settings.adaptiveModeEnabled {
                        let learned = settings.appModeOverrides.compactMap { pair -> (bundle: String, mode: Mode)? in
                            guard let mode = store.modes.first(where: { $0.id.uuidString == pair.value }) else { return nil }
                            return (pair.key, mode)
                        }.sorted { $0.bundle < $1.bundle }

                        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 63)

                        if learned.isEmpty {
                            HStack(spacing: 13) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Image(systemName: "tray")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Brand.ink4)
                                    )
                                Text("No per-app modes learned yet. Pick a mode from the menu bar while using an app.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.ink4)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        } else {
                            ForEach(Array(learned.enumerated()), id: \.element.bundle) { index, item in
                                if index > 0 {
                                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 63)
                                }
                                learnedAppRow(for: item.bundle, mode: item.mode)
                            }
                        }
                    }
                }
            }
        }
    }

    private func learnedAppRow(for bundleID: String, mode: Mode) -> some View {
        HStack(spacing: 13) {
            // App icon placeholder chip
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Brand.ink4)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(appName(for: bundleID))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.ink)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.ink4)
                    Text(mode.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.ink3)
                }
            }

            Spacer(minLength: 12)

            Button {
                settings.appModeOverrides.removeValue(forKey: bundleID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.ink4)
            }
            .buttonStyle(.borderless)
            .help("Forget this app's mode")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
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
                Section {
                    TextField("Name", text: $mode.name)
                    TextField("SF Symbol", text: $mode.symbolName)
                    Picker("Tone", selection: $mode.tone) {
                        ForEach(ToneStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Mode")
                } footer: {
                    Text("Formal expands contractions and ensures full sentences. Casual drops the trailing period on short messages. Verbatim skips cleanup entirely.")
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
