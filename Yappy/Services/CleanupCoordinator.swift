//
//  CleanupCoordinator.swift
//  Yappy
//

import Foundation

/// A backend that cleans up Yappy's dictation transcripts. Implemented on-device
/// by Apple Foundation Models (macOS 26+). Best-effort: on any failure it returns
/// the input unchanged so dictation never breaks.
protocol CleanupProvider: AnyObject {
    /// Short label for the Settings UI (e.g. "Apple Intelligence").
    var displayName: String { get }

    /// Whether the provider can serve a request right now (model loaded / reachable).
    func isAvailable() async -> Bool

    /// Cleans a dictation transcript. The caller has already decided cleanup should
    /// run (enabled, non-verbatim tone). Returns the original text on any failure.
    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool) async -> String

    /// Asks the provider to load its model into memory ahead of use, so the first
    /// real request doesn't pay a cold-start. Best-effort and idempotent.
    func prewarm() async
}

extension CleanupProvider {
    /// Default: nothing to warm up.
    func prewarm() async {}
}

/// Routes the app's transcript-cleanup calls to the on-device AI provider (Apple
/// Intelligence). When no provider is available (older macOS or AI disabled),
/// cleanup degrades to a no-op so dictation never breaks.
@MainActor
final class CleanupCoordinator {
    private let settings: Settings
    /// The on-device AI provider (Apple Intelligence). `nil` when none is wired,
    /// in which case cleanup degrades to returning its input unchanged.
    private let provider: CleanupProvider?

    init(settings: Settings, provider: CleanupProvider? = nil) {
        self.settings = settings
        self.provider = provider
    }

    // MARK: - Public API

    /// Cleans a transcript with the on-device provider, applying the same
    /// enable/tone gates the provider would apply internally. Returns the input
    /// unchanged when cleanup is off, the tone is verbatim, or no provider exists.
    func cleanup(_ text: String, tone: ToneStyle, backtrack: Bool, cleanupEnabled: Bool?) async -> String {
        guard (cleanupEnabled ?? settings.cleanupEnabled), !text.isEmpty else { return text }
        guard tone != .verbatim else { return text }
        guard let provider else { return text }
        return await provider.cleanup(text, tone: tone, backtrack: backtrack)
    }

    /// Warms up the on-device model so the first cleanup doesn't pay the
    /// multi-second cold start of loading it into memory. Fire-and-forget and
    /// cheap once warm. No-op when cleanup is off or no provider exists.
    ///
    /// Call this at the start of each dictation: the model loads in the background
    /// while the user speaks, so it's hot by the time the transcript is ready.
    func prewarm() {
        guard settings.cleanupEnabled, let provider else { return }
        // Fire-and-forget on the provider's own executor (off the main thread).
        // No isAvailable() gate: that check is itself costly (it decodes the model
        // manifest), and prewarm() is a cheap no-op when the model can't load.
        // IMPORTANT: only call this when no dictation is recording — warming the
        // model loads it on a background thread, and doing so while the audio
        // engine is being torn down races CoreAudio and crashes. Callers warm only
        // at audio-idle moments (enabling cleanup; after a cleanup completes).
        Task { [provider] in
            await provider.prewarm()
        }
    }
}
