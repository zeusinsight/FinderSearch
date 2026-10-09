import AppKit

// Keep the approved artwork intact; render the platform tile with exact geometry.
guard CommandLine.arguments.count == 4,
    let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]),
    let size = Int(CommandLine.arguments[3]), size > 0,
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("Usage: render-icon.swift artwork.png output.png size") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true
let edge = CGFloat(size)
context.cgContext.clear(CGRect(x: 0, y: 0, width: edge, height: edge))
let tile = NSRect(x: edge * 0.06, y: edge * 0.06, width: edge * 0.88, height: edge * 0.88)
NSBezierPath(roundedRect: tile, xRadius: edge * 0.18, yRadius: edge * 0.18).addClip()
NSColor.white.setFill()
tile.fill()
artwork.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
