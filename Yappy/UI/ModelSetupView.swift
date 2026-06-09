//
//  ModelSetupView.swift
//  Yappy
//

import SwiftUI

/// First-run experience while the Parakeet model downloads/loads.
/// Also reused as a status row inside Settings.
struct ModelSetupView: View {
    @ObservedObject var transcriptionService: ParakeetTranscriptionService

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Setting up Yappy")
                .font(.title2.bold())

            switch transcriptionService.modelState {
            case .downloading(let progress):
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 260)
                    Text("Downloading speech model (443 MB, one time)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .loading, .notLoaded:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading speech model…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                Label("Ready to dictate", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(spacing: 8) {
                    Label("Setup failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        Task { await transcriptionService.warmUp() }
                    }
                }
            }

            Text("Transcription runs entirely on this Mac. Your voice never leaves it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(width: 380)
    }
}

/// Compact model status row for Settings.
struct ModelStatusRow: View {
    @ObservedObject var transcriptionService: ParakeetTranscriptionService

    var body: some View {
        HStack {
            Label {
                Text("Speech model (Parakeet)")
            } icon: {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
            Spacer()
            Text(transcriptionService.modelState.statusDescription)
                .foregroundStyle(.secondary)
            if case .failed = transcriptionService.modelState {
                Button("Retry") {
                    Task { await transcriptionService.warmUp() }
                }
            }
        }
    }

    private var iconName: String {
        switch transcriptionService.modelState {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle"
        case .loading, .notLoaded: return "hourglass"
        }
    }

    private var iconColor: Color {
        switch transcriptionService.modelState {
        case .ready: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}
