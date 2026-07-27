//
//  SelectionTransformView.swift
//  Yappy
//
//  The floating "Voice Edit" card. While listening it's a compact glass capsule
//  echoing the dictation pill; once a transform is ready it grows into a
//  dark-glass card that stacks the original selection (dimmed) over the result
//  (bright) with the spoken instruction between them, and Replace / Try again /
//  Cancel actions. Preview-first by design: the user always sees the change
//  before it lands, never an invisible in-place mutation.
//

import AppKit
import Combine
import SwiftUI

struct SelectionTransformView: View {
    @ObservedObject var controller: SelectionTransformController
    @ObservedObject var settings: Settings
    var onSizeChange: (CGSize) -> Void = { _ in }

    private let compactWidth: CGFloat = 240
    private let cardWidth: CGFloat = 460
    private let expandedRadius: CGFloat = 24
    private let compactHeight: CGFloat = 46

    // Palette — matches AskPillView / RecordingPillView molten glass.
    private var accent: Color { .accentColor }
    private let warm = Color(red: 1.0, green: 0.8, blue: 0.62)
    private let textPrimary = Color.white.opacity(0.95)
    private let textSecondary = Color.white.opacity(0.66)
    private let textTertiary = Color.white.opacity(0.4)
    private let critical = Color(red: 1.0, green: 0.42, blue: 0.42)

