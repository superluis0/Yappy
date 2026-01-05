//
//  MenuBarView.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import SwiftUI

/// SwiftUI view displayed in the menu bar popover.
/// Shows app status, settings access, and configuration warnings.
struct MenuBarView: View {
    // MARK: - Properties

    @ObservedObject var appState: AppState
    @ObservedObject var settings: Settings

    /// Callback to open the settings window.
    let openSettings: () -> Void

    /// Callback to quit the application.
    let quitApp: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()
                .padding(.vertical, 8)

            // Status indicator
            statusSection

            // Warning if API keys not configured
            if !settings.isConfigured {
                warningSection
            }

            Divider()
                .padding(.vertical, 8)

            // Settings button
            Button(action: openSettings) {
                HStack {
                    Image(systemName: "gearshape")
                    Text("Settings...")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Quit button
            Button(action: quitApp) {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .frame(width: 250)
        .padding(.vertical, 8)
    }

    // MARK: - View Components

    private var headerSection: some View {
        HStack {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("Yappy")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var statusSection: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
    }

    private var warningSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 4) {
                Text("API Keys Not Configured")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Please add your OpenAI and xAI API keys in Settings to use voice recording.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        if appState.isRecording {
            return .red
        } else if appState.isProcessing {
            return .orange
        } else if settings.isConfigured {
            return .green
        } else {
            return .gray
        }
    }

    private var statusText: String {
        if appState.isRecording {
            return "Recording..."
        } else if appState.isProcessing {
            return "Processing..."
        } else if settings.isConfigured {
            return "Ready"
        } else {
            return "Not Configured"
        }
    }
}

// MARK: - Preview

#Preview {
    MenuBarView(
        appState: AppState(),
        settings: Settings(),
        openSettings: {},
        quitApp: {}
    )
}
