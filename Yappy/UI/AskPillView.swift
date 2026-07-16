//
//  AskPillView.swift
//  Yappy
//
//  The Ask pill: while listening/transcribing it's a compact capsule that
//  echoes the dictation pill; when content arrives it grows into a wider
//  dark-glass card showing the question, live research steps, and the answer.
//  Answers render block-aware (paragraphs, tables, code, lists, images) via
//  AskAnswerBlock — inline markdown alone leaves tables as raw pipes.
//  Voice-only: no typed input row, no approval block (Ask has no computer
//  tools to approve).
//

import AppKit
import SwiftUI

struct AskPillView: View {
    @ObservedObject var controller: AskController
    @ObservedObject var settings: Settings
    var onSizeChange: (CGSize) -> Void = { _ in }

    private let compactWidth: CGFloat = 240
    private let cardWidth: CGFloat = 440
    /// Wide tables/code can grow the card up to this before falling back to
    /// internal horizontal scrolling.
    private let maxCardWidth: CGFloat = 760
    private let expandedRadius: CGFloat = 24
    private let compactHeight: CGFloat = 46

    /// Natural width of the widest non-wrapping block (table/code) in the
    /// current answer, reported via preference. 0 = none.
    @State private var widestBlock: CGFloat = 0
    @State private var copied = false

    /// Content-driven card width: wide tables expand the card to fit exactly
    /// (block width + card padding), clamped to [cardWidth, maxCardWidth].
    private var expandedWidth: CGFloat {
        guard widestBlock > 0 else { return cardWidth }
        return min(maxCardWidth, max(cardWidth, widestBlock + 44))
    }

    // MARK: - Palette (matches RecordingPillView's molten glass)
    private var accent: Color { .accentColor }
    private let warm = Color(red: 1.0, green: 0.8, blue: 0.62)
    private let textPrimary = Color.white.opacity(0.95)
    private let textSecondary = Color.white.opacity(0.66)
    private let textTertiary = Color.white.opacity(0.4)
    private let critical = Color(red: 1.0, green: 0.42, blue: 0.42)

