//
//  AppDelegate+MenuBarIcon.swift
//  Yappy
//
//  The menu-bar lettermark: idle/processing/recording glyph drawing and the
//  recording "breathe" animation. Split out of AppDelegate.swift when the
//  file-length ratchet fired (the coherence batch nudged it past 3,100 lines) —
//  this section is self-contained rendering with no dictation logic, so it is
//  the natural seam. The three stored properties it drives (`statusItem`,
//  `menuBarAnimationTimer`, `menuBarFrameIndex`) stay in the main file, since
//  Swift extensions cannot hold stored state.
//

import Cocoa

/// Which menu-bar glyph to draw. Internal (not nested private) so both the
/// main file's state switch and this extension's renderer can name it.
enum MenuBarGlyph {
    case ready
    case processing
    case recording
}

extension AppDelegate {

    /// Idle/processing menu-bar glyphs, drawn once and reused on every state
    /// change rather than redrawn each time (static lets initialize lazily).
    static let readyIcon: NSImage = yIcon(.ready)
    static let processingIcon: NSImage = yIcon(.processing)

    /// Precomputed frames "breathing" the Y's stroke weight while recording —
    /// the lettermark has no waveform bars to animate, so the whole glyph pulses
    /// instead, echoing the pill's breathing glow. Cheap to swap, like the old
    /// bar frames.
    static let recordingFrames: [NSImage] = [
        2.3, 2.6, 2.9, 2.6, 2.3
    ].map { yIcon(.recording, strokeWidth: $0) }

    func startMenuBarAnimation() {
        guard menuBarAnimationTimer == nil else { return }
        statusItem?.button?.image = Self.recordingFrames[0]
        menuBarFrameIndex = 0
        menuBarAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.menuBarFrameIndex = (self.menuBarFrameIndex + 1) % Self.recordingFrames.count
            self.statusItem?.button?.image = Self.recordingFrames[self.menuBarFrameIndex]
        }
    }

    func stopMenuBarAnimation() {
        menuBarAnimationTimer?.invalidate()
        menuBarAnimationTimer = nil
    }

    /// Brand orange used for the recording state (the app's accent color).
    private static let brandOrange = NSColor(named: "AccentColor")
        ?? NSColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1.0)

    /// Draws the Yappy "Y" lettermark for a given state.
    /// Ready/processing are template images (auto light/dark); recording is solid
    /// orange. `strokeWidth` drives the recording "breathe" animation frames.
    private static func yIcon(_ glyph: MenuBarGlyph, strokeWidth: CGFloat = 2.6) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = yPath()
            path.lineWidth = strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            switch glyph {
            case .ready:
                NSColor.black.setStroke()
            case .processing:
                // Dimmed, to read as "working" during the brief processing
                // window (the pill shows the detailed state).
                NSColor.black.withAlphaComponent(0.4).setStroke()
            case .recording:
                brandOrange.setStroke()
            }
            path.stroke()
            return true
        }
        image.isTemplate = (glyph != .recording)
        return image
    }

    /// The Y lettermark in an 18×18 box: two arms meeting at the fork, stem
    /// dropping to the baseline. NSImage's unflipped coordinates put y=0 at the
    /// BOTTOM, so the arms anchor high (y 15.4) and the stem ends low (y 2.6).
    /// Stroke-based (round caps/joins) so the recording frames can vary weight.
    private static func yPath() -> NSBezierPath {
        let path = NSBezierPath()
        let fork = NSPoint(x: 9.0, y: 9.0)
        path.move(to: NSPoint(x: 4.4, y: 15.4))
        path.line(to: fork)
        path.move(to: NSPoint(x: 13.6, y: 15.4))
        path.line(to: fork)
        path.move(to: fork)
        path.line(to: NSPoint(x: 9.0, y: 2.6))
        return path
    }
}
