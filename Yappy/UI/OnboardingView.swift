//
//  OnboardingView.swift
//  Yappy
//

import SwiftUI
import ApplicationServices
import AVFoundation

/// A way the user plans to dictate, picked during onboarding. Each case maps to a
/// preset Mode and a few seeded dictionary terms (applied in `AppDelegate`). The
/// raw value is what's persisted in `Settings.useCases`.
enum UseCase: String, CaseIterable, Identifiable {
    case code
    case writing
    case email
    case chat
    case notes

    var id: String { rawValue }

    /// Label shown on the selectable chip.
    var displayName: String {
        switch self {
        case .code: return "Code"
        case .writing: return "Writing"
        case .email: return "Email"
        case .chat: return "Chat"
        case .notes: return "Notes"
        }
    }

    /// SF Symbol for the chip, mirroring the mockup's icon choices.
    var symbolName: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .writing: return "pencil"
        case .email: return "envelope"
        case .chat: return "bubble.left.and.bubble.right"
        case .notes: return "note.text"
        }
    }
}

/// Rolling audio levels for the onboarding mic preview, fed by AppDelegate.
@MainActor
final class OnboardingLevelModel: ObservableObject {
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: Constants.pillBarCount)

    func push(_ level: Float) {
        var updated = levels
        updated.removeFirst()
        updated.append(level)
        levels = updated
    }

    func reset() {
        levels = Array(repeating: 0, count: Constants.pillBarCount)
    }
}

/// Guided first-run flow: welcome → microphone (live waveform) →
/// accessibility → model download (permissions come first, so the download
/// wait shows a rotating "what you can say" deck instead of a bare progress
/// bar) → try it → what you'll use it for. Each step springs in from the
/// trailing edge; the mic step shows Yappy actually hearing you, the model
/// step teaches a few commands while the one-time download runs, and the
/// try-it step lets you dictate into a practice field before the final
/// use-case pick, which seeds a starter Mode + dictionary and finishes.
struct OnboardingView: View {
    @ObservedObject var transcriptionService: ParakeetTranscriptionService
    @ObservedObject var levelModel: OnboardingLevelModel
    /// Shared app state. The try-it step watches `lastDictationAt` to confirm the
    /// practice text arrived by voice rather than the keyboard.
    @ObservedObject var appState: AppState
    let requestMicrophone: () async -> Bool
    let startLevelPreview: () -> Bool
    let stopLevelPreview: () -> Void
    /// Presets a Mode and seeds dictionary terms for each picked use case.
    let applyUseCase: (Set<UseCase>) -> Void
    let onFinish: () -> Void
    /// Finishes onboarding AND opens the main window on the Commands tab —
    /// the "Browse the commands" button's whole promise.
    var onBrowseCommands: () -> Void = {}

    @State private var step = 0
    @State private var micGranted = AudioRecorder.hasPermission
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var axGranted = AXIsProcessTrusted()
    @State private var previewActive = false
    @State private var pickedUseCases: Set<UseCase> = []
    @State private var tryItText = ""
    @State private var tryItSucceeded = false

    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Total onboarding steps, surfaced as the progress-dot count.
    private static let stepCount = 6

    var body: some View {
        ZStack {
            GlassBackdrop()

            VStack(spacing: 20) {
                ZStack {
                    content
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                .frame(maxHeight: .infinity)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)

                ProgressDots(count: Self.stepCount, active: step)
            }
            .padding(32)
        }
        .frame(width: 460, height: 500)
        .onReceive(permissionPoll) { _ in
            micGranted = AudioRecorder.hasPermission
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            axGranted = AXIsProcessTrusted()
            syncPreview()
        }
        .onChange(of: step) {
            syncPreview()
        }
        .onDisappear {
            if previewActive {
                stopLevelPreview()
                previewActive = false
            }
        }
    }

