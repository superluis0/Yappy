//
//  DictionaryTrainingView.swift
//  Yappy
//

import SwiftUI

/// Teaches Yappy how the user says a term: records a few takes, transcribes them
/// with boosting OFF (pure model output) to discover the model's mishearings,
/// and offers those as aliases. Audio is analyzed in memory and never saved.
struct DictionaryTrainingView: View {
    let term: DictionaryTerm
    @ObservedObject var transcriptionService: ParakeetTranscriptionService
    /// Called with the user-approved alias candidates.
    let onComplete: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    private struct Prompt {
        let instruction: String
        let template: String?   // "{}" placeholder for sentence takes; nil = isolated
    }

    private var prompts: [Prompt] {
        [
            Prompt(instruction: "Say \u{201c}\(term.text)\u{201d}", template: nil),
            Prompt(instruction: "Say \u{201c}\(term.text)\u{201d} again", template: nil),
            Prompt(instruction: "Once more: \u{201c}\(term.text)\u{201d}", template: nil),
            Prompt(instruction: "Now in a sentence: \u{201c}I work with \(term.text) every day\u{201d}",
                   template: "i work with {} every day"),
        ]
    }

    @State private var recorder = AudioRecorder()
    @State private var stepIndex = 0
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var isolated: [String] = []
    @State private var sentences: [(template: String, transcript: String)] = []
    @State private var candidates: [String] = []
    @State private var phase: Phase = .recording
    @State private var lastTakeEmpty = false

    private enum Phase { case recording, reviewing }

    var body: some View {
        VStack(spacing: 20) {
            header
            Divider()
            switch phase {
            case .recording: recordingStep
            case .reviewing: review
            }
        }
        .padding(24)
        .frame(width: 460, height: 460)
        .task { _ = await AudioRecorder.requestPermission() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            Text("Teach \u{201c}\(term.text)\u{201d}")
                .font(.title2.bold())
            Text("Recordings are analyzed in memory and never saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Recording

    private var recordingStep: some View {
        VStack(spacing: 18) {
            Text("Take \(stepIndex + 1) of \(prompts.count)")
                .font(.caption).foregroundStyle(.secondary)

            Text(prompts[stepIndex].instruction)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 60)

            if !modelReady {
                Label("Waiting for the speech model to finish loading…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else if isProcessing {
                ProgressView().controlSize(.small)
            } else {
                Button(action: toggleRecording) {
                    Label(isRecording ? "Stop" : "Record",
                          systemImage: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(isRecording ? .red : .accentColor)
            }

            if lastTakeEmpty {
                Text("Didn't catch that — try again, a little louder.")
                    .font(.caption).foregroundStyle(.orange)
            }

            Spacer()
            Button("Skip", action: finishToReview)
                .buttonStyle(.borderless)
                .disabled(isRecording || isProcessing)
        }
    }

    private var modelReady: Bool { transcriptionService.modelState == .ready }

    private func toggleRecording() {
        if isRecording {
            isRecording = false
            let samples = recorder.stopRecording()
            processTake(samples)
        } else {
            lastTakeEmpty = false
            guard recorder.startRecording() else { return }
            isRecording = true
        }
    }

    private func processTake(_ samples: [Float]) {
        guard AudioRecorder.containsSpeech(samples) else {
            lastTakeEmpty = true
            return
        }
        isProcessing = true
        let prompt = prompts[stepIndex]
        Task {
            let text = (try? await transcriptionService.transcribe(samples)) ?? ""
            await MainActor.run {
                isProcessing = false
                if let template = prompt.template {
                    sentences.append((template: template, transcript: text))
                } else {
                    isolated.append(text)
                }
                advance()
            }
        }
    }

    private func advance() {
        if stepIndex + 1 < prompts.count {
            stepIndex += 1
        } else {
            finishToReview()
        }
    }

    private func finishToReview() {
        candidates = AliasMiner.mineCandidates(forTerm: term.text, isolated: isolated, sentences: sentences)
        phase = .reviewing
    }

    // MARK: - Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 30)).foregroundStyle(.green)
                    Text("Already recognized")
                        .font(.headline)
                    Text("Yappy heard \u{201c}\(term.text)\u{201d} correctly every time — no extra training needed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Yappy sometimes hears \u{201c}\(term.text)\u{201d} as:")
                    .font(.headline)
                Text("Keep the ones that look right; these will be corrected back to \u{201c}\(term.text).\u{201d}")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(candidates, id: \.self) { candidate in
                        HStack(spacing: 6) {
                            Text(candidate).lineLimit(1)
                            Button {
                                candidates.removeAll { $0 == candidate }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                    }
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(candidates.isEmpty ? "Done" : "Save") {
                    if !candidates.isEmpty { onComplete(candidates) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
