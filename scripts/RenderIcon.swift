// Draws the Watchlamp icon (a 1024 px PNG): the board's lamp on a dark tile.
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

let green = NSColor(srgbRed: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0, alpha: 1)
let d = s * 0.5
let outer = NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)
let lens = outer.insetBy(dx: d * 0.075, dy: d * 0.075)

NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = green
glow.shadowBlurRadius = s * 0.1
glow.shadowOffset = .zero
glow.set()
green.setFill()
NSBezierPath(ovalIn: lens).fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(white: 0.34, alpha: 1), ending: NSColor(white: 0.1, alpha: 1))?
    .draw(in: NSBezierPath(ovalIn: outer), angle: -90)
let glass = NSBezierPath(ovalIn: lens)
NSGradient(colors: [mix(green, 0.55, .white), green, mix(green, 0.32, .black)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)?.draw(in: glass, relativeCenterPosition: NSPoint(x: 0, y: 0.24))
NSGradient(colors: [NSColor(white: 1, alpha: 0.45), NSColor(white: 1, alpha: 0)], atLocations: [0, 1],
           colorSpace: .sRGB)?.draw(in: glass, relativeCenterPosition: NSPoint(x: -0.2, y: 0.6))

// The comet that circles the bezel while Claude works: bright head, tail fading out behind it.
let center = NSPoint(x: s / 2, y: s / 2)
let ringRadius = d / 2 - d * 0.075 / 2
let ringWidth = d * 0.075 * 0.9
let headAngle: CGFloat = 18, tailLength: CGFloat = 160, steps = 80
let light = mix(green, 0.75, .white)
for i in 0..<steps {
    let t0 = CGFloat(i) / CGFloat(steps), t1 = CGFloat(i + 1) / CGFloat(steps)   // 0 = tail end, 1 = head
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: ringRadius, startAngle: headAngle + tailLength * (1 - t0),
                  endAngle: headAngle + tailLength * (1 - t1), clockwise: true)
    arc.lineWidth = ringWidth
    light.withAlphaComponent(pow(t1, 1.6)).setStroke()
    arc.stroke()
}
NSGraphicsContext.saveGraphicsState()
let headGlow = NSShadow()
headGlow.shadowColor = light
headGlow.shadowBlurRadius = ringWidth * 1.2
headGlow.shadowOffset = .zero
headGlow.set()
light.setFill()
let head = NSPoint(x: center.x + ringRadius * cos(headAngle * .pi / 180), y: center.y + ringRadius * sin(headAngle * .pi / 180))
NSBezierPath(ovalIn: NSRect(x: head.x - ringWidth / 2, y: head.y - ringWidth / 2, width: ringWidth, height: ringWidth)).fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
