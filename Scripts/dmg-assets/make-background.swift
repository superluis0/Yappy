// make-background.swift — renders the DMG window background PNG with AppKit.
// Run from the repo root: `swift Scripts/dmg-assets/make-background.swift`
// Output: Scripts/dmg-assets/dmg-background.png (600x400, matches the DMG window).
//
// The Yappy.app icon and the Applications-folder icon are drawn by Finder on top
// of this background, at the positions set in layout-dmg.applescript. This image
// only supplies the branding and the "drag me over there" arrow between them.

import AppKit

let W = 600, H = 400

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

let full = NSRect(x: 0, y: 0, width: W, height: H)

// Soft vertical gradient (a touch darker at the bottom).
let bottom = NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
let top    = NSColor(calibratedRed: 0.975, green: 0.977, blue: 0.985, alpha: 1)
NSGradient(starting: bottom, ending: top)!.draw(in: full, angle: 90)

// Arrow between the two icons (icons sit at Finder y=190 -> bottom-left y=210).
let arrowY: CGFloat = 210
let arrowColor = NSColor(calibratedWhite: 0.70, alpha: 1)
arrowColor.setStroke()
arrowColor.setFill()

let shaft = NSBezierPath()
shaft.lineWidth = 6
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 232, y: arrowY))
shaft.line(to: NSPoint(x: 360, y: arrowY))
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 356, y: arrowY + 17))
head.line(to: NSPoint(x: 388, y: arrowY))
head.line(to: NSPoint(x: 356, y: arrowY - 17))
head.close()
head.fill()

// Centered text helper (non-flipped context: y measured from the bottom).
func drawCentered(_ s: String, font: NSFont, color: NSColor, centerY: CGFloat) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    let astr = NSAttributedString(string: s, attributes: attrs)
    let h = astr.size().height
    astr.draw(in: NSRect(x: 0, y: centerY - h / 2, width: CGFloat(W), height: h))
}

drawCentered("Yappy",
             font: .systemFont(ofSize: 38, weight: .bold),
             color: NSColor(calibratedWhite: 0.12, alpha: 1),
             centerY: 332)
drawCentered("Drag Yappy to your Applications folder to install",
             font: .systemFont(ofSize: 14, weight: .regular),
             color: NSColor(calibratedWhite: 0.46, alpha: 1),
             centerY: 62)

NSGraphicsContext.restoreGraphicsState()

let outDir = "Scripts/dmg-assets"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outPath = outDir + "/dmg-background.png"
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(W)x\(H))")