    /// Natural height of the two panes, measured so the scroll region can size to
    /// content up to `maxPanesHeight`, then scroll.
    @State private var panesHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isVisible {
                styledCard
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85), value: controller.stage)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: controller.caption)
    }

    private var isVisible: Bool {
        controller.stage != .idle && controller.stage != .cancelled || controller.caption != nil
    }

    private var isCompact: Bool {
        switch controller.stage {
        case .capturing, .listening, .transforming: return true
        case .idle, .cancelled: return controller.caption != nil
        case .preview, .replacing: return false
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isCompact ? compactHeight / 2 : expandedRadius, style: .continuous)
    }

    private var styledCard: some View {
        content
            .frame(width: isCompact ? compactWidth : cardWidth)
            .background(glass)
            .overlay(shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.07), accent.opacity(0.20)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1))
            .clipShape(shape)
            // Glow while listening only — a rainbow around a static preview reads busy.
            .overlay {
                if controller.stage == .listening {
                    ListeningGlowRing(shape: shape, style: settings.listeningGlowStyle)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 22, y: 9)
            .background(sizeReader)
            .onExitCommand { controller.cancel() }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var glass: some View {
        shape
            .fill(LinearGradient(
                colors: [Color(red: 0.165, green: 0.155, blue: 0.15),
                         Color(red: 0.075, green: 0.068, blue: 0.062)],
                startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(accent.opacity(0.045)))
    }

    private var sizeReader: some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { _, newValue in
                onSizeChange(newValue)
            }
        }
    }

    // MARK: - Content by stage

    @ViewBuilder
    private var content: some View {
        switch controller.stage {
        case .listening:
            compactRow {
                PulsingDot(tint: warm)
                Text("Listening…").font(.system(size: 13)).foregroundStyle(textSecondary)
            }
        case .capturing:
            compactRow {
                PulsingDot(tint: warm)
                Text("Reading selection…").font(.system(size: 13)).foregroundStyle(textSecondary)
            }
        case .transforming:
            compactRow {
                if controller.isGenerating {
                    ProgressView().controlSize(.small).tint(warm)
                } else {
                    PulsingDot(tint: warm)
                }
                Text(controller.isGenerating ? "Thinking…" : "Transforming…")
                    .font(.system(size: 13)).foregroundStyle(textSecondary)
            }
        case .preview, .replacing:
            previewCard
        case .idle, .cancelled:
            if let caption = controller.caption {
                captionRow(caption)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private func compactRow<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        HStack(spacing: 8) { Spacer(minLength: 0); inner(); Spacer(minLength: 0) }
            .padding(.horizontal, 16)
            .frame(height: compactHeight)
    }

    private func captionRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "text.cursor")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(textTertiary)
            Text(text).font(.system(size: 12.5)).foregroundStyle(textSecondary)
                .lineLimit(2).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: compactHeight)
    }

    // MARK: - Preview card

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            if !controller.instruction.isEmpty {
                Text("› \(controller.instruction)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(warm.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The before/after panes scroll within a capped region so a long
            // selection stays reviewable and never grows the card past the screen.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 13) {
                    pane(label: "Selection", text: controller.original, dimmed: true)
                    pane(label: "Result", text: controller.result, dimmed: false)
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PanesHeightKey.self, value: geo.size.height)
                })
            }
            .frame(height: min(panesHeight, maxPanesHeight))
            .onPreferenceChange(PanesHeightKey.self) { panesHeight = $0 }
            actions
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 17)
    }

    /// Cap for the scrollable panes region — keeps the whole card comfortably
    /// under the panel's 70%-of-screen ceiling (header/instruction/buttons take
    /// the rest).
    private var maxPanesHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        return max(160, screenHeight * 0.52)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Text("Voice Edit")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(textPrimary)
            Spacer(minLength: 0)
            Button { controller.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
        }
    }

    private func pane(label: String, text: String, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(textTertiary)
                .kerning(0.4)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 13))
                .foregroundStyle(dimmed ? textSecondary : textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(dimmed ? 0.03 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(dimmed ? Color.white.opacity(0.05) : accent.opacity(0.18)))
        )
    }

    private var actions: some View {
        HStack(spacing: 9) {
            Button { controller.replace() } label: {
                Text("Replace")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Button { controller.tryAgain() } label: {
                Text("Try again")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            Button { controller.cancel() } label: {
                Text("Cancel")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Floating panel

/// Owns the floating Voice Edit card panel. Bottom-centered and nonactivating,
/// so the app you were editing keeps focus (and its selection) for the paste.
/// Click-through while capturing/listening (no controls); interactive once the
/// preview's buttons are on screen.
@MainActor
final class SelectionTransformPanelController {
    private var panel: NSPanel?
    private let controller: SelectionTransformController
    private let settings: Settings
    private var cancellables: Set<AnyCancellable> = []
    private var activeScreen: NSScreen?
    private var lastContentSize: CGSize = .zero
    private let shadowMargin: CGFloat = 40
    private let bottomLift: CGFloat = 28

    init(controller: SelectionTransformController, settings: Settings) {
        self.controller = controller
        self.settings = settings
        // Any state that changes visibility/interactivity: stage or caption.
        controller.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reflect() }
            .store(in: &cancellables)
        controller.$caption
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reflect() }
            .store(in: &cancellables)
    }

    func prewarm() {
        if panel == nil { panel = makePanel() }
    }

    private func reflect() {
        if controller.stage == .replacing {
            // Tear the card down IMMEDIATELY (no fade): while the panel is up
            // it can hold key-window status from the Replace click, and a key
            // panel eats the synthetic Cmd+V meant for the origin app. The
            // paste starts after a settle delay precisely so this orderOut
            // (and the key handoff back to the origin) wins the race.
            panel?.orderOut(nil)
        } else if isVisible {
            showIfNeeded()
            updateMouseEvents()
        } else {
            hide()
        }
    }

    private var isVisible: Bool {
        (controller.stage != .idle && controller.stage != .cancelled && controller.stage != .replacing)
            || controller.caption != nil
    }

    private func updateMouseEvents() {
        // Interactive only once the preview's buttons exist.
        let interactive = controller.stage == .preview
        panel?.ignoresMouseEvents = !interactive
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.adoptYappyDarkAppearance()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // The card hosts BUTTONS only — it must never become the key window.
        // A nonactivating panel that takes key status on click steals the
        // synthetic Cmd+V from the origin app: Replace posted the paste, the
        // panel ate it, and the replacement silently never landed (live-caught
        // 2026-07-16: "Paste NEVER CONFIRMED after 24 polls").
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: SelectionTransformView(
            controller: controller,
            settings: settings,
            onSizeChange: { [weak self] size in self?.onContentSize(size) }
        ))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func showIfNeeded() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        activeScreen = screenForMouse()
        resizePanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isVisible { panel.orderOut(nil) }
            }
        })
    }

    private func onContentSize(_ size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        let changed = abs(size.width - lastContentSize.width) > 0.5
            || abs(size.height - lastContentSize.height) > 0.5
        lastContentSize = size
        if changed { resizePanel() }
    }

    private func resizePanel() {
        guard let panel else { return }
        let screen = activeScreen ?? screenForMouse() ?? NSScreen.main
        guard let screen else { return }
        let size = lastContentSize == .zero ? CGSize(width: 380, height: 60) : lastContentSize
        let visible = screen.visibleFrame
        let width = min(size.width + shadowMargin * 2, visible.width - 24)
        // Belt-and-suspenders to the view's own scroll cap: never let the panel
        // exceed 70% of the screen height (the panes scroll within it).
        let height = min(size.height + shadowMargin * 2, visible.height * 0.7)
        let x = visible.midX - width / 2
        let y = visible.minY + Constants.pillBottomMargin + bottomLift - shadowMargin
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: false)
        }
    }

    private func screenForMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

// MARK: - Small shared bits

/// Reports the natural height of the before/after panes so the scroll region can
/// size to content up to a cap.
private struct PanesHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A gently breathing dot for the compact capture states (file-local; mirrors
/// the dictation/Ask pills' indicator). Solid under Reduce Motion.
private struct PulsingDot: View {
    var tint: Color
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .scaleEffect((pulse || reduceMotion) ? 1.0 : 0.55)
            .opacity((pulse || reduceMotion) ? 1.0 : 0.45)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}
