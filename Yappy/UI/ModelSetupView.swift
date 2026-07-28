//
//  ModelSetupView.swift
//  Yappy
//

import SwiftUI

/// First-run experience while the speech model downloads/loads.
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
                    if let progress {
                        ProgressView(value: progress)
                            .frame(width: 260)
                    } else {
                        ProgressView()
                            .frame(width: 260)
                    }
                    Text("Downloading speech model (one time)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .loading, .notLoaded:
                VStack(spacing: 8) {
                    ProgressView()
                    Text(transcriptionService.modelState.userFacingLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                Label("Ready to dictate", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(spacing: 8) {
                    Label(transcriptionService.modelState.userFacingLabel,
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
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

/// Compact model status row for Settings. Renders as a `SettingRow` so it is
/// the same row as everything else in the card it sits in — 34pt icon chip,
/// branded status colors, identical padding — instead of a bare `Label` stack.
struct ModelStatusRow: View {
    @ObservedObject var settings: Settings
    @ObservedObject var transcriptionService: ParakeetTranscriptionService

    var body: some View {
        // Merge: A's SettingRow structure (same chip/padding/colors as every
        // other row) + C's retry-verb unification. `statusDescription` is kept
        // over the plain label because it carries the download percentage —
        // this row is the ONLY progress feedback in Settings — and its wording
        // is aligned with `userFacingLabel` in the service.
        SettingRow(
            icon: iconName,
            title: "Speech model (\(settings.transcriptionModel.displayName))",
            iconColor: iconColor
        ) {
            HStack(spacing: 10) {
                Text(transcriptionService.modelState.statusDescription)
                    .font(.system(size: Design.TypeScale.rowSubtitle))
                    .foregroundStyle(Brand.ink3)
                if case .failed = transcriptionService.modelState {
                    Button("Try again") {
                        Task { await transcriptionService.warmUp() }
                    }
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
        case .ready: return Brand.ready
        case .failed: return Brand.danger
        default: return Brand.ink4
        }
    }
}