    /// The live mic waveform runs only on the microphone step once granted.
    private func syncPreview() {
        let shouldPreview = (step == 1 && micGranted)
        if shouldPreview, !previewActive {
            previewActive = startLevelPreview()
        } else if !shouldPreview, previewActive {
            stopLevelPreview()
            previewActive = false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: microphone
        case 2: accessibility
        case 3: model
        case 4: tryIt
        default: useCase
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        stepCard {
            StepIcon(systemName: "waveform", animated: true)
            Text("Welcome to Yappy")
                .font(.largeTitle.bold())
                .foregroundStyle(Brand.ink)
            Text("Hold a hotkey, speak, and your words appear wherever your cursor is — transcribed entirely on this Mac. Let's get set up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink3)
            Spacer(minLength: 8)
            Button("Get Started") { step = 1 }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    private var microphone: some View {
        stepCard {
            StepIcon(systemName: "mic.fill", granted: micGranted)
            Text("Microphone access")
                .font(.title.bold())
                .foregroundStyle(Brand.ink)
            Text("Yappy needs your microphone to hear what you say. Audio never leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink3)

            if micGranted {
                // Live proof that Yappy hears you.
                VStack(spacing: 8) {
                    WaveformBarsView(
                        levels: levelModel.levels,
                        maxHeight: 26,
                        style: AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.75, blue: 0.55), Color.accentColor],
                            startPoint: .top, endPoint: .bottom
                        )),
                        glow: Color.accentColor.opacity(0.7)
                    )
                    .frame(height: 32)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    Text("Say something — Yappy is listening.")
                        .font(.caption)
                        .foregroundStyle(Brand.ink4)
                }
            } else if micStatus == .denied || micStatus == .restricted {
                // macOS already blocked the mic, so re-requesting won't re-prompt.
                // Route to the Microphone privacy pane instead of a dead button.
                VStack(spacing: 10) {
                    Text("macOS has blocked microphone access for Yappy. Turn it on in System Settings → Privacy & Security → Microphone, then come back here.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Brand.danger)
                    Button("Open System Settings") {
                        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.large)
                }
            } else {
                Button("Allow Microphone") {
                    Task {
                        _ = await requestMicrophone()
                        micGranted = AudioRecorder.hasPermission
                        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                        syncPreview()
                    }
                }
                .controlSize(.large)
            }

            Spacer(minLength: 8)
            Button(micGranted ? "Continue" : "Skip for now") { step = 2 }
                .keyboardShortcut(micGranted ? .defaultAction : .init(.escape))
        }
    }

    private var accessibility: some View {
        stepCard {
            StepIcon(systemName: "accessibility", granted: axGranted)
            Text("Accessibility access")
                .font(.title.bold())
                .foregroundStyle(Brand.ink)
            Text("This lets Yappy detect your hotkey and paste text into other apps. Enable Yappy in System Settings → Privacy & Security → Accessibility.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink3)

            if axGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Brand.ready)
            } else {
                Button("Open System Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
                .controlSize(.large)
            }

            Spacer(minLength: 8)
            Button(axGranted ? "Continue" : "Skip for now") { step = 3 }
                .keyboardShortcut(axGranted ? .defaultAction : .init(.escape))
        }
    }

    private var model: some View {
        stepCard {
            StepIcon(systemName: "cpu")
            Text("Your speech model")
                .font(.title.bold())
                .foregroundStyle(Brand.ink)
            Text("Yappy transcribes with a neural model running on this Mac's Neural Engine — nothing is sent to a server.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink3)

            modelStatus

            Spacer(minLength: 8)
            Button("Continue") { step = 4 }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    /// The final step — moved here from before try-it so the very first thing
    /// onboarding asks for is a hands-on win, not a preference. `applyUseCase`
    /// only presets Modes/seeds dictionary terms and mirrors picks into
    /// `Settings.useCases` (purely informational afterward); nothing about it
    /// depends on running before try-it, so the reorder is safe.
    private var useCase: some View {
        stepCard {
            StepIcon(systemName: "square.grid.2x2")
            Text("What will you use it for?")
                .font(.title.bold())
                .foregroundStyle(Brand.ink)
            Text("We'll preset a matching Mode and seed your dictionary — change anything later.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink3)

            UseCaseChips(picked: $pickedUseCases)
                .padding(.top, 2)

            Spacer(minLength: 8)
            VStack(spacing: 8) {
                Button("Finish") {
                    applyUseCase(pickedUseCases)
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                Button("Browse the commands") {
                    applyUseCase(pickedUseCases)
                    onBrowseCommands()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    /// A permission the try-it step still needs before dictation can work. If the
    /// user skipped the Microphone or Accessibility step, hitting the practice box
    /// would be silent dead air; the step names the gap and offers the fix instead
    /// of the dictation prompt. Mic is reported first when both are missing (you
    /// can't dictate at all without it), matching the setup step order.
    private enum MissingGrant {
        case microphone
        case accessibility
    }

    private var missingGrant: MissingGrant? {
        if !micGranted { return .microphone }
        if !axGranted { return .accessibility }
        return nil
    }

    private var tryIt: some View {
        stepCard(spacing: 14) {
            if tryItSucceeded {
                StepIcon(systemName: "checkmark.seal.fill", granted: true)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                Text("That's it — you're dictating")
                    .font(.title.bold())
                    .foregroundStyle(Brand.ink)
            } else {
                StepIcon(systemName: "sparkles")
                Text("Try it right here")
                    .font(.title.bold())
                    .foregroundStyle(Brand.ink)
            }

            // A skipped permission makes the practice box dead air — the single
            // most impression-forming moment of onboarding. When a grant is
            // missing (and we haven't already succeeded), swap the dictation
            // prompt + practice box for a callout that names the gap and offers
            // the same fix as the earlier steps. The permission poll clears
            // `missingGrant` live once granted, flipping this back automatically.
            if let missingGrant, !tryItSucceeded {
                permissionCallout(for: missingGrant)
            } else {
                tryItPractice
            }

            Spacer(minLength: 8)
            VStack(spacing: 8) {
                // Succeeded: one more step (what you'll use it for) before
                // finishing. Not yet succeeded: "Skip and finish" is a full
                // bypass straight out of onboarding, same as before this step
                // existed after try-it.
                Button(tryItSucceeded ? "Continue" : "Skip and finish") {
                    if tryItSucceeded {
                        step = 5
                    } else {
                        onFinish()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                Button("Browse the commands", action: onBrowseCommands)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        // Only a real Yappy voice dictation flips success. `lastDictationAt` is
        // stamped by AppDelegate the moment transcribed text is inserted, so
        // typing into the box never counts. Attached to the try-it card so it
        // observes only while this step is on screen — an earlier dictation
        // can't pre-trigger it.
        .onChange(of: appState.lastDictationAt) {
            guard !tryItSucceeded else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                tryItSucceeded = true
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: tryItSucceeded)
    }

    /// The normal try-it content: the dictation prompt, the practice box, and the
    /// "came from your voice" confirmation. Shown when both permissions are granted
    /// (or once a dictation has already landed).
    private var tryItPractice: some View {
        Group {
            Text(transcriptionService.modelState == .ready
                 ? "Click into the box, hold **Right ⌘**, and say: “Yappy makes dictation feel like magic.”"
                 : "The speech model is still getting ready — you can finish setup and try dictating in a minute.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink3)

            TextEditor(text: $tryItText)
                .font(.body)
                .foregroundStyle(Brand.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 88)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(tryItSucceeded ? Brand.ready : Color.white.opacity(0.10),
                                      lineWidth: tryItSucceeded ? 1.5 : 1)
                )
                .shadow(color: tryItSucceeded ? Brand.ready.opacity(0.25) : .clear, radius: 6)

            if tryItSucceeded {
                Label("Inserted by voice", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Brand.ready)
                    .transition(.opacity)
            } else {
                Text("We confirm the text actually came from your voice, not the keyboard.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.ink4)
            }
        }
    }

    /// Replaces the dictation prompt when a permission was skipped: names the
    /// missing grant, says why it's needed, and offers the same Open-System-Settings
    /// button the Microphone/Accessibility steps use. Mirrors those steps' visual
    /// idiom (danger-tinted copy + a large button) so the fix reads as continuous
    /// with the flow rather than an error.
    @ViewBuilder
    private func permissionCallout(for grant: MissingGrant) -> some View {
        VStack(spacing: 10) {
            switch grant {
            case .microphone:
                Text("Microphone access is still off")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Brand.danger)
                Text("Yappy can't hear you until the microphone is on, so dictation won't do anything yet.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.ink3)
                Button("Open System Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
                .controlSize(.large)
            case .accessibility:
                Text("Accessibility access is still off")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Brand.danger)
                Text("Yappy needs it to detect your hotkey and type text into other apps, so dictation can't land yet.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.ink3)
                Button("Open System Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch transcriptionService.modelState {
        case .ready:
            Label("Speech model ready", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(Brand.ready)
        case .downloading(let progress):
            VStack(spacing: 10) {
                VStack(spacing: 6) {
                    ProgressView(value: progress).frame(width: 240)
                    Text("Downloading speech model (443 MB, one time)…")
                        .font(.caption).foregroundStyle(Brand.ink4)
                }
                // The one-time download is the natural moment to teach a few
                // commands instead of leaving the wait as dead air — this
                // replaces the old separate "discovery" step that used to run
                // right before try-it.
                CommandMiniDeck()
            }
        case .loading, .notLoaded:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing speech model…").font(.caption).foregroundStyle(Brand.ink4)
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(Brand.danger)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await transcriptionService.warmUp() }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Glass step scaffolding

    /// Wraps a step's content in the shared frosted-glass surface so every step
    /// reads as one of the mockup's panels. Centers content; the caller supplies
    /// the icon tile, copy, controls, and a trailing `Spacer`.
    @ViewBuilder
    private func stepCard<Content: View>(
        spacing: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: spacing) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .glassPanel(cornerRadius: 22)
    }
}

/// The mockup's rounded-rect gradient icon tile. Orange gradient by default
/// (the `.ico` style); a green-tinted variant for "granted" / success states
/// (`.ico.ok`). Built on the same gradient-tile recipe as the window's brand mark.
private struct StepIcon: View {
    let systemName: String
    var granted: Bool = false
    var animated: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(fill)
            .frame(width: 58, height: 58)
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(icon)
            .shadow(color: shadow, radius: 14, y: 6)
    }

    private var icon: some View {
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
            .modifier(IconPulse(active: animated))
    }

    private var fill: LinearGradient {
        granted
            ? LinearGradient(colors: [Brand.ready, Color(red: 0.12, green: 0.62, blue: 0.46)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(red: 1, green: 0.68, blue: 0.51), Color.accentColor],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var shadow: Color {
        (granted ? Brand.ready : Color.accentColor).opacity(0.45)
    }
}

/// Applies the welcome icon's repeating variable-color pulse only when requested,
/// keeping the symbol-effect call out of a `@ViewBuilder` branch. Skipped under
/// Reduce Motion so the icon stays static while still conveying the step.
private struct IconPulse: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            content
        }
    }
}

/// The mockup's bottom progress indicator: one dot per step, the active one
/// elongated and orange (`.dots i.on`), the rest dim pills (`.dots i`).
private struct ProgressDots: View {
    let count: Int
    let active: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                let isActive = index == active
                Capsule()
                    .fill(isActive ? AnyShapeStyle(Color.accentColor)
                                   : AnyShapeStyle(Color.white.opacity(0.16)))
                    .frame(width: isActive ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: active)
    }
}

/// The mockup's `.chips` row: a wrapping set of multi-select use-case chips. A
/// selected chip is orange-tinted (`.chip.sel`); the rest are dim outlines.
private struct UseCaseChips: View {
    @Binding var picked: Set<UseCase>

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(UseCase.allCases) { useCase in
                UseCaseChip(
                    useCase: useCase,
                    isSelected: picked.contains(useCase)
                ) {
                    if picked.contains(useCase) {
                        picked.remove(useCase)
                    } else {
                        picked.insert(useCase)
                    }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: picked)
    }
}

/// A single selectable use-case chip (mockup `.chip` / `.chip.sel`).
private struct UseCaseChip: View {
    let useCase: UseCase
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: useCase.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                Text(useCase.displayName)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(isSelected ? Brand.ink : Brand.ink3)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.20))
                                     : AnyShapeStyle(Color.white.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55)
                                             : Color.white.opacity(0.12),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A hand-picked set of "here's what you can say" commands for the
/// model-download mini-deck. Looked up BY PHRASE from `CommandCatalog.sections`
/// — never copied — so this copy can't drift from what the app actually
/// understands (`CommandCatalogTests.testKnownParserPhrasesArePresent` already
/// guards these exact phrases staying in the catalog).
private enum CommandDeck {
    struct Card: Identifiable {
        let icon: String
        let phrase: String
        let effect: String
        var id: String { phrase }
    }

    /// Phrases to feature, in display order.
    private static let featuredPhrases = ["comma", "scratch that", "new paragraph", "press enter"]

    static let cards: [Card] = {
        let indexedEntries = CommandCatalog.sections.flatMap { section in
            section.entries.map { (icon: section.icon, entry: $0) }
        }
        return featuredPhrases.compactMap { phrase in
            guard let match = indexedEntries.first(where: { $0.entry.phrase == phrase }) else { return nil }
            return Card(icon: match.icon, phrase: match.entry.phrase, effect: match.entry.effect)
        }
    }()
}

/// Rotates through `CommandDeck.cards` every ~5s, cross-fading between them.
/// Shown alongside the model-download progress bar so the one-time wait
/// teaches a few phrases instead of just sitting on a bare spinner — replaces
/// the old separate "discovery" step that used to run right before try-it.
private struct CommandMiniDeck: View {
    @State private var index = 0
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var card: CommandDeck.Card? {
        CommandDeck.cards.indices.contains(index) ? CommandDeck.cards[index] : nil
    }

    var body: some View {
        Group {
            if let card {
                HStack(alignment: .top, spacing: 10) {
                    iconTile(card.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(card.phrase)”")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Brand.ink)
                        Text(card.effect)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Brand.ink4)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .id(card.id)
                .transition(.opacity)
            }
        }
        .padding(9)
        .frame(width: 260, alignment: .leading)
        // Fill only — no stroke border, matching this screen's convention that
        // a border reads as tappable; this card is informational only.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .animation(.easeInOut(duration: 0.4), value: index)
        .onReceive(timer) { _ in
            guard !CommandDeck.cards.isEmpty else { return }
            index = (index + 1) % CommandDeck.cards.count
        }
        .accessibilityElement(children: .combine)
    }

    /// The small icon tile, matching the rest of this screen's card language.
    private func iconTile(_ symbolName: String) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 1)
            )
    }
}

/// Minimal flow layout: lays children left to right, wrapping to a new row when
/// the next child would overflow the proposed width. Used for the use-case chips
/// so the row reflows if labels or window width change (SwiftUI has no built-in
/// wrap on the macOS 14 deployment target).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
