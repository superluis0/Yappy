//
//  UndoToast.swift
//  Yappy
//

import SwiftUI

/// A temporary pill-shaped toast confirming a destructive action with an Undo escape hatch.
/// Drop it as a `.overlay(alignment: .bottom)` on any view that has single-item deletes.
///
/// The escape hatch is time-limited, so it must not be mouse-only: appearing posts a
/// VoiceOver announcement naming the deletion and the window that's left, and Undo
/// carries the standard ⌘Z shortcut so it is reachable without hunting for the pill.
struct UndoToast: View {
    let message: String
    /// How long the caller's timer leaves Undo available — announced so a
    /// VoiceOver user knows how much window they have.
    var secondsRemaining: Int = 3
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.callout)
            Divider()
                .frame(height: 16)
                .accessibilityHidden(true)
            Button("Undo", action: onUndo)
                .font(.callout.weight(.medium))
                .foregroundStyle(.tint)
                .buttonStyle(.plain)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityLabel("Undo")
                .accessibilityHint(undoHint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.bottom, 16)
        .onAppear {
            AppState.announceForAccessibility("\(message). \(undoHint)")
        }
    }

    private var undoHint: String {
        "Undo with Command Z within \(secondsRemaining) second\(secondsRemaining == 1 ? "" : "s")."
    }
}
