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
            voiceCommandsSection
            audioFeedbackSection
            streamingSection
            permissionsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 600)
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

    private var voiceCommandsSection: some View {
        Section("Voice Commands") {
            Toggle("Enable voice commands", isOn: $settings.voiceCommandsEnabled)
                .toggleStyle(.switch)

            if settings.voiceCommandsEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Say commands at the end of your dictation:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)

                    VStack(alignment: .leading, spacing: 4) {
                        commandHelpRow(command: "\"delete that\"", description: "Remove all inserted text")
                        commandHelpRow(command: "\"undo\"", description: "Undo last action")
                        commandHelpRow(command: "\"new line\"", description: "Insert line break")
                        commandHelpRow(command: "\"new paragraph\"", description: "Insert paragraph break")
                        commandHelpRow(command: "\"period\", \"comma\"", description: "Insert punctuation")
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }

    private var audioFeedbackSection: some View {
        Section("Sound Effects") {
            Toggle("Enable audio feedback", isOn: $settings.audioFeedbackEnabled)
                .toggleStyle(.switch)

            if settings.audioFeedbackEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Volume")
                            .font(.subheadline)

                        Slider(value: $settings.audioFeedbackVolume, in: 0...1)
                            .frame(maxWidth: 200)

                        Text("\(Int(settings.audioFeedbackVolume * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.leading, 20)

                    Text("Plays subtle sounds for recording start, stop, and text insertion")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
    }

    private var streamingSection: some View {
        Section("Text Insertion") {
            Toggle("Enable streaming text", isOn: $settings.streamingTextEnabled)
                .toggleStyle(.switch)

            Text("Types text word-by-word for a live transcription effect")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 20)
        }
    }

    private func commandHelpRow(command: String, description: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.orange)
            Text("—")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var permissionsSection: some View {
        Section {
            // Overall status header
            VStack(spacing: 12) {
                HStack {
                    Circle()
                        .fill(allPermissionsGranted ? Color.green : Color.orange)
                        .frame(width: 12, height: 12)
                    
                    Text(allPermissionsGranted ? "All Permissions Granted ✓" : "Setup Required")
                        .font(.headline)
                        .foregroundColor(allPermissionsGranted ? .green : .orange)
                    
                    Spacer()
                    
                    Button {
                        checkPermissions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh permission status")
                }
                
                if !allPermissionsGranted {
                    Text("Yappy needs the following permissions to work properly. Please enable each one to use all features.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 8)
            
            Divider()
            
            // Microphone permission
            permissionRow(
                icon: "mic.fill",
                title: "Microphone Access",
                description: "Required for voice recording",
                whyNeeded: "Yappy uses your microphone to capture speech for transcription.",
                status: microphonePermissionStatus,
                actionTitle: microphonePermissionStatus == .notDetermined ? "Grant Access" : "Open Settings",
                action: {
                    if microphonePermissionStatus == .notDetermined {
                        requestMicrophonePermission()
                    } else {
                        openMicrophoneSettings()
                    }
                }
            )
            
            Divider()
            
            // Accessibility permission
            permissionRow(
                icon: "accessibility",
                title: "Accessibility Access",
                description: "Required for hotkey detection and text insertion",
                whyNeeded: "Yappy needs accessibility access to detect your keyboard shortcut and type text into other apps.",
                status: accessibilityPermissionStatus,
                actionTitle: "Open System Settings",
                action: openAccessibilitySettings
            )
            
            Divider()
            
            // Input Monitoring (for keyboard events)
            permissionRow(
                icon: "keyboard",
                title: "Input Monitoring",
                description: "Required for global hotkey activation",
                whyNeeded: "Yappy monitors keyboard input to detect when you press the activation hotkey.",
                status: accessibilityPermissionStatus, // Same as accessibility on macOS
                actionTitle: "Open System Settings",
                action: openInputMonitoringSettings
            )
            
            // Quick setup instructions
            if !allPermissionsGranted {
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Setup Guide")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        setupStep(number: 1, text: "Click \"Open System Settings\" for each permission")
                        setupStep(number: 2, text: "Find \"Yappy\" in the list of apps")
                        setupStep(number: 3, text: "Toggle the switch to enable access")
                        setupStep(number: 4, text: "Return here and click refresh (↻) to verify")
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(8)
            }
            
        } header: {
            Text("Permissions")
        } footer: {
            if allPermissionsGranted {
                Text("Yappy has all the permissions it needs. You're all set!")
                    .foregroundColor(.green)
            }
        }
    }
    
    // MARK: - Permission Helpers
    
    private var allPermissionsGranted: Bool {
        microphonePermissionStatus == .authorized && accessibilityPermissionStatus == .authorized
    }
    
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        whyNeeded: String,
        status: PermissionStatus,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Icon and title
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(status.iconColor)
                        .frame(width: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Status badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(status.iconColor)
                        .frame(width: 8, height: 8)
                    
                    Text(status.badgeText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(status.iconColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(status.iconColor.opacity(0.1))
                .cornerRadius(12)
            }
            
            // Why needed explanation (only show if not granted)
            if status != .authorized {
                Text(whyNeeded)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, 32)
            }
            
            // Action button (only show if not granted)
            if status != .authorized {
                Button(action: action) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text(actionTitle)
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func setupStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.blue)
                .frame(width: 16)
            
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
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

    private func openMicrophoneSettings() {
        // Open System Settings to Microphone
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }

        // Re-check after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            checkMicrophonePermission()
        }
    }

    private func openInputMonitoringSettings() {
        // Open System Settings to Input Monitoring
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
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

    var badgeText: String {
        switch self {
        case .notDetermined:
            return "Pending"
        case .authorized:
            return "Enabled"
        case .denied:
            return "Disabled"
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
