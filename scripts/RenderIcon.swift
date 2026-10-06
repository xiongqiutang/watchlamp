// Draws the Watchlamp icon (a 1024 px PNG): the board's "your turn" lamp, yellow with a raised hand, glowing on a
// dark tile. The lamp is drawn the way Board.swift draws it (bezel, glass, shine, rim, bloom and halo).
// Used by build.sh only, so none of this ships inside the app.
import AppKit

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024
let s = CGFloat(size)

func mix(_ a: NSColor, _ fraction: CGFloat, _ b: NSColor) -> NSColor { a.blended(withFraction: fraction, of: b) ?? a }

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8),
                        xRadius: s * 0.18, yRadius: s * 0.18)
NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))?.draw(in: tile, angle: -90)

let yellow = NSColor(srgbRed: 1, green: 0xD6 / 255.0, blue: 0x0A / 255.0, alpha: 1)
let d = s * 0.54
let outer = NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)
let lens = outer.insetBy(dx: d * 0.075, dy: d * 0.075)

// The soft light around a lit lamp, kept inside the tile.
NSGraphicsContext.saveGraphicsState()
tile.addClip()
let center = NSPoint(x: s / 2, y: s / 2)
NSGradient(colors: [0.5, 0.3, 0.1, 0].map { yellow.withAlphaComponent($0) }, atLocations: [0, 0.6, 0.78, 1],
           colorSpace: .sRGB)?.draw(fromCenter: center, radius: 0, toCenter: center, radius: d * 0.8, options: [])
let halo = NSShadow()
halo.shadowColor = yellow
halo.shadowBlurRadius = d * 0.14
halo.shadowOffset = .zero
halo.set()
yellow.setFill()
NSBezierPath(ovalIn: lens).fill()
NSGraphicsContext.restoreGraphicsState()

// Metal bezel, glass lens with its highlight, and the thin dark rim between them.
NSGradient(starting: NSColor(white: 0.32, alpha: 1), ending: NSColor(white: 0.1, alpha: 1))?
    .draw(in: NSBezierPath(ovalIn: outer), angle: -90)
let glass = NSBezierPath(ovalIn: lens)
NSGradient(colors: [mix(yellow, 0.55, .white), yellow, mix(yellow, 0.32, .black)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)?.draw(in: glass, relativeCenterPosition: NSPoint(x: 0, y: 0.24))
NSGradient(colors: [NSColor(white: 1, alpha: 0.45), NSColor(white: 1, alpha: 0)], atLocations: [0, 1],
           colorSpace: .sRGB)?.draw(in: glass, relativeCenterPosition: NSPoint(x: -0.2, y: 0.6))
let rimWidth = d * 0.012
let rim = NSBezierPath(ovalIn: lens.insetBy(dx: rimWidth / 2, dy: rimWidth / 2))
rim.lineWidth = rimWidth
NSColor(white: 0, alpha: 0.45).setStroke()
rim.stroke()

// The raised hand, dark on the bright lens, as the board draws it on yellow.
if let symbol = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: d * 0.42, weight: .bold)) {
    let glyph = symbol.size
    let ink = NSImage(size: glyph, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor(white: 0.04, alpha: 0.86).set()
        rect.fill(using: .sourceAtop)
        return true
    }
    ink.draw(in: NSRect(x: (s - glyph.width) / 2, y: (s - glyph.height) / 2, width: glyph.width, height: glyph.height))
}

NSGraphicsContext.restoreGraphicsState()
try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
