//
//  CleanupCoordinator.swift
//  Yappy
//

import Foundation

/// A backend that performs Yappy's AI text transforms — transcript cleanup,
/// Command Mode edits, and named Transforms. Implemented by an on-device model
/// (Apple Foundation Models on macOS 26+, or a bundled MLX model) and by a local
/// LM Studio server. Every method is best-effort: on any failure it returns the
/// input unchanged (or nil) so dictation never breaks.
protocol CleanupProvider: AnyObject {
    /// Short label for the Settings UI (e.g. "Apple Intelligence", "Built-in", "LM Studio").
    var displayName: String { get }

    /// Whether the provider can serve a request right now (model loaded / reachable).
    func isAvailable() async -> Bool

    /// Cleans a dictation transcript. The caller has already decided cleanup should
    /// run (enabled, non-verbatim tone). Returns the original text on any failure.
    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool) async -> String

    /// Applies a spoken instruction to a selection (Command Mode). Returns nil on failure.
    func runCommand(instruction: String, selection: String) async -> String?

    /// Applies a saved Transform's prompt to some text. Returns nil on failure.
    func runTransform(prompt: String, text: String) async -> String?
}

/// Chooses which `CleanupProvider` handles AI text transforms and routes the app's
/// cleanup / Command Mode / Transform calls to it. The LM Studio server stays the
/// "bring-your-own" power-user option; the on-device providers make cleanup work
/// with no extra setup.
@MainActor
final class CleanupCoordinator {
    /// The LM Studio backend. Exposed because the Settings UI also drives its
    /// server-specific config (reachability, model list).
    let lmStudio: LMStudioService

    private let settings: Settings
    /// On-device backends keyed by the setting that selects them. Populated as the
    /// providers are wired in (Foundation Models, MLX); an empty map means every
    /// request falls back to LM Studio, preserving the original behavior.
    private let onDeviceProviders: [CleanupBackend: CleanupProvider]

    init(lmStudio: LMStudioService,
         settings: Settings,
         onDeviceProviders: [CleanupBackend: CleanupProvider] = [:]) {
        self.lmStudio = lmStudio
        self.settings = settings
        self.onDeviceProviders = onDeviceProviders
    }

    // MARK: - Public API (mirrors the former lmStudio call sites)

    /// Cleans a transcript with the active backend, applying the same enable/tone
    /// gates the LM Studio path used to apply internally.
    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool, cleanupEnabled: Bool?) async -> String {
        guard (cleanupEnabled ?? settings.cleanupEnabled), !text.isEmpty else { return text }
        guard tone != .verbatim else { return text }
        return await activeProvider().cleanup(text, tone: tone, backtrack: backtrack)
    }

    func runCommand(instruction: String, selection: String) async -> String? {
        await activeProvider().runCommand(instruction: instruction, selection: selection)
    }

    func runTransform(prompt: String, text: String) async -> String? {
        await activeProvider().runTransform(prompt: prompt, text: text)
    }

    // MARK: - Provider resolution

    /// Resolves the backend per the user's choice, falling back to LM Studio when a
    /// chosen on-device provider isn't available on this machine.
    private func activeProvider() async -> CleanupProvider {
        switch settings.cleanupBackend {
        case .automatic:
            // Prefer the most efficient on-device option that's actually ready.
            if let fm = onDeviceProviders[.appleIntelligence], await fm.isAvailable() { return fm }
            if let mlx = onDeviceProviders[.builtIn], await mlx.isAvailable() { return mlx }
            return lmStudio
        case .appleIntelligence:
            if let fm = onDeviceProviders[.appleIntelligence], await fm.isAvailable() { return fm }
            return lmStudio
        case .builtIn:
            if let mlx = onDeviceProviders[.builtIn], await mlx.isAvailable() { return mlx }
            return lmStudio
        case .lmStudio:
            return lmStudio
        }
    }
}
