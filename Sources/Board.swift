import AppKit

/// What one lamp on the board displays.
struct LampItem {
    let id: String
    let label: String
    let state: LightState
    let status: String
    let detail: String
    let tooltip: String
    let record: SessionRecord?
    var glyph: String?
    var dark = false
}

/// Layout numbers. Rects use bottom-left-origin layer coordinates.
///
/// Every length is a fixed multiple of one of two units, so the board keeps the same proportions at every
/// lamp size: d, the lamp diameter, for what surrounds the lamp (its glow), and u, the text unit, for what
/// surrounds the text. u is the status text size of the horizontal layout; like all text it has a floor
/// so it stays readable next to small lamps.
struct Metrics {
    let d: CGFloat
    let vertical: Bool
    let showDetail: Bool
    var rtl = false
    var maxWidth = CGFloat.greatestFiniteMagnitude   // the screen's width: rows wrap rather than run off it

    var u: CGFloat { max(11, d * 0.135) }
    var sideMargin: CGFloat { u * 1.25 }     // board edge to the text column
    var bottomMargin: CGFloat { u * 1.35 }   // below the last line of text
    var glowRoom: CGFloat { d * 0.2 }        // added where a lamp's glow meets the board edge
    var topPad: CGFloat { sideMargin + glowRoom }
    var bottomPad: CGFloat { vertical ? topPad : bottomMargin }
    var leftPad: CGFloat { vertical && !rtl ? topPad : sideMargin }
    var rightPad: CGFloat { vertical && rtl ? topPad : sideMargin }
    var bezel: CGFloat { max(2, d * 0.075) }
    var lampGap: CGFloat { d * 0.07 + u * 0.5 }   // clears the glow below the lamp, and the text
    var lineGap: CGFloat { u / 3 }
    var nameSize: CGFloat { max(13, d * (vertical ? 0.22 : 0.18)) }
    var statusSize: CGFloat { max(11, d * (vertical ? 0.16 : 0.135)) }
    var detailSize: CGFloat { max(10, d * (vertical ? 0.125 : 0.11)) }
    var nameLine: CGFloat { ceil(nameSize * 1.3) }
    var pillHeight: CGFloat { ceil(statusSize * 1.85) }
    var pillPadding: CGFloat { statusSize * 0.75 }
    var detailLine: CGFloat { ceil(detailSize * 1.4) }
    var textHeight: CGFloat { nameLine + lineGap + pillHeight + (showDetail ? lineGap + detailLine : 0) }
    // Horizontal: fits the longest status ("Wartet auf dich 03:42", 9.7 em) in every language; the detail line
    // truncates. Vertical: as wide as the text needs (see BoardView.textFit), up to a limit.
    var textFit: CGFloat?
    var textWidth: CGFloat { vertical ? min(textFit ?? .greatestFiniteMagnitude, u * 15.5) : u * 10.75 }
    var cellWidth: CGFloat { vertical ? d + lampGap * 1.4 + textWidth : textWidth }
    var cellHeight: CGFloat { vertical ? max(d, textHeight) : d + lampGap + textHeight }
    var columnSpacing: CGFloat { u * 0.9 }
    var rowSpacing: CGFloat { u * 1.48 }
    var cornerRadius: CGFloat { u * 1.33 }

    /// A row holds at most four lamps, and only as many as fit on the screen; more sessions wrap onto new rows.
    func columns(_ count: Int) -> Int {
        guard !vertical else { return 1 }
        let fitting = Int((maxWidth - leftPad - rightPad + columnSpacing) / (cellWidth + columnSpacing))
        return min(max(1, count), 4, max(1, fitting))
    }
    func rows(_ count: Int) -> Int { (max(1, count) + columns(count) - 1) / columns(count) }

    func boardSize(count: Int) -> NSSize {
        let c = CGFloat(columns(count)), r = CGFloat(rows(count))
        return NSSize(width: leftPad + rightPad + c * cellWidth + (c - 1) * columnSpacing,
                      height: topPad + bottomPad + r * cellHeight + (r - 1) * rowSpacing)
    }

    func cellRect(_ index: Int, count: Int, board: NSSize) -> CGRect {
        let c = columns(count)
        let column = CGFloat(rtl ? c - 1 - index % c : index % c), row = CGFloat(index / c)
        let top = topPad + row * (cellHeight + rowSpacing)
        return CGRect(x: leftPad + column * (cellWidth + columnSpacing), y: board.height - top - cellHeight,
                      width: cellWidth, height: cellHeight)
    }
}

