//
//  VisualEffectBackground.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import SwiftUI
import AppKit

/// NSVisualEffectView wrapper for SwiftUI that provides native blur and vibrancy effects.
/// Creates a translucent, blurred background that adapts to the desktop wallpaper.
struct VisualEffectBackground: NSViewRepresentable {
    // MARK: - Properties

    /// The material type for the visual effect (e.g., .hudWindow, .menu).
    let material: NSVisualEffectView.Material

    /// The blending mode for how the view blends with content behind it.
    let blendingMode: NSVisualEffectView.BlendingMode

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