    var body: some View {
        Group {
            if let run = controller.run, run.status != .idle {
                styledCard(run)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Widest-block preference flows up from table/code blocks; feed it into
        // the width and reset it whenever a new run begins.
        .onPreferenceChange(AskBlockWidthKey.self) { widestBlock = $0 }
        .onChange(of: controller.run?.id) { _, _ in
            widestBlock = 0
            copied = false
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: controller.run?.status)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: controller.run?.steps.count ?? 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: expandedWidth)
    }

    /// The card with its full styling chain — split out of `body` to keep the
    /// expression small enough for the type checker.
    private func styledCard(_ run: AskRun) -> some View {
        card(for: run)
            .frame(width: isCompact(run) ? compactWidth : expandedWidth)
            .background(glass(for: run))
            // Glass rim: bright where light catches the top edge, fading out,
            // warmed by the accent at the base — same language as the
            // dictation pill's capsule.
            .overlay(shape(for: run)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.30), .white.opacity(0.07), accent.opacity(0.20)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
            .clipShape(shape(for: run))
            // Glow rim, same treatment as the dictation pill — from the first
            // listening moment all the way through the expanded answer card,
            // so the effect carries over as the capsule grows (the ring is
            // mounted once and its shape morphs with the card's spring).
            // Failure/cancel cards drop it: a rainbow around an error reads
            // wrong. Placed AFTER the clip: the halo blurs outward past the
            // shape's edge, and clipShape would slice it off. The 40pt shadow
            // margin gives it room to bleed.
            .overlay {
                if run.status != .failed, run.status != .cancelled {
                    ListeningGlowRing(shape: shape(for: run), style: settings.listeningGlowStyle)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 22, y: 9)
            .background(sizeReader)
            .onHover { controller.pillHovered = $0 }
            // Clicking into the card (selecting text to copy, or just a
            // click) pins it — it then stays until ✕ / Esc / next Ask.
            .simultaneousGesture(TapGesture().onEnded {
                if !isCompact(run), run.status.isTerminal { controller.pinFromCardTap() }
            })
            .onExitCommand { controller.abort() }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Capsule while capturing, card once content is on the way.
    private func isCompact(_ run: AskRun) -> Bool {
        run.status == .preparing || run.status == .listening || run.status == .transcribing
    }

    private func shape(for run: AskRun) -> RoundedRectangle {
        RoundedRectangle(
            cornerRadius: isCompact(run) ? compactHeight / 2 : expandedRadius,
            style: .continuous
        )
    }

    private func glass(for run: AskRun) -> some View {
        shape(for: run)
            .fill(LinearGradient(
                colors: [Color(red: 0.165, green: 0.155, blue: 0.15),
                         Color(red: 0.075, green: 0.068, blue: 0.062)],
                startPoint: .top, endPoint: .bottom))
            .overlay(shape(for: run).fill(accent.opacity(0.045)))
    }

    private var sizeReader: some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { _, newValue in
                onSizeChange(newValue)
            }
        }
    }

    // MARK: - Card content by status

    @ViewBuilder
    private func card(for run: AskRun) -> some View {
        switch run.status {
        case .preparing:
            compactRow {
                PulsingDot(tint: warm)
                Text("Getting ready…").font(.system(size: 13)).foregroundStyle(textSecondary)
            }
        case .listening:
            compactRow {
                LevelBars(levels: controller.audioLevels, tint: warm)
                Text("Listening…").font(.system(size: 13)).foregroundStyle(textSecondary)
            }
        case .transcribing:
            compactRow {
                PulsingDot(tint: warm)
                Text("Transcribing…").font(.system(size: 13)).foregroundStyle(textSecondary)
            }
        default:
            VStack(alignment: .leading, spacing: 15) {
                priorQuestionChain(run)
                header(run)
                statusBlock(run)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 19)
        }
    }

    private func compactRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { Spacer(minLength: 0); content(); Spacer(minLength: 0) }
            .padding(.horizontal, 16)
            .frame(height: compactHeight)
    }