/// One lamp and its labels.
@MainActor
final class LampCell {
    // Soft light around the lamp: breathes while Claude works, blinks when it needs you.
    private let glow = CALayer()
    private let bloom = CAGradientLayer()
    private let halo = CALayer()
    // The lamp itself: metal bezel, glass lens, highlight and state glyph.
    private let lamp = CALayer()
    private let bezel = CAGradientLayer()
    private let glass = CAGradientLayer()
    private let shine = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let glyph = CALayer()
    // A comet circling the bezel while Claude works.
    private let spinner = CAGradientLayer()
    private let spinnerRing = CAShapeLayer()
    private let name = CATextLayer()
    private let pill = CALayer()
    private let status = CATextLayer()
    private let detail = CATextLayer()

    private var metrics = Metrics(d: 110, vertical: false, showDetail: true)
    private var textLeft: CGFloat = 0
    private var pillY: CGFloat = 0
    private var styleKey = ""
    private var textKeys = ["", "", ""]
    private var nameFitKey = ""
    private var nameFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private var statusFitKey = ""
    private var statusFont = NSFont.systemFont(ofSize: 12)

    init(parent: CALayer) {
        bloom.type = .radial
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 1, y: 1)
        bloom.locations = [0, 0.48, 0.74, 1]
        halo.shadowOffset = .zero
        glow.addSublayer(bloom)
        glow.addSublayer(halo)

        bezel.colors = [NSColor(white: 0.32, alpha: 1).cgColor, NSColor(white: 0.1, alpha: 1).cgColor]
        bezel.startPoint = CGPoint(x: 0.5, y: 1)
        bezel.endPoint = CGPoint(x: 0.5, y: 0)
        glass.type = .radial
        glass.startPoint = CGPoint(x: 0.5, y: 0.62)
        glass.endPoint = CGPoint(x: 1.12, y: 1.24)
        glass.locations = [0, 0.55, 1]
        glass.masksToBounds = true
        shine.type = .radial
        shine.startPoint = CGPoint(x: 0.4, y: 0.8)
        shine.endPoint = CGPoint(x: 0.9, y: 1.3)
        shine.colors = [NSColor(white: 1, alpha: 0.45).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        shine.masksToBounds = true
        rim.fillColor = nil
        rim.strokeColor = NSColor(white: 0, alpha: 0.45).cgColor
        glyph.contentsGravity = .resizeAspect
        for sub in [bezel, glass, shine, rim, glyph] as [CALayer] { lamp.addSublayer(sub) }
        // Static between state changes: cache as bitmaps so the pulses are cheap fades.
        glow.shouldRasterize = true
        lamp.shouldRasterize = true

        spinner.type = .conic
        spinner.startPoint = CGPoint(x: 0.5, y: 0.5)
        spinner.endPoint = CGPoint(x: 1, y: 0.5)
        spinner.locations = [0, 0.4, 1]
        spinnerRing.fillColor = nil
        spinnerRing.strokeColor = NSColor.black.cgColor
        spinner.mask = spinnerRing
        spinner.isHidden = true

        for text in [name, status, detail] {
            text.isWrapped = false
            text.truncationMode = .none   // we truncate ourselves; CATextLayer drops lines that don't fit
        }
        name.shadowColor = NSColor.black.cgColor
        name.shadowOpacity = 0.6
        name.shadowRadius = 2
        name.shadowOffset = CGSize(width: 0, height: -1)
        for layer in [glow, lamp, spinner, name, pill, status, detail] as [CALayer] { parent.addSublayer(layer) }
    }

    func remove() {
        for layer in [glow, lamp, spinner, name, pill, status, detail] as [CALayer] { layer.removeFromSuperlayer() }
    }

