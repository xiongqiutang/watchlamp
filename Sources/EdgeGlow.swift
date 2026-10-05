import AppKit

/// A glowing frame around every screen, click-through, for when the board is out of sight.
@MainActor
final class EdgeGlow {
    private var windows: [NSWindow] = []
    private var frames: [CAShapeLayer] = []
    private var shownKey = ""

    /// `state == nil` hides the glow.
    func update(state: LightState?, palette: Palette) {
        let key = state.map { "\($0.rawValue)|\(palette.id)" } ?? ""
        guard key != shownKey else { return }
        shownKey = key
        guard let state else {
            close()   // free the full-screen windows until they are needed again
            return
        }
        if windows.isEmpty { build() }
        let color = palette.color(state).cgColor
        for (window, frame) in zip(windows, frames) {
            frame.strokeColor = color
            frame.shadowColor = color
            Anim.pulse(frame, state: state, lit: true)
            window.orderFrontRegardless()
        }
    }

    /// Screens were added, removed or rearranged: rebuild on the next update.
    func rebuild() {
        close()
        shownKey = ""
    }

    private func close() {
        windows.forEach { $0.close() }
        windows = []
        frames = []
    }

    private func build() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.layer = CALayer()
            view.wantsLayer = true
            let thickness: CGFloat = 14
            let frame = CAShapeLayer()
            frame.frame = view.bounds
            let ring = CGPath(roundedRect: view.bounds.insetBy(dx: thickness / 2, dy: thickness / 2),
                              cornerWidth: 14, cornerHeight: 14, transform: nil)
            frame.path = ring
            frame.shadowPath = ring.copy(strokingWithWidth: thickness, lineCap: .butt, lineJoin: .round, miterLimit: 10)
            frame.fillColor = nil
            frame.lineWidth = thickness
            frame.shadowOffset = .zero
            frame.shadowRadius = 30
            frame.shadowOpacity = 1
            view.layer?.addSublayer(frame)
            window.contentView = view

            windows.append(window)
            frames.append(frame)
        }
    }
}