    private func header(_ run: AskRun) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if !run.rawTranscript.isEmpty {
                Text(run.rawTranscript)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let label = run.modelLabel, run.status != .transcribing {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.14)))
            }
            if controller.pillPinned {
                // Click to unpin — the linger countdown resumes.
                Button { controller.pillPinned = false } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.9))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(accent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Pinned — click to let it auto-dismiss")
                .accessibilityLabel("Pinned — tap to unpin")
                .transition(.scale.combined(with: .opacity))
            }
            Button { controller.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .animation(.easeOut(duration: 0.15), value: controller.pillPinned)
    }

    @ViewBuilder
    private func priorQuestionChain(_ run: AskRun) -> some View {
        if !run.turns.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if run.turns.count > 3 {
                    Text("…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(textTertiary)
                        .lineLimit(1)
                }
                ForEach(Array(run.turns.suffix(3).enumerated()), id: \.offset) { _, turn in
                    Text("› \(turn.question)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder
    private func statusBlock(_ run: AskRun) -> some View {
        switch run.status {
        case .completed:
            answerView(run)
        case .failed, .cancelled:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: run.status == .failed ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(run.status == .failed ? critical : textTertiary)
                Text(answerText(run))
                    .font(.system(size: 13))
                    .foregroundStyle(textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !run.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    retryButton(title: "Try again")
                }
            }
        default:
            workingBlock(run)
        }
    }

    private func answerText(_ run: AskRun) -> String {
        let text = run.result ?? run.answerText ?? ""
        return text.isEmpty ? "Done." : text
    }

    @ViewBuilder
    private func answerView(_ run: AskRun) -> some View {
        let text = answerText(run)
        let sources = AskSources.extract(from: text)
        let rendered = AskAnswerContent(
            text: text, accent: accent,
            textPrimary: textPrimary, textSecondary: textSecondary,
            textTertiary: textTertiary
        )
        VStack(alignment: .leading, spacing: 12) {
            if text.count > 700 {
                ScrollView(.vertical, showsIndicators: false) { rendered }.frame(maxHeight: 340)
            } else {
                rendered
            }
            if !sources.isEmpty {
                AskSourceChips(sources: sources, textSecondary: textSecondary)
            }
            answerActionRow(run: run, text: text)
            if let caption = controller.fallbackCaption {
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption = controller.transientCaption {
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            answersPrivacyReceipt(run: run)
        }
    }

    private func answerActionRow(run: AskRun, text: String) -> some View {
        HStack(spacing: 8) {
            Button {
                controller.insertAnswer()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "text.insert")
                        .font(.system(size: 10, weight: .medium))
                    Text("Insert")
                        .font(.system(size: 11))
                }
                .foregroundStyle(textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 11))
                }
                .foregroundStyle(textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)

            speakButton()

            retryButton(title: "Ask again")
            Spacer(minLength: 0)
            if let latency = run.latencySeconds, let label = run.modelLabel {
                Text(String(format: "%.1fs · %@", latency, label))
                    .font(.system(size: 10))
                    .foregroundStyle(textTertiary)
            }
        }
    }

    @ViewBuilder
    private func speakButton() -> some View {
        if controller.speakAvailable {
            Button {
                // The card-wide tap-to-pin gesture (styledCard) also fires on this
                // tap, in NONDETERMINISTIC order relative to this action — reading
                // `pillPinned` directly here misclassified a gesture-first pin as
                // deliberate and left Stop pinning the card. The timestamped check
                // recognizes a pin born from this same click in either order; the
                // async unpin then runs after whichever half fires second.
                let wasPinned = controller.pillPinnedBeforeCurrentClick
                switch controller.speakingPhase {
                case .idle:
                    controller.speakCurrentAnswer()
                case .synthesizing, .speaking:
                    controller.stopSpeakingNow()
                }
                if !wasPinned {
                    DispatchQueue.main.async { controller.pillPinned = false }
                }
            } label: {
                HStack(spacing: 4) {
                    switch controller.speakingPhase {
                    case .idle:
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 10, weight: .medium))
                    case .synthesizing:
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 10, height: 10)
                    case .speaking:
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                    Text(controller.speakingPhase == .speaking ? "Stop" : "Speak")
                        .font(.system(size: 11))
                }
                .foregroundStyle(textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
    }

    private func answersPrivacyReceipt(run: AskRun) -> some View {
        Group {
            if !UserDefaults.standard.bool(forKey: "com.yappy.answersReceiptShown") {
                Text("Answered via your own \(run.modelLabel ?? "model") account — dictation stays on-device.")
                    .font(.system(size: 11))
                    .foregroundStyle(textTertiary)
                    .onAppear {
                        UserDefaults.standard.set(true, forKey: "com.yappy.answersReceiptShown")
                    }
            }
        }
    }

    private func retryButton(title: String) -> some View {
        Button { controller.retry() } label: {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private func workingBlock(_ run: AskRun) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(run.steps.suffix(4))) { step in
                ActionRow(step: step, accent: accent, warm: warm,
                          textPrimary: textPrimary, textSecondary: textSecondary,
                          textTertiary: textTertiary, critical: critical)
            }

            // Suppress streamed text that is (so far) nothing but process
            // narration — the animated "Searching the web" row above already
            // says it, better.
            if let streaming = run.answerText, !streaming.isEmpty,
               !AskAnswerBlock.isNarrationOnly(streaming) {
                AskAnswerContent(
                    text: streaming, accent: accent,
                    textPrimary: textPrimary, textSecondary: textSecondary,
                    textTertiary: textTertiary
                )
            }

            HStack(spacing: 8) {
                if run.steps.isEmpty, (run.answerText ?? "").isEmpty {
                    PulsingDot(tint: warm)
                    Text("Thinking…").font(.system(size: 12)).foregroundStyle(textSecondary)
                }
                Spacer(minLength: 0)
                Button { controller.abort() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop answering")
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        if let cached = markdownCache[text] { return cached }
        // Streaming re-invalidates block views on every delta; without a
        // bound, each paragraph/cell would re-parse from scratch per render.
        if markdownCache.count >= 512 { markdownCache.removeAll() }
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        // Model-authored links open on a single click - only https survives
        // (no custom URL schemes, no plain http). The text itself stays.
        for run in attributed.runs where run.link != nil {
            if run.link?.scheme?.lowercased() != "https" {
                attributed[run.range].link = nil
            }
        }
        markdownCache[text] = attributed
        return attributed
    }

    /// Bounded cache for inline markdown fragments inside block views.
    @MainActor private static var markdownCache: [String: AttributedString] = [:]
}

// MARK: - Source chips

/// Compact host capsules for cited links — shared by the pill and history.
struct AskSourceChips: View {
    let sources: [AskSource]
    var textSecondary: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sources) { source in
                Button {
                    NSWorkspace.shared.open(source.url)
                } label: {
                    Text(displayHost(source.host))
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(source.host)")
            }
            Spacer(minLength: 0)
        }
    }

    private func displayHost(_ host: String) -> String {
        guard host.count > 28 else { return host }
        return "\(host.prefix(13))…\(host.suffix(12))"
    }
}

// MARK: - Block-aware answer rendering

/// Natural width of the widest non-wrapping block (table/code) in an answer.
/// Blocks measure themselves inside their horizontal scrollers (where they lay
/// out at ideal width) and the pill widens to fit, up to its cap.
struct AskBlockWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BlockWidthReporter: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: AskBlockWidthKey.self, value: geo.size.width)
        }
    }
}

