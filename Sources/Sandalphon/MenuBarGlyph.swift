import AppKit

/// The menu bar mark: the wing and text cursor of the app icon, drawn as a template image so the system
/// tints it for light, dark and highlighted menu bars.
enum MenuBarGlyph {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / 18
            ctx.scaleBy(x: s, y: s)
            NSColor.black.setFill()
            // Text cursor.
            NSBezierPath(roundedRect: NSRect(x: 1.6, y: 2.4, width: 2.3, height: 9.2), xRadius: 1.15, yRadius: 1.15).fill()
            // Three feathers fanning from the foot of the cursor, drawn back to front with a hairline between them.
            let base = NSPoint(x: 5.3, y: 2.3)
            let feathers: [(tip: NSPoint, up: NSPoint, down: NSPoint)] = [
                (NSPoint(x: 16.9, y: 16.2), NSPoint(x: 5.6, y: 12.5), NSPoint(x: 13.5, y: 9.5)),
                (NSPoint(x: 16.6, y: 11.2), NSPoint(x: 6.6, y: 9.0), NSPoint(x: 14.0, y: 6.2)),
                (NSPoint(x: 15.2, y: 6.6), NSPoint(x: 8.0, y: 6.4), NSPoint(x: 13.5, y: 3.0)),
            ]
            for f in feathers {
                let p = NSBezierPath()
                p.move(to: base)
                p.curve(to: f.tip, controlPoint1: NSPoint(x: base.x + (f.up.x - base.x) * 0.2, y: f.up.y * 0.75),
                        controlPoint2: f.up)
                p.curve(to: base, controlPoint1: f.down, controlPoint2: NSPoint(x: base.x + 3.5, y: base.y + 0.4))
                p.close()
                ctx.setBlendMode(.destinationOut)
                p.lineWidth = 1.5
                p.stroke()
                ctx.setBlendMode(.normal)
                p.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
