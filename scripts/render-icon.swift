import AppKit

// Renders the 1024x1024 master app icon PNG: macOS-style rounded-rect tile with a
// vertical gradient and a white mic-with-pause glyph. Usage: render-icon.swift <out.png>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <out.png>\n".utf8))
    exit(1)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let canvas = 1024.0
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Apple's icon grid: the tile leaves a transparent margin around it.
let tileRect = NSRect(x: 100, y: 100, width: canvas - 200, height: canvas - 200)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(calibratedRed: 0.32, green: 0.20, blue: 0.85, alpha: 1),
    ending: NSColor(calibratedRed: 0.14, green: 0.55, blue: 0.95, alpha: 1)
)!.draw(in: tile, angle: -90)

func drawSymbol(_ name: String, pointSize: CGFloat, in rect: NSRect) {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) else {
        FileHandle.standardError.write(Data("symbol \(name) unavailable\n".utf8))
        exit(1)
    }
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()

    // Fit into rect preserving aspect ratio, centered.
    let scale = min(rect.width / tinted.size.width, rect.height / tinted.size.height)
    let drawSize = NSSize(width: tinted.size.width * scale, height: tinted.size.height * scale)
    let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
    tinted.draw(in: NSRect(origin: origin, size: drawSize))
}

drawSymbol("mic.fill", pointSize: 300, in: tileRect.insetBy(dx: 250, dy: 220))

// Pause bars, bottom-right of the mic, like a badge.
NSColor.white.set()
let barSize = NSSize(width: 42, height: 130)
for x in [598.0, 668.0] {
    NSBezierPath(roundedRect: NSRect(origin: NSPoint(x: x, y: 250), size: barSize),
                 xRadius: 21, yRadius: 21).fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode png\n".utf8))
    exit(1)
}
try png.write(to: outputURL)