/// Caches the parsed block list for the exact text last seen. Streaming
/// answers re-invalidate this view's body on every delta AND on unrelated
/// state changes elsewhere in the pill (audio levels, hover, speaking
/// phase), so without this the full accumulated markdown would re-parse
/// on every invalidation -- O(n^2) main-thread work over a stream. Exact
/// string-equality key means staleness is impossible by construction.
@MainActor
private enum AnswerBlockMemo {
    static var lastInput: String?
    static var lastBlocks: [AskAnswerBlock.Identified] = []
    static func blocks(for text: String) -> [AskAnswerBlock.Identified] {
        if text == lastInput { return lastBlocks }
        let parsed = AskAnswerBlock.identified(AskAnswerBlock.strippingLeadingNarration(text))
        lastInput = text
        lastBlocks = parsed
        return parsed
    }
}

/// Renders an answer as typed blocks: paragraphs (inline markdown), pipe
/// tables (Grid), fenced code (mono box), lists, and images. Internal (not
/// private) so the main window's Ask history reuses it with its own palette.
struct AskAnswerContent: View {
    var text: String
    var accent: Color
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color? = nil

    private var tertiary: Color { textTertiary ?? textSecondary.opacity(0.6) }

    var body: some View {
        // Narration strip runs at parse time (via AnswerBlockMemo) so it also
        // cleans answers saved to history before the filter existed.
        let blocks = AnswerBlockMemo.blocks(for: text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { item in
                blockView(item.block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AskAnswerBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(AskPillView.markdown(text))
                .font(.system(size: 14.5))
                .foregroundStyle(textPrimary)
                .lineSpacing(6)
                .tint(accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(AskPillView.markdown(text))
                .font(.system(size: level <= 2 ? 16 : 15, weight: .semibold))
                .foregroundStyle(textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

        case .code(let language, let code):
            CodeBlockView(
                language: language,
                code: code,
                textPrimary: textPrimary,
                textTertiary: tertiary
            )

        case .table(let header, let rows):
            tableView(header: header, rows: rows)

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.85))
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(AskPillView.markdown(item))
                            .font(.system(size: 14.5))
                            .foregroundStyle(textPrimary)
                            .lineSpacing(5)
                            .tint(accent)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .image(let alt, let url):
            RemoteImageBlock(alt: alt, url: url, textSecondary: textSecondary)
        }
    }

    private func tableView(header: [String]?, rows: [[String]]) -> some View {
        let columns = max(header?.count ?? 0, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if let header {
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(AskPillView.markdown(column < header.count ? header[column] : ""))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(textSecondary)
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.12))
                        .gridCellUnsizedAxes(.horizontal)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(AskPillView.markdown(column < row.count ? row[column] : ""))
                                .font(.system(size: 13))
                                .foregroundStyle(textPrimary)
                                .tint(accent)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(BlockWidthReporter())
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Code block with copy

private struct CodeBlockView: View {
    let language: String?
    let code: String
    var textPrimary: Color
    var textTertiary: Color

    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .padding(.top, language?.isEmpty == false ? 22 : 0)
                    .background(BlockWidthReporter())
            }

            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(textTertiary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Click-to-load remote images

/// Defers the network fetch until the user explicitly taps — answers may embed
/// third-party image URLs the user never approved.
private struct RemoteImageBlock: View {
    let alt: String
    let url: URL
    var textSecondary: Color

    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo")
                            .font(.system(size: 12))
                            .foregroundStyle(textSecondary)
                            .padding(10)
                    case .empty:
                        ProgressView().controlSize(.small).padding(14)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Button { loaded = true } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "photo")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alt.isEmpty ? "Load image" : "Load image — \(alt)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.white.opacity(0.95))
                            if let host = url.host {
                                Text(host)
                                    .font(.system(size: 11))
                                    .foregroundStyle(textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 200)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Small pieces

private struct LevelBars: View {
    var levels: [Double]
    var tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.suffix(9).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 4 + CGFloat(max(0, min(1, level))) * 15)
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

private struct PulsingDot: View {
    var tint: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.0 : 0.55)
            .opacity(pulse ? 1.0 : 0.45)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

/// One row of the research feed: kind icon + title, dimming once done. A
/// running row breathes (icon + text pulse together); a running THINKING row
/// additionally cycles through a slew of words so the same label never
/// bombards ("Thinking", "Pondering", …).
private struct ActionRow: View {
    var step: AskRunStep
    var accent: Color
    var warm: Color
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var critical: Color

    @State private var pulse = false

    private static let thinkingWords = [
        "Thinking", "Pondering", "Reasoning", "Considering",
        "Connecting the dots", "Weighing sources", "Mulling it over",
    ]

    var body: some View {
        let running = step.state == .running
        let failed = step.state == .failed
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(failed ? critical : (running ? accent : textTertiary))
                .frame(width: 15)
                .opacity(running ? (pulse ? 1.0 : 0.45) : 1)
            titleView(running: running)
                .font(.system(size: 12.5))
                .foregroundStyle(running ? textPrimary : textSecondary)
                .lineLimit(step.kind == .narration ? 2 : 1)
                .truncationMode(.tail)
                .opacity(running ? (pulse ? 1.0 : 0.6) : 1)
            Spacer(minLength: 0)
        }
        .onAppear { startPulseIfRunning() }
        .onChange(of: step.state) { _, _ in startPulseIfRunning() }
    }

    private func startPulseIfRunning() {
        guard step.state == .running else { pulse = false; return }
        pulse = false
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
    }

    /// A running thinking row cycles its word every ~1.6s with a soft fade;
    /// everything else shows its stored title.
    @ViewBuilder
    private func titleView(running: Bool) -> some View {
        if running, step.kind == .thinking {
            TimelineView(.periodic(from: .now, by: 1.6)) { context in
                let index = Int(context.date.timeIntervalSinceReferenceDate / 1.6) % Self.thinkingWords.count
                Text(Self.thinkingWords[index])
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: index)
            }
        } else {
            Text(step.title)
        }
    }

    private var icon: String {
        switch step.kind {
        case .thinking: "brain"
        case .search: "magnifyingglass"
        case .tool: "wrench.adjustable"
        case .command: "terminal"
        case .narration: "text.alignleft"
        case .generic: "circle.dotted"
        }
    }
}