    func layout(in cell: CGRect, metrics m: Metrics) {
        metrics = m
        let d = m.d
        let frame = m.vertical
            ? CGRect(x: m.rtl ? cell.maxX - d : cell.minX, y: cell.midY - d / 2, width: d, height: d)
            : CGRect(x: cell.midX - d / 2, y: cell.maxY - d, width: d, height: d)
        let bounds = CGRect(x: 0, y: 0, width: d, height: d)
        let lens = bounds.insetBy(dx: m.bezel, dy: m.bezel)

        glow.frame = frame
        bloom.frame = bounds.insetBy(dx: -d * 0.42, dy: -d * 0.42)
        halo.frame = lens
        halo.cornerRadius = lens.width / 2
        halo.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: lens.size), transform: nil)

        lamp.frame = frame
        bezel.frame = bounds
        bezel.cornerRadius = d / 2
        for layer in [glass, shine] {
            layer.frame = lens
            layer.cornerRadius = lens.width / 2
        }
        rim.frame = bounds
        rim.lineWidth = max(1, d * 0.012)
        rim.path = CGPath(ellipseIn: lens.insetBy(dx: rim.lineWidth / 2, dy: rim.lineWidth / 2), transform: nil)

        spinner.frame = frame
        spinnerRing.frame = bounds
        spinnerRing.lineWidth = m.bezel * 0.9
        spinnerRing.path = CGPath(ellipseIn: bounds.insetBy(dx: m.bezel / 2, dy: m.bezel / 2), transform: nil)

        textLeft = m.vertical && !m.rtl ? cell.minX + d + m.lampGap * 1.4 : cell.minX
        var top = m.vertical ? (cell.height - m.textHeight) / 2 : d + m.lampGap
        name.frame = CGRect(x: textLeft, y: cell.maxY - top - m.nameLine, width: m.textWidth, height: m.nameLine)
        top += m.nameLine + m.lineGap
        pillY = cell.maxY - top - m.pillHeight
        top += m.pillHeight + m.lineGap
        detail.frame = CGRect(x: textLeft, y: cell.maxY - top - m.detailLine, width: m.textWidth, height: m.detailLine)
        detail.isHidden = !m.showDetail
        let side: CATextLayerAlignmentMode = m.rtl ? .right : .left
        name.alignmentMode = m.vertical ? side : .center
        detail.alignmentMode = m.vertical ? side : .center
        status.alignmentMode = .center
        pill.cornerRadius = m.pillHeight / 2
        styleKey = ""
        textKeys = ["", "", ""]
    }

    func show(_ item: LampItem, palette: Palette, scale: CGFloat) {
        let m = metrics
        let lit = palette.lit(item.state) && !item.dark
        let color = palette.color(item.state)
        let key = "\(item.state.rawValue)|\(palette.id)|\(lit)|\(item.glyph ?? "")|\(scale)"
        if key != styleKey {
            styleKey = key
            applyStyle(item, lit: lit, color: color, scale: scale)
        }

        // Shrink long project names (down to two thirds) before truncating them.
        let fitKey = "\(item.label)|\(m.nameSize)|\(m.textWidth)"
        if fitKey != nameFitKey {
            nameFitKey = fitKey
            nameFont = Fonts.rounded(m.nameSize, .bold)
            while nameFont.pointSize > m.nameSize * 0.66,
                  (item.label as NSString).size(withAttributes: [.font: nameFont]).width > m.textWidth - 6 {
                nameFont = Fonts.rounded(nameFont.pointSize - 0.5, .bold)
            }
        }
        setText(0, name, item.label, nameFont, NSColor(white: 0.97, alpha: 1), "name", scale, width: m.textWidth - 4)

        // Status in a tinted pill, centred under the lamp (or beside it in the vertical layout).
        // Long translations shrink a little first, so the timer stays visible.
        let room = m.textWidth - m.pillPadding * 2
        let shape = "\(item.status.map { $0.isNumber ? "0" : $0 })|\(m.statusSize)|\(room)"   // digits are fixed-width
        if shape != statusFitKey {
            statusFitKey = shape
            statusFont = Fonts.rounded(m.statusSize, .semibold, monospacedDigits: true)
            while statusFont.pointSize > m.statusSize * 0.8,
                  (item.status as NSString).size(withAttributes: [.font: statusFont]).width > room {
                statusFont = Fonts.rounded(statusFont.pointSize - 0.5, .semibold, monospacedDigits: true)
            }
        }
        let font = statusFont
        let shown = Self.fit(item.status, font: font, width: room)
        let textWidth = ceil((shown as NSString).size(withAttributes: [.font: font]).width) + 2
        let pillWidth = textWidth + m.pillPadding * 2
        let pillX = !m.vertical ? textLeft + (m.textWidth - pillWidth) / 2 : m.rtl ? textLeft + m.textWidth - pillWidth : textLeft
        pill.frame = CGRect(x: pillX, y: pillY, width: pillWidth, height: m.pillHeight)
        let lineHeight = ceil(m.statusSize * 1.32)
        status.frame = CGRect(x: pillX + m.pillPadding - 1, y: pillY + (m.pillHeight - lineHeight) / 2,
                              width: textWidth + 2, height: lineHeight)
        let statusColor = lit ? color.mixed(0.3, with: .white) : NSColor(white: 0.66, alpha: 1)
        setText(1, status, shown, font, statusColor, key, scale, width: .greatestFiniteMagnitude)
        setText(2, detail, item.detail, .systemFont(ofSize: m.detailSize, weight: .regular),
                NSColor(white: 0.6, alpha: 1), "detail", scale, width: m.textWidth - 4)
    }

    private func applyStyle(_ item: LampItem, lit: Bool, color: NSColor, scale: CGFloat) {
        let d = metrics.d
        glow.rasterizationScale = scale
        lamp.rasterizationScale = scale
        bloom.isHidden = !lit
        halo.isHidden = !lit
        if lit {
            bloom.colors = [0.55, 0.32, 0.1, 0].map { color.withAlphaComponent($0).cgColor }
            halo.backgroundColor = color.cgColor
            halo.shadowColor = color.cgColor
            halo.shadowRadius = d * 0.16
            halo.shadowOpacity = 0.95
            glass.colors = [color.mixed(0.55, with: .white).cgColor, color.cgColor, color.mixed(0.32, with: .black).cgColor]
            shine.opacity = 1
        } else {
            glass.colors = [NSColor(white: 0.33, alpha: 1).cgColor, NSColor(white: 0.18, alpha: 1).cgColor,
                            NSColor(white: 0.1, alpha: 1).cgColor]
            shine.opacity = 0.45
        }
        pill.backgroundColor = (lit ? color.withAlphaComponent(0.2) : NSColor(white: 1, alpha: 0.08)).cgColor

        // Dark glyph on bright lenses (yellow), white on the rest.
        let ink = !lit ? NSColor(white: 1, alpha: 0.3)
            : color.luminance > 0.72 ? NSColor(white: 0, alpha: 0.55) : NSColor(white: 1, alpha: 0.95)
        if let name = item.glyph, let image = Glyphs.image(name, pointSize: d * 0.3, color: ink, scale: scale) {
            let w = CGFloat(image.width) / scale, h = CGFloat(image.height) / scale
            glyph.contents = image
            glyph.contentsScale = scale
            glyph.frame = CGRect(x: (d - w) / 2, y: (d - h) / 2, width: w, height: h)
            glyph.isHidden = false
        } else {
            glyph.isHidden = true
        }

        Anim.stop(glow)
        Anim.stop(lamp)
        let spinning = lit && item.state == .working
        spinner.isHidden = !spinning
        if spinning {
            let head = color.mixed(0.75, with: .white)
            spinner.colors = [head.cgColor, head.withAlphaComponent(0).cgColor, head.withAlphaComponent(0).cgColor]
            Anim.spin(spinner, seconds: 1.6)
            Anim.fade(glow, to: 0.35, duration: 1.4, ease: .easeInEaseOut)
        } else {
            Anim.stop(spinner)
        }
        if lit && item.state == .waiting {
            Anim.fade(glow, to: 0, duration: 0.42, ease: .easeIn)
            Anim.fade(lamp, to: 0.12, duration: 0.42, ease: .easeIn)
        }
    }

    private func setText(_ index: Int, _ layer: CATextLayer, _ text: String, _ font: NSFont, _ color: NSColor,
                         _ colorKey: String, _ scale: CGFloat, width: CGFloat) {
        let key = "\(text)|\(font.pointSize)|\(colorKey)|\(scale)|\(width)"
        guard key != textKeys[index] else { return }
        textKeys[index] = key
        layer.contentsScale = scale
        layer.string = NSAttributedString(string: Self.fit(text, font: font, width: width),
                                          attributes: [.font: font, .foregroundColor: color])
    }

    /// CATextLayer draws nothing at all for a line that does not fit, so truncate it ourselves.
    static func fit(_ text: String, font: NSFont, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ s: String) -> Bool { (s as NSString).size(withAttributes: attributes).width <= width }
        if fits(text) { return text }
        let chars = Array(text)
        var low = 0, high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(String(chars[..<mid]) + "…") { low = mid } else { high = mid - 1 }
        }
        return String(chars[..<low]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The floating board: one lamp per session. Drag to move, click a lamp to jump to its app, right-click for the menu.
@MainActor
final class BoardView: NSView {
    var onClick: ((SessionRecord) -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?
    private(set) var preferredSize = NSSize(width: 200, height: 200)

    private let background = CAGradientLayer()
    private var cells: [LampCell] = []
    private var frames: [CGRect] = []
    private var items: [LampItem] = []
    private var structureKey = ""
    private var fitKey = ""
    private var fitWidth: CGFloat = 0
    private var tooltipKey = ""
    private var tooltipOwners: [NSString] = []
    private var mouseDownEvent: NSEvent?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(background)
        background.borderWidth = 1
        background.borderColor = NSColor(white: 1, alpha: 0.09).cgColor
        background.colors = [NSColor(white: 0.135, alpha: 1).cgColor, NSColor(white: 0.065, alpha: 1).cgColor]
        background.startPoint = CGPoint(x: 0.5, y: 1)
        background.endPoint = CGPoint(x: 0.5, y: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ newItems: [LampItem], look: Look, scale: CGFloat? = nil) {
        guard let root = layer else { return }
        let screen = window?.screen ?? NSScreen.main
        var m = Metrics(d: CGFloat(look.size), vertical: look.vertical, showDetail: look.showDetail, rtl: look.rtl,
                        maxWidth: screen?.visibleFrame.width ?? .greatestFiniteMagnitude)
        if m.vertical {
            // Measuring text is the costly part of a refresh; redo it only when what it measures changes.
            let key = "\(m.d)|\(m.showDetail)|\(Lang.code ?? "")|" + newItems.map {
                "\($0.label)\u{1}\($0.status.count)\u{1}\($0.record == nil ? $0.detail : "")"
            }.joined(separator: "\u{2}")
            if key != fitKey {
                fitKey = key
                fitWidth = Self.textFit(newItems, m)
            }
            m.textFit = fitWidth
        }
        let size = m.boardSize(count: newItems.count)
        let scale = scale ?? window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let key = "\(newItems.count)|\(m.columns(newItems.count))|\(m.d)|\(m.vertical)|\(m.showDetail)|\(m.rtl)|\(m.textWidth)"
        if key != structureKey {
            structureKey = key
            cells.forEach { $0.remove() }
            cells = newItems.map { _ in LampCell(parent: root) }
            frames = newItems.indices.map { m.cellRect($0, count: newItems.count, board: size) }
            for (cell, frame) in zip(cells, frames) { cell.layout(in: frame, metrics: m) }
        }
        background.frame = CGRect(origin: .zero, size: size)
        background.cornerRadius = m.cornerRadius
        root.cornerRadius = m.cornerRadius
        root.masksToBounds = true
        for (cell, item) in zip(cells, newItems) { cell.show(item, palette: look.palette, scale: scale) }
        CATransaction.commit()

        items = newItems
        preferredSize = size
        updateTooltips()
    }

    /// The vertical layout's text column ends where its text does, so the right margin matches the others.
    /// It fits the lines that stay put: the names, every status, a finished turn's summary, and the hint shown
    /// when there are no sessions. What a session is doing changes with every step; that line truncates
    /// rather than resizing the board.
    private static func textFit(_ items: [LampItem], _ m: Metrics) -> CGFloat {
        func width(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let statusFont = Fonts.rounded(m.statusSize, .semibold, monospacedDigits: true)
        let statuses = [L("Running %@", Format.clock(0)), L("Waiting for you %@", Format.clock(0)), L("Your turn"), L("Idle"),
                        Format.phrase("@interrupted"), Format.phrase("@failed")] + items.map(\.status)
        let nameFont = Fonts.rounded(m.nameSize, .bold)
        let detailFont = NSFont.systemFont(ofSize: m.detailSize)
        let summary = L("Finished %@", L("%ld min ago", 59)) + " · " + L("Took %@", Format.clock(3599))
        let lines = [summary] + items.filter { $0.record == nil }.map(\.detail)
        return max(statuses.map { width($0, statusFont) + 2 + m.pillPadding * 2 }.max() ?? 0,
                   items.map { width($0.label, nameFont) + 6 }.max() ?? 0,
                   m.showDetail ? lines.map { width($0, detailFont) + 4 }.max() ?? 0 : 0)
    }

    private func updateTooltips() {
        let key = items.map(\.tooltip).joined(separator: "\u{1}") + structureKey
        guard key != tooltipKey else { return }
        tooltipKey = key
        removeAllToolTips()
        // An NSString owner answers with its own text; the view does not retain owners, so keep them.
        tooltipOwners = items.map { $0.tooltip as NSString }
        for (frame, owner) in zip(frames, tooltipOwners) { addToolTip(frame, owner: owner, userData: nil) }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragged = false
        window?.orderFrontRegardless()   // when it isn't kept on top, a click brings it forward
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let down = mouseDownEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        if hypot(b.x - a.x, b.y - a.y) > 3 {
            dragged = true
            window?.performDrag(with: down)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !dragged else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let i = frames.firstIndex(where: { $0.contains(point) }), i < items.count, let record = items[i].record {
            onClick?(record)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event, self)
    }
}

/// Borderless, non-activating, on every Space and above full-screen apps.
final class LightPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = content
        keepOnTop(true)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// On top: above every window, full-screen apps included. Otherwise an ordinary window that others can cover.
    func keepOnTop(_ onTop: Bool) {
        isFloatingPanel = onTop
        level = onTop ? .statusBar : .normal
    }
}
