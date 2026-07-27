//
//  WaveformBarsView.swift
//  Yappy
//

import SwiftUI

/// Reusable animated waveform bars driven by recent audio levels.
/// Used by the recording pill and the onboarding mic preview.
struct WaveformBarsView: View {
    let levels: [Float]
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var maxHeight: CGFloat = 22
    var style: AnyShapeStyle = AnyShapeStyle(.white)
    /// When set, each bar gets a soft glow of this color.
    var glow: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<levels.count, id: \.self) { index in
                Capsule()
                    .fill(style)
                    .frame(width: barWidth, height: barHeight(at: index))
                    .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 3)
                    // Bars still track level under Reduce Motion; only the spring eases.
                    .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: levels)
            }
        }
    }

    /// Symmetric falloff from the center so the bars read like a voice meter.
    private func barHeight(at index: Int) -> CGFloat {
        guard index < levels.count, levels.count > 1 else { return barWidth }

        let center = CGFloat(levels.count - 1) / 2
        let distance = abs(CGFloat(index) - center) / center
        let shape = 1.0 - distance * 0.55

        let level = CGFloat(levels[index])
        return max(barWidth, level * maxHeight * shape)
    }
}
