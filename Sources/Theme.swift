import AppKit

struct Palette {
    let id: String
    let title: String
    let working: NSColor
    let waiting: NSColor
    let idle: NSColor
    /// Whether the idle lamp glows (traffic-light style) or goes dark.
    let idleLit: Bool

    func color(_ state: LightState) -> NSColor {
        switch state {
        case .working: return working
        case .waiting: return waiting
        case .idle: return idle
        }
    }

    func lit(_ state: LightState) -> Bool { state == .idle ? idleLit : true }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let all: [Palette] = [
        Palette(id: "classic", title: "Classic: working green · waiting red · idle off",
                working: rgb(0x30D158), waiting: rgb(0xFF453A), idle: rgb(0x48484A), idleLit: false),
        // Seen from your side, like Aignals: red means wait, yellow needs a click, green is your turn.
        Palette(id: "yourturn", title: "Your turn: working red · click-me yellow · your turn green",
                working: rgb(0xFF453A), waiting: rgb(0xFFD60A), idle: rgb(0x30D158), idleLit: true),
        Palette(id: "accessible", title: "Color-blind friendly: working blue · waiting orange · idle off",
                working: rgb(0x0A84FF), waiting: rgb(0xFF9F0A), idle: rgb(0x48484A), idleLit: false),
    ]
}

/// The board's appearance, decoupled from UserDefaults so snapshots can render any variant.
struct Look {
    var size: Double
    var vertical: Bool
    var showDetail: Bool
    var palette: Palette
    var rtl = false
    var textScale: Double = 1
}

@MainActor
final class Prefs {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    static let sizes: [(String, Double)] = [("Small", 56), ("Medium", 80), ("Large", 110), ("X-Large", 160), ("Huge", 240)]
    static let textSizes: [(String, Double)] = [("Small", 0.8), ("Medium", 1), ("Large", 1.25), ("X-Large", 1.5)]
    static let edgeModes = ["Off", "Only when waiting for you", "While working or waiting"]

    var size: Double {
        get { defaults.object(forKey: "lampSize") as? Double ?? 110 }
        set { defaults.set(newValue, forKey: "lampSize") }
    }
    /// Multiplies the board's text, independent of the lamp size.
    var textScale: Double {
        get { defaults.object(forKey: "textScale") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "textScale") }
    }
    var vertical: Bool {
        get { defaults.bool(forKey: "vertical") }
        set { defaults.set(newValue, forKey: "vertical") }
    }
    var showDetail: Bool {
        get { defaults.object(forKey: "showDetail") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showDetail") }
    }
    /// 0 off, 1 only while waiting for you, 2 while working or waiting.
    var edgeMode: Int {
        get { defaults.object(forKey: "edgeMode") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "edgeMode") }
    }
    var hideWhenEmpty: Bool {
        get { defaults.bool(forKey: "hideWhenEmpty") }
        set { defaults.set(newValue, forKey: "hideWhenEmpty") }
    }
    /// A language code from Lang.choices, or nil to follow the system.
    var language: String? {
        get { defaults.string(forKey: "language") }
        set { defaults.set(newValue, forKey: "language") }
    }
    var paletteID: String {
        get { defaults.string(forKey: "palette") ?? "classic" }
        set { defaults.set(newValue, forKey: "palette") }
    }
    var palette: Palette { Palette.all.first { $0.id == paletteID } ?? Palette.all[0] }
    var look: Look {
        Look(size: size, vertical: vertical, showDetail: showDetail, palette: palette, rtl: Lang.rtl, textScale: textScale)
    }
    var origin: NSPoint? {
        get {
            guard let xy = defaults.array(forKey: "panelOrigin") as? [Double], xy.count == 2 else { return nil }
            return NSPoint(x: xy[0], y: xy[1])
        }
        set {
            if let p = newValue { defaults.set([Double(p.x), Double(p.y)], forKey: "panelOrigin") }
            else { defaults.removeObject(forKey: "panelOrigin") }
        }
    }
}

