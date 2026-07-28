//
//  DesignTokens.swift
//  Yappy
//

import SwiftUI

/// The one place the main window's geometry, surface, and type values live.
///
/// Yappy's windows are pinned to dark (`adoptYappyDarkAppearance()`), so the
/// surface ramp is expressed as white-over-dark opacities rather than semantic
/// colors — that is deliberate, not a theming bug.
///
/// Every value below was chosen as the one already most common in the redesigned
/// Settings screen, so adopting a token is a no-op on the screens that already
/// looked right and pulls the outliers into line.
enum Design {
    /// Corner radii. Four roles, down from thirteen ad-hoc values.
    enum Radius {
        /// Every glass card/panel: `GlassCard`, `glassPanel()`, stat tiles,
        /// history rows, the sidebar's model footer.
        static let card: CGFloat = 16
        /// A surface nested *inside* a card (search fields, example rows,
        /// hover highlights, list rows that are not themselves cards).
        static let inset: CGFloat = 10
        /// The icon chip that leads a row or a section label.
        static let chip: CGFloat = 9
        /// Compact controls and inline chips (icon buttons, phrase chips).
        static let control: CGFloat = 6
    }

    /// White-over-dark surface opacities. `raised` and `stroke` share a value on
    /// purpose: it is the pairing the redesigned Settings rows already use, and a
    /// chip whose edge matches its fill is what makes the ramp read as one
    /// material instead of a stack of outlined boxes.
    enum Surface {
        static let raisedOpacity: Double = 0.06
        static let strokeOpacity: Double = 0.06
        static let strokeEmphasisOpacity: Double = 0.12
        static let hoverOpacity: Double = 0.08
        static let pressedOpacity: Double = 0.14

        /// A faint raised surface: inactive icon chips, inline chips, wells.
        static var raised: Color { Color.white.opacity(raisedOpacity) }
        /// The 1px hairline edge on a raised surface.
        static var stroke: Color { Color.white.opacity(strokeOpacity) }
        /// A brighter 1px edge for selected or free-standing surfaces.
        static var strokeEmphasis: Color { Color.white.opacity(strokeEmphasisOpacity) }
        /// Fill painted behind a control while the pointer is over it.
        static var hover: Color { Color.white.opacity(hoverOpacity) }
        /// Fill painted behind a control while it is held down.
        static var pressed: Color { Color.white.opacity(pressedOpacity) }
    }

    /// The shared page shell and row rhythm.
    enum Space {
        /// Content column width for every sidebar screen.
        static let pageWidth: CGFloat = 640
        static let pageHorizontal: CGFloat = 30
        static let pageTop: CGFloat = 26
        static let pageBottom: CGFloat = 46
        /// Vertical gap between top-level sections on a page.
        static let sectionGap: CGFloat = 26
        /// A section header is inset slightly from its card's edge…
        static let sectionHeaderInset: CGFloat = 4
        /// …and sits this far above it.
        static let sectionHeaderGap: CGFloat = 11
        /// Padding inside a glass card that holds free-form content.
        static let cardPadding: CGFloat = 16
        /// Padding of one row inside a card that holds rows.
        static let rowHorizontal: CGFloat = 16
        static let rowVertical: CGFloat = 12
        /// Gap between a row's icon chip and its text.
        static let rowGap: CGFloat = 13
        /// The standard 34pt icon chip that leads a row.
        static let chipSize: CGFloat = 34
    }

    /// The type scale. Body copy collapsed to one size (was 12 / 12.5 / 13).
    enum TypeScale {
        static let screenTitle: CGFloat = 24
        static let screenSubtitle: CGFloat = 13.5
        static let sectionTitle: CGFloat = 13
        static let rowTitle: CGFloat = 14
        static let rowSubtitle: CGFloat = 12
        static let caption: CGFloat = 11
        static let micro: CGFloat = 10
    }
}

// MARK: - Shared layout modifiers

extension View {
    /// The shared page shell every sidebar screen wears: a fixed-width centered
    /// content column with the same margins.
    func pageShell() -> some View {
        frame(maxWidth: Design.Space.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Design.Space.pageHorizontal)
            .padding(.top, Design.Space.pageTop)
            .padding(.bottom, Design.Space.pageBottom)
    }

    /// Spacing for a section header sitting above its card — applied to a
    /// `SectionLabel`, or to an HStack of one plus trailing controls.
    func sectionHeader() -> some View {
        padding(.horizontal, Design.Space.sectionHeaderInset)
            .padding(.bottom, Design.Space.sectionHeaderGap)
    }
}

// MARK: - Interaction states

/// Gives an otherwise chrome-less control a hover and a pressed state, so
/// nothing that can be clicked looks like static text.
///
/// The feedback is an instantaneous fill swap plus a dim on press: no implicit
/// animation is attached, so it behaves identically under Reduce Motion.
struct HoverPressButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    /// Chips and badges paint their own background inside the label; for those
    /// the hover fill would be hidden, so only the press dim applies.
    var paintsBackground: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        StatefulBody(configuration: configuration, shape: shape, paintsBackground: paintsBackground)
    }

    /// `@State` is not allowed directly in a `ButtonStyle`, so hover tracking
    /// lives in this nested view.
    private struct StatefulBody: View {
        let configuration: Configuration
        let shape: S
        let paintsBackground: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    if paintsBackground {
                        shape.fill(fill)
                    }
                }
                .opacity(configuration.isPressed ? 0.65 : 1)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Design.Surface.pressed }
            return hovering ? Design.Surface.hover : Color.clear
        }
    }
}

extension ButtonStyle where Self == HoverPressButtonStyle<RoundedRectangle> {
    /// Hover + pressed feedback clipped to a rounded rectangle.
    static func hoverSurface(cornerRadius: CGFloat = Design.Radius.inset) -> Self {
        HoverPressButtonStyle(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension ButtonStyle where Self == HoverPressButtonStyle<Capsule> {
    /// Hover + pressed feedback for a pill-shaped control.
    static var hoverCapsule: Self {
        HoverPressButtonStyle(shape: Capsule())
    }

    /// Press feedback only — for chips that already paint their own capsule.
    static var pressCapsule: Self {
        HoverPressButtonStyle(shape: Capsule(), paintsBackground: false)
    }
}
