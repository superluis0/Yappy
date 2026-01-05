//
//  SettingsView.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import SwiftUI

/// Settings window view for configuring Yappy.
/// Provides UI for API key management, hotkey selection, and app preferences.
struct SettingsView: View {
    // MARK: - Properties

    @ObservedObject var settings: Settings

    // MARK: - Body

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            APISettingsView(settings: settings)
                .tabItem {
                    Label("API Keys", systemImage: "key.fill")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General Settings View

/// General settings tab for hotkey configuration and app behavior.
struct GeneralSettingsView: View {
    @ObservedObject var settings: Settings
    
    private func checkAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var body: some View {
        Form {
            Section {
                Picker("Hotkey:", selection: $settings.hotkeyOption) {
                    ForEach(HotkeyOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Recording Activation")
                    .font(.headline)
            }

            Divider()

            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                Toggle("AI Transcription Cleanup", isOn: $settings.cleanupEnabled)
                
                if settings.cleanupEnabled {
                    Text("⚡️ Text will paste immediately, cleanup happens in background")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("⚡️ Optimized for lowest latency - text pastes instantly")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Application Behavior")
                    .font(.headline)
            }
            .padding(.top, 8)
            
            Divider()
            
            Section {
                Button("Check Accessibility Permissions") {
                    checkAccessibilityPermissions()
                }
                Text("Grants permission to paste transcribed text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Permissions")
                    .font(.headline)
            }
            .padding(.top, 8)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - API Settings View

/// API keys configuration tab.
struct APISettingsView: View {
    @ObservedObject var settings: Settings
    @State private var showAPIKeyInfo = false

    var body: some View {
        Form {
            Section {
                SecureField("OpenAI API Key", text: $settings.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)

                Text("Used for Whisper speech-to-text transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OpenAI")
                    .font(.headline)
            }

            Divider()

            Section {
                SecureField("OpenRouter API Key", text: $settings.openRouterAPIKey)
                    .textFieldStyle(.roundedBorder)

                Text("Used for Grok AI-powered transcription cleanup via OpenRouter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OpenRouter (Grok)")
                    .font(.headline)
            }

            Divider()

            HStack {
                Button("Get API Keys Info") {
                    showAPIKeyInfo = true
                }
                Spacer()
                if settings.isConfigured {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            .padding(.top, 8)
        }
        .formStyle(.grouped)
        .padding()
        .alert("API Keys Information", isPresented: $showAPIKeyInfo) {
            Button("OK") { }
        } message: {
            Text("Get your OpenAI API key from platform.openai.com\n\nGet your OpenRouter API key from openrouter.ai/keys")
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView(settings: Settings())
}
