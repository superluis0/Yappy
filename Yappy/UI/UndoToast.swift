//
//  UndoToast.swift
//  Yappy
//

import SwiftUI

/// A temporary pill-shaped toast confirming a destructive action with an Undo escape hatch.
/// Drop it as a `.overlay(alignment: .bottom)` on any view that has single-item deletes.
struct UndoToast: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.callout)
            Divider()
                .frame(height: 16)
            Button("Undo", action: onUndo)
                .font(.callout.weight(.medium))
                .foregroundStyle(.tint)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.bottom, 16)
    }
}
