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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.sectionGap) {
                header
                modesSection
                adaptiveSection
            }
            .pageShell()
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
                .font(.system(size: Design.TypeScale.screenTitle, weight: .bold))
                .foregroundStyle(Brand.ink)
            Text("Per-app dictation profiles — tune tone, cleanup, and formatting for every context.")
                .font(.system(size: Design.TypeScale.screenSubtitle))
                .foregroundStyle(Brand.ink3)
        }
    }

    // MARK: - Modes card

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: "slider.horizontal.3", title: "Modes")
                .sectionHeader()

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(store.modes) { mode in
                        modeRow(for: mode)
                    }

                    // Add mode button
                    Button {
                        let new = Mode(name: "New Mode")
                        store.add(new)
                        editing = new
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                                .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                                .overlay(
                                    Image(systemName: "plus")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.22))
                                )
                            Text("Add mode")
                                .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                        }
                        .padding(.horizontal, Design.Space.rowHorizontal)
                        .padding(.vertical, Design.Space.rowVertical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Merge: A's hover/press feedback + B's visible focus ring —
                    // orthogonal states, both apply. Radii kept in step.
                    .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.inset))
                    .primaryActionFocus(cornerRadius: Design.Radius.inset)
                }
            }
        }
    }

    private func modeRow(for mode: Mode) -> some View {
        let isActive = activeModeID == mode.id

        return HStack(spacing: Design.Space.rowGap) {
            // Icon chip — accent-tinted when active
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Design.Surface.raised)
                .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                .overlay(
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isActive ? Color.accentColor : Brand.ink3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.30) : Design.Surface.raised)
                )

            // Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.name)
                        .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                        .foregroundStyle(Brand.ink)
                    if isActive {
                        Text("Active")
                            .font(.system(size: Design.TypeScale.caption, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(subtitle(for: mode))
                    .font(.system(size: Design.TypeScale.rowSubtitle))
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
                    Button {
                        settings.activeModeID = mode.id.uuidString
                    } label: {
                        Text("Use")
                            .font(.system(size: Design.TypeScale.rowSubtitle))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
                }

                if !mode.isAuto {
                    Button {
                        editing = mode
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: Design.TypeScale.rowSubtitle))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(Brand.ink3)
                    }
                    .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
                    .accessibilityLabel("Edit \(mode.name)")

                    Button {
                        store.delete(mode)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: Design.TypeScale.rowSubtitle))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(Brand.ink4)
                    }
                    .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
                    .accessibilityLabel("Delete \(mode.name)")
                }
            }
        }
        .padding(.horizontal, Design.Space.rowHorizontal)
        .padding(.vertical, Design.Space.rowVertical)
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
                .sectionHeader()

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    // Adaptive toggle row
                    HStack(spacing: Design.Space.rowGap) {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .fill(settings.adaptiveModeEnabled
                                  ? Color.accentColor.opacity(0.18)
                                  : Design.Surface.raised)
                            .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                            .overlay(
                                Image(systemName: "app.badge")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(settings.adaptiveModeEnabled
                                                     ? Color.accentColor : Brand.ink3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                                    .strokeBorder(settings.adaptiveModeEnabled
                                                  ? Color.accentColor.opacity(0.25)
                                                  : Design.Surface.raised)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            // Merge: C's curly apostrophe + A's type token.
                            Text("Adapt to the app I’m using")
                                .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                                .foregroundStyle(Brand.ink)
                            Text("When on Auto, Yappy uses the mode you last picked in each app. An explicit mode selection overrides until you switch back.")
                                .font(.system(size: Design.TypeScale.rowSubtitle))
                                .foregroundStyle(Brand.ink4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Toggle("", isOn: $settings.adaptiveModeEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.accentColor)
                            .accessibilityLabel("Adapt to the app I'm using")
                    }
                    .padding(.horizontal, Design.Space.rowHorizontal)
                    .padding(.vertical, Design.Space.rowVertical)

                    // Per-app overrides (shown when adaptive is on)
                    if settings.adaptiveModeEnabled {
                        let learned = settings.appModeOverrides.compactMap { pair -> (bundle: String, mode: Mode)? in
                            guard let mode = store.modes.first(where: { $0.id.uuidString == pair.value }) else { return nil }
                            return (pair.key, mode)
                        }.sorted { $0.bundle < $1.bundle }

                        if learned.isEmpty {
                            HStack(spacing: Design.Space.rowGap) {
                                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                                    .fill(Design.Surface.raised)
                                    .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                                    .overlay(
                                        Image(systemName: "tray")
                                            .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                                            .foregroundStyle(Brand.ink4)
                                    )
                                Text("No per-app modes learned yet. Pick a mode from the menu bar while using an app.")
                                    .font(.system(size: Design.TypeScale.rowSubtitle))
                                    .foregroundStyle(Brand.ink4)
                                Spacer()
                            }
                            .padding(.horizontal, Design.Space.rowHorizontal)
                            .padding(.vertical, Design.Space.rowVertical)
                        } else {
                            ForEach(learned, id: \.bundle) { item in
                                learnedAppRow(for: item.bundle, mode: item.mode)
                            }
                        }
                    }
                }
            }
        }
        // A5: the per-app override list appears/disappears with the switch above
        // it — animate the reveal instead of shoving the page in one frame. Only
        // the transition changes; the toggle still writes straight to `settings`.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: settings.adaptiveModeEnabled)
    }

    private func learnedAppRow(for bundleID: String, mode: Mode) -> some View {
        HStack(spacing: Design.Space.rowGap) {
            // App icon placeholder chip
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .fill(Design.Surface.raised)
                .frame(width: Design.Space.chipSize, height: Design.Space.chipSize)
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                        .foregroundStyle(Brand.ink4)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(appName(for: bundleID))
                    .font(.system(size: Design.TypeScale.rowTitle, weight: .medium))
                    .foregroundStyle(Brand.ink)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.ink4)
                    Text(mode.name)
                        .font(.system(size: Design.TypeScale.rowSubtitle))
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
                    .frame(width: 26, height: 26)
            }
            // Merge: A's hover style + C's curly apostrophe.
            .buttonStyle(.hoverSurface(cornerRadius: Design.Radius.control))
            .help("Forget this app’s mode")
            .accessibilityLabel("Forget this app's mode")
        }
        .padding(.horizontal, Design.Space.rowHorizontal)
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
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.sectionGap) {
                    editorSection(
                        icon: "slider.horizontal.3",
                        title: "Mode",
                        footer: "Formal expands contractions and ensures full sentences. Casual drops the trailing period on short messages. Verbatim skips cleanup entirely."
                    ) {
                        TextField("Name", text: $mode.name)
                            .textFieldStyle(.roundedBorder)
                        TextField("SF Symbol", text: $mode.symbolName)
                            .textFieldStyle(.roundedBorder)
                        Picker("Tone", selection: $mode.tone) {
                            ForEach(ToneStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }

                    editorSection(icon: "sparkles", title: "Cleanup & formatting") {
                        Picker("AI cleanup", selection: cleanupBinding) {
                            ForEach(CleanupChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Write spoken numbers as digits", isOn: $mode.numberFormatting)
                        Toggle("Format spoken numbered lists", isOn: $mode.numberedLists)
                        Toggle("Remove filler words", isOn: $mode.fillerRemoval)
                        Toggle("Spoken formatting commands", isOn: $mode.spokenCommands)
                        Toggle("Spoken punctuation", isOn: $mode.spokenPunctuation)
                    }

                    editorSection(
                        icon: "wand.and.stars",
                        title: "Auto-activate",
                        footer: "When set, this mode turns on automatically in that kind of app (unless you’ve picked a mode explicitly)."
                    ) {
                        Picker("Auto-activate for", selection: autoTriggerBinding) {
                            Text("Never").tag(AppCategory?.none)
                            ForEach(AppCategory.allCases, id: \.self) {
                                Text($0.displayName).tag(AppCategory?.some($0))
                            }
                        }
                    }

                    editorSection(icon: "character.book.closed", title: "Vocabulary") {
                        TextField("Extra dictionary terms (comma-separated)", text: $extraTermsText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                // Merge: C's edits here targeted the old Form-based editor,
                // which A rebuilt as editorSection cards with the same strings;
                // C's apostrophe fix is applied to the surviving footer below.
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)

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
            .padding(Design.Space.cardPadding)
        }
        .frame(width: 460, height: 520)
    }

    /// One titled group of controls in the editor — the same section label +
    /// glass card the main window's screens use, with an optional footnote.
    @ViewBuilder
    private func editorSection<Content: View>(
        icon: String,
        title: String,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(icon: icon, title: title)
                .sectionHeader()
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .tint(.accentColor)
            }
            if let footer {
                Text(footer)
                    .font(.system(size: Design.TypeScale.caption))
                    .foregroundStyle(Brand.ink4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Design.Space.sectionHeaderInset)
                    .padding(.top, 8)
            }
        }
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
