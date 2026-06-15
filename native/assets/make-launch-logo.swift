// Generates a transparent gold `music.note.house` glyph for the iOS launch
// screen (shown centred over the dark LaunchBackground colour).
// Run from native/assets:  swift make-launch-logo.swift
// Produces launch-logo.png (512px, transparent background).
import AppKit

let size = 512.0
let gold = NSColor(red: 0.898, green: 0.627, blue: 0.051, alpha: 1)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let config = NSImage.SymbolConfiguration(pointSize: 300, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [gold]))
if let symbol = NSImage(systemSymbolName: "music.note.house", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render launch logo\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: "launch-logo.png"))
print("wrote launch-logo.png")
