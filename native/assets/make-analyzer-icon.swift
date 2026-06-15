// Generates the RoonSage Analyzer app icon: a gold `waveform` glyph on the same
// dark radial gradient as the main app, so the Analyzer reads as part of the
// family while staying visually distinct (waveform = "analysis/server").
// Run from native/assets:  swift make-analyzer-icon.swift
// Produces analyzer-icon-1024.png (used to build RoonSageAnalyzer.icns).
import AppKit

let size = 1024.0
let gold = NSColor(red: 0.898, green: 0.627, blue: 0.051, alpha: 1)
let bgTop = NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
let bgBottom = NSColor(red: 0.075, green: 0.075, blue: 0.08, alpha: 1)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)

// Full-bleed dark gradient background (system masks the corners on macOS).
NSGradient(starting: bgTop, ending: bgBottom)?.draw(in: rect, angle: -90)

// Soft gold glow behind the glyph.
let glow = NSGradient(colors: [gold.withAlphaComponent(0.20), gold.withAlphaComponent(0)])
glow?.draw(in: rect, relativeCenterPosition: NSPoint(x: 0, y: 0.05))

// Gold waveform glyph, centred.
let config = NSImage.SymbolConfiguration(pointSize: 540, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [gold]))
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: "analyzer-icon-1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
