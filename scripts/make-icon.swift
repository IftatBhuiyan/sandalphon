// Flattens the paper icon: the glyph at 70% centred on the ivory (or navy) tile, as a square PNG.
// The layered source of truth is Resources/Sandalphon.icon; this flat version is the fallback .icns for
// toolchains that cannot compile Icon Composer files, and the image used in the README and on the website.
// Usage: swift scripts/make-icon.swift out.png [--dark] [--size 1024] [--glyph path] [--tile path]
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}
let dark = args.contains("--dark")
args.removeAll { $0 == "--dark" }
let size = Int(option("--size") ?? "1024") ?? 1024
let assets = "Resources/Sandalphon.icon/Assets/"
let glyphPath = option("--glyph") ?? assets + "Sandalphon.png"
let tilePath = option("--tile") ?? assets + (dark ? "Paper navy.png" : "Paper ivory.png")
guard let out = args.first, let glyph = NSImage(contentsOfFile: glyphPath), let tile = NSImage(contentsOfFile: tilePath) else {
    FileHandle.standardError.write("usage: make-icon.swift out.png [--dark] [--size n] [--glyph path] [--tile path]\n".data(using: .utf8)!)
    exit(2)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high
let full = NSRect(x: 0, y: 0, width: size, height: size)
tile.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1)
let inset = CGFloat(size) * 0.15
glyph.draw(in: full.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.current!.flushGraphics()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