enum Format {
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func ago(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return L("just now") }
        if s < 3600 { return L("%ld min ago", s / 60) }
        if s < 86400 { return L("%ld h ago", s / 3600) }
        return L("%ld d ago", s / 86400)
    }

    /// `yourTurn`: the palette lights the idle lamp green, so say so.
    static func status(_ r: SessionRecord, now: Double, yourTurn: Bool = false) -> String {
        switch r.state {
        case .working: return L("Running %@", clock(now - (r.turnStarted ?? r.stateSince)))
        case .waiting: return L("Waiting for you %@", clock(now - (r.pending.last?.since ?? r.stateSince)))
        case .idle: return r.endNote.map(phrase) ?? L(yourTurn ? "Your turn" : "Idle")
        }
    }

    static func detail(_ r: SessionRecord, now: Double) -> String {
        guard r.state == .idle else { return phrase(r.detail) }
        var parts: [String] = []
        if let f = r.finishedAt { parts.append(L(r.endNote == nil ? "Finished %@" : "Ended %@", ago(now - f))) }
        if let d = r.lastTurnSeconds, d >= 1 { parts.append(L("Took %@", clock(d))) }
        return parts.isEmpty ? L("Waiting for a new task") : parts.joined(separator: " · ")
    }

    /// The hook stores language-neutral tokens such as "@edit:main.swift"; translate them for display.
    /// Anything else (older records) is shown as written.
    static func phrase(_ text: String) -> String {
        guard text.hasPrefix("@") else { return text }
        let body = text.dropFirst()
        let colon = body.firstIndex(of: ":")
        let key = String(colon.map { body[..<$0] } ?? body)
        let arg = colon.map { String(body[body.index(after: $0)...]) }
        func with(_ label: String) -> String { arg.map { "\(label) · \($0)" } ?? label }
        switch key {
        case "thinking": return L("Thinking…")
        case "compacting": return L("Compacting context…")
        case "cmd": return with(L("Command"))
        case "read": return with(L("Read"))
        case "edit": return with(L("Edit"))
        case "write": return with(L("Write"))
        case "search": return with(L("Search"))
        case "find": return with(L("Find files"))
        case "fetch": return with(L("Fetch page"))
        case "web": return with(L("Web search"))
        case "task": return with(L("Subtask"))
        case "todo": return L("Updating the task list")
        case "skill": return with(L("Skill"))
        case "tool": return with(L("Tool"))
        case "ask": return L("Waiting for your answer")
        case "plan": return L("Waiting for you to approve the plan")
        case "perm": return arg.map { L("Needs your permission") + " · " + phrase($0) } ?? L("Needs your permission")
        case "input": return with(L("Waiting for your input"))
        case "error": return arg.map { L("Stopped on an error") + " · " + $0 } ?? L("Stopped on an error, take a look")
        case "failed": return L("Stopped on an error")
        case "interrupted": return L("Interrupted")
        case "background": return L("Background tasks ×%@", arg ?? "")
        default: return arg ?? key
        }
    }

    /// SF Symbol drawn on the lamp: a raised hand when Claude needs you, a tick when a turn finished.
    static func glyph(_ r: SessionRecord) -> String? {
        switch r.state {
        case .working: return nil
        case .waiting: return r.pending.last?.key == "error" ? "exclamationmark" : "hand.raised.fill"
        case .idle: return r.finishedAt == nil ? nil : (r.endNote == nil ? "checkmark" : "pause.fill")
        }
    }
}

enum Fonts {
    /// SF Pro Rounded (Chinese falls back to PingFang), optionally with fixed-width digits so timers don't jiggle.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight, monospacedDigits: Bool = false) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if let rounded = descriptor.withDesign(.rounded) { descriptor = rounded }
        if monospacedDigits {
            // kNumberSpacingType / kMonospacedNumbersSelector
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: 6, NSFontDescriptor.FeatureKey.selectorIdentifier: 0,
            ]]])
        }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

@MainActor
enum Glyphs {
    private static var cache: [String: CGImage] = [:]

    /// A tinted SF Symbol rendered at the screen's pixel density.
    static func image(_ name: String, pointSize: CGFloat, color: NSColor, scale: CGFloat) -> CGImage? {
        let key = "\(name)|\(pointSize)|\(color.description)|\(scale)"
        if let hit = cache[key] { return hit }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)) else { return nil }
        let size = symbol.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                                         pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        symbol.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        cache[key] = rep.cgImage
        return rep.cgImage
    }
}

enum Anim {
    static let frameRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)

    /// Fades a layer down and back up forever.
    static func fade(_ layer: CALayer, to value: Float, duration: Double, ease: CAMediaTimingFunctionName) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = value
        fade.duration = duration
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: ease)
        fade.preferredFrameRateRange = frameRate
        layer.add(fade, forKey: "pulse")
    }

    /// Clockwise rotation, one turn per `seconds`.
    static func spin(_ layer: CALayer, seconds: Double) {
        guard layer.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0.0
        turn.toValue = -2 * Double.pi
        turn.duration = seconds
        turn.repeatCount = .infinity
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 60)
        layer.add(turn, forKey: "spin")
    }

    static func stop(_ layer: CALayer) {
        layer.removeAnimation(forKey: "pulse")
        layer.removeAnimation(forKey: "spin")
    }

    /// The screen-edge glow: working breathes slowly; waiting blinks fast.
    static func pulse(_ layer: CALayer, state: LightState, lit: Bool) {
        stop(layer)
        guard lit, state != .idle else { return }
        state == .waiting
            ? fade(layer, to: 0.08, duration: 0.4, ease: .easeIn)
            : fade(layer, to: 0.55, duration: 1.2, ease: .easeInEaseOut)
    }
}

extension NSColor {
    func mixed(_ fraction: CGFloat, with other: NSColor) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }

    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}
