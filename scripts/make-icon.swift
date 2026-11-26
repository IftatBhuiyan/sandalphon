// Draws the Sandalphon app icon and writes a 1024px PNG. Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centred in 1024 with a continuous-corner squircle.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor(srgbRed: 0.27, green: 0.16, blue: 0.78, alpha: 1).setFill()
shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
let gradient = NSGradient(colors: [NSColor(srgbRed: 0.56, green: 0.42, blue: 1.0, alpha: 1),
                                   NSColor(srgbRed: 0.33, green: 0.20, blue: 0.88, alpha: 1),
                                   NSColor(srgbRed: 0.16, green: 0.09, blue: 0.55, alpha: 1)],
                          atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
gradient.draw(in: body, angle: -90)
// Soft light from the top-left.
NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
    .draw(fromCenter: CGPoint(x: 300, y: 860), radius: 0, toCenter: CGPoint(x: 300, y: 860), radius: 620, options: [])
ctx.restoreGState()

// The word being typed: a bold "a" followed by a caret.
let font = NSFont.systemFont(ofSize: 430, weight: .bold)
let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 430) } ?? font
let text = NSAttributedString(string: "a", attributes: [.font: rounded, .foregroundColor: NSColor.white])
let textSize = text.size()
let caretGap: CGFloat = 34, caretWidth: CGFloat = 40
let groupWidth = textSize.width + caretGap + caretWidth
let x0 = (size - groupWidth) / 2
text.draw(at: CGPoint(x: x0, y: 392))
let caret = NSBezierPath(roundedRect: CGRect(x: x0 + textSize.width + caretGap, y: 492, width: caretWidth, height: 300),
                         xRadius: 20, yRadius: 20)
NSColor(srgbRed: 1.0, green: 0.82, blue: 0.36, alpha: 1).setFill()
caret.fill()

// The suggestion bar under it: three pills, the first one chosen.
let barY: CGFloat = 262, barH: CGFloat = 128
let bar = CGRect(x: 232, y: barY, width: 560, height: barH)
NSColor.white.withAlphaComponent(0.16).setFill()
NSBezierPath(roundedRect: bar, xRadius: 44, yRadius: 44).fill()
let inset: CGFloat = 18
let pillW = (bar.width - inset * 4) / 3
for i in 0..<3 {
    let r = CGRect(x: bar.minX + inset + CGFloat(i) * (pillW + inset), y: barY + inset, width: pillW, height: barH - inset * 2)
    (i == 0 ? NSColor.white : NSColor.white.withAlphaComponent(0.30)).setFill()
    NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28).fill()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
