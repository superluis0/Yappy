//
//  SettingsView.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import SwiftUI
import ServiceManagement
import AVFoundation

/// Comprehensive settings view with API configuration, hotkey preferences, and permissions.
struct SettingsView: View {
    // MARK: - Properties

    @ObservedObject var settings: Settings

    @State private var microphonePermissionStatus: PermissionStatus = .notDetermined
    @State private var accessibilityPermissionStatus: PermissionStatus = .notDetermined

    // MARK: - Body

    var body: some View {
        Form {
            apiKeysSection
            hotkeySection
            generalSection
            permissionsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 500)
        .onAppear {
            checkPermissions()
        }
    }

    // MARK: - Form Sections

    private var apiKeysSection: some View {
        Section("API Keys") {
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenAI API Key")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                SecureField("sk-...", text: $settings.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)

                Text("Used for Whisper speech-to-text transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("xAI API Key")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                SecureField("xai-...", text: $settings.xAIAPIKey)
                    .textFieldStyle(.roundedBorder)

                Text("Used for Grok text cleanup and enhancement")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            HStack {
                Image(systemName: settings.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(settings.isConfigured ? .green : .orange)

                Text(settings.isConfigured ? "API keys configured" : "Both API keys required")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var hotkeySection: some View {
        Section("Hotkey") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Activation Method")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("", selection: $settings.hotkeyOption) {
                    ForEach(HotkeyOption.allCases, id: \.self) { option in
                        Text(option.displayName)
                            .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text("Current: \(settings.hotkeyOption.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Enable text cleanup", isOn: $settings.cleanupEnabled)
                .toggleStyle(.switch)

            Text("Uses Grok AI to fix capitalization and punctuation in transcriptions")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 20)

            Divider()
                .padding(.vertical, 4)

            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    toggleLaunchAtLogin(enabled: newValue)
                }
            ))
            .toggleStyle(.switch)

            Text("Automatically start Yappy when you log in")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 20)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            // Microphone permission
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "mic.fill")
                            .foregroundColor(microphonePermissionStatus.iconColor)

                        Text("Microphone Access")
                            .font(.subheadline)
                    }

                    Text(microphonePermissionStatus.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if microphonePermissionStatus != .authorized {
                    Button("Request") {
                        requestMicrophonePermission()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)

            Divider()

            // Accessibility permission
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "accessibility")
                            .foregroundColor(accessibilityPermissionStatus.iconColor)

                        Text("Accessibility Access")
                            .font(.subheadline)
                    }

                    Text(accessibilityPermissionStatus.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if accessibilityPermissionStatus != .authorized {
                    Button("Open System Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helper Methods

    private func checkPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
    }

    private func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphonePermissionStatus = PermissionStatus(from: status)
    }

    private func checkAccessibilityPermission() {
        let isGranted = HotkeyManager.checkAccessibilityPermissions()
        accessibilityPermissionStatus = isGranted ? .authorized : .denied
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                checkMicrophonePermission()
            }
        }
    }

    private func openAccessibilitySettings() {
        HotkeyManager.requestAccessibilityPermissions()

        // Open System Settings to Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        // Re-check after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            checkAccessibilityPermission()
        }
    }

    private func toggleLaunchAtLogin(enabled: Bool) {
        settings.launchAtLogin = enabled

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
            // Revert the setting if it failed
            settings.launchAtLogin = !enabled
        }
    }
}

// MARK: - Permission Status

/// Represents the status of a system permission.
private enum PermissionStatus {
    case notDetermined
    case authorized
    case denied

    var iconColor: Color {
        switch self {
        case .notDetermined:
            return .orange
        case .authorized:
            return .green
        case .denied:
            return .red
        }
    }

    var description: String {
        switch self {
        case .notDetermined:
            return "Not yet requested"
        case .authorized:
            return "Granted"
        case .denied:
            return "Denied - please enable in System Settings"
        }
    }

    init(from avStatus: AVAuthorizationStatus) {
        switch avStatus {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .authorized
        case .denied, .restricted:
            self = .denied
        @unknown default:
            self = .denied
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView(settings: Settings())
}
