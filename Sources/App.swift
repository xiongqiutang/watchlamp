import AppKit
import ServiceManagement

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping @MainActor () -> Void = {}) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor @objc private func fire() { handler() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Prefs.shared
    private let board = BoardView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    private lazy var panel = LightPanel(content: board)
    private let edge = EdgeGlow()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var sessions: [SessionRecord] = []
    private var lastMaintenance = 0.0
    private var iconKey = ""
    private var appNames: [String: String] = [:]
    private let cache = SessionCache()
    private var transcriptSizes: [String: UInt64] = [:]
    private var connection = Connection.State.disconnected
    private var lastConnectionCheck = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil)
            return
        }
        Store.ensureDirs()
        Lang.use(prefs.language)
        if Self.runningFromTemporaryLocation {
            askToMoveToApplications()
            return
        }
        board.onClick = { [weak self] record in self?.reveal(record) }
        board.onMenu = { [weak self] event, view in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: view)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
        refresh()
        restorePosition()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.1
        setUpConnection()
    }

    // MARK: - Connection to Claude Code

    /// Opened straight from the disk image, or from a quarantined download that macOS runs from a temporary
    /// read-only copy: hooks pointing there would break as soon as it closes.
    private static var runningFromTemporaryLocation: Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") { return true }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    private func askToMoveToApplications() {
        let alert = NSAlert()
        alert.messageText = L("Please move Watchlamp to your Applications folder first")
        alert.informativeText = L("Drag Watchlamp into the Applications folder and open it from there. Run from the disk image or the Downloads folder, it can't stay connected to Claude Code.")
        alert.addButton(withTitle: L("Quit Watchlamp"))
        bringToFront()
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func setUpConnection() {
        connection = Connection.state()
        switch connection {
        case .connected:
            break
        case .elsewhere:
            try? Connection.connect()   // the app was moved: point the hooks at this copy
            connection = Connection.state()
        case .disconnected, .noClaude:
            if !prefs.askedToConnect { DispatchQueue.main.async { self.offerToConnect() } }
        }
    }

    /// First launch: explain what connecting does, and offer launch at login alongside.
    private func offerToConnect() {
        prefs.askedToConnect = true
        let alert = NSAlert()
        alert.messageText = L("Connect Watchlamp to Claude Code?")
        alert.informativeText = L("Watchlamp adds a few hooks to Claude Code's settings (~/.claude/settings.json) so it can see what each session is doing. The current file is backed up first.")
        alert.addButton(withTitle: L("Connect to Claude Code"))
        alert.addButton(withTitle: L("Not now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Launch at login")
        alert.suppressionButton?.state = .on
        bringToFront()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if alert.suppressionButton?.state == .on && SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        connectNow()
    }

    private func connectNow() {
        do {
            try Connection.connect()
        } catch {
            showSettingsError(error)
        }
        connection = Connection.state()
        refresh()
    }

    private func disconnectNow() {
        do {
            try Connection.disconnect()
        } catch {
            showSettingsError(error)
        }
        connection = Connection.state()
        refresh()
    }

    private func showSettingsError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Couldn't update Claude Code's settings")
        alert.informativeText = (error as? Connection.Failure)?.message ?? error.localizedDescription
        bringToFront()
        alert.runModal()
    }

    private func bringToFront() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - Refresh loop

    private func refresh() {
        let now = Date().timeIntervalSince1970
        var list = cache.loadAll()
        if now - lastMaintenance >= 2 {
            lastMaintenance = now
            list = maintain(list, now: now)
        }
        if now - lastConnectionCheck >= 10 {
            lastConnectionCheck = now
            connection = Connection.state()
        }
        list.sort { ($0.started, $0.sessionId) < ($1.started, $1.sessionId) }
        sessions = list

        board.update(items(now: now), look: prefs.look)
        fitPanel()
        let overall = aggregate()
        edge.update(state: edgeState(overall), palette: prefs.palette)
        updateIcon(overall)
        if prefs.hideWhenEmpty && list.isEmpty {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Drops sessions whose Claude Code process has exited, and catches interrupts (which skip the Stop hook).
    private func maintain(_ list: [SessionRecord], now: Double) -> [SessionRecord] {
        var kept: [SessionRecord] = []
        for record in list {
            if let pid = record.pid, pid > 1, !Proc.alive(pid) {
                Store.locked { Store.remove(record.sessionId) }
                continue
            }
            if now - record.updated > 12 * 3600 {
                Store.locked { Store.remove(record.sessionId) }
                continue
            }
            var current = record
            let mainBusy = record.mainActive || record.pending.contains { $0.agent == "main" || $0.agent == "?" }
            // Only re-read a transcript that grew since the last look.
            if mainBusy, let path = record.transcript, let size = Transcript.stat(path)?.size,
               transcriptSizes.updateValue(size, forKey: path) != size,
               Transcript.endsWithInterrupt(path, after: record.updated) {
                Store.locked {
                    // Skip if a newer hook event landed in the meantime.
                    guard var fresh = Store.load(record.sessionId), fresh.updated == record.updated else { return }
                    fresh.endTurn(now, note: "@interrupted")
                    fresh.recompute(now)
                    Store.save(fresh)
                    current = fresh
                }
            }
            kept.append(current)
        }
        return kept
    }

    private func items(now: Double) -> [LampItem] {
        guard !sessions.isEmpty else {
            return [LampItem(id: "none", label: "Claude", state: .idle, status: L("No sessions"),
                             detail: connection == .connected ? L("Lights up when Claude Code starts working")
                                 : L("Not connected to Claude Code yet. Right-click to connect."),
                             tooltip: L("Watchlamp: no Claude Code session detected yet"), record: nil, dark: true)]
        }
        var totals: [String: Int] = [:]
        for s in sessions { totals[s.project, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return sessions.map { r in
            var label = r.project.isEmpty ? "Claude" : r.project
            if totals[r.project, default: 0] > 1 {
                seen[r.project, default: 0] += 1
                label += " #\(seen[r.project, default: 0])"
            }
            var tip = [r.cwd]
            if let title = r.title, !title.isEmpty { tip.append(title) }
            if let app = appName(r.hostBundle) { tip.append(L("Running in %@ · click to switch to it", app)) }
            return LampItem(id: r.sessionId, label: label, state: r.state,
                            status: Format.status(r, now: now, yourTurn: prefs.palette.idleLit),
                            detail: Format.detail(r, now: now), tooltip: tip.joined(separator: "\n"), record: r,
                            glyph: Format.glyph(r))
        }
    }

    private func aggregate() -> LightState? {
        if sessions.contains(where: { $0.state == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        return sessions.isEmpty ? nil : .idle
    }

    private func edgeState(_ overall: LightState?) -> LightState? {
        switch (prefs.edgeMode, overall) {
        case (1, .waiting?), (2, .waiting?): return .waiting
        case (2, .working?): return .working
        default: return nil
        }
    }

    private func updateIcon(_ overall: LightState?) {
        let palette = prefs.palette
        let key = "\(overall?.rawValue ?? "none")|\(palette.id)|\(sessions.count)"
        guard key != iconKey, let button = statusItem?.button else { return }
        iconKey = key
        let lit = overall.map(palette.lit) ?? false
        let color = overall.map(palette.color) ?? .gray
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 3.5, dy: 3.5))
            if lit {
                color.setFill()
                dot.fill()
            } else {
                NSColor.black.setStroke()
                dot.lineWidth = 1.6
                dot.stroke()
            }
            return true
        }
        image.isTemplate = !lit
        button.image = image
        let working = sessions.filter { $0.state == .working }.count
        let waiting = sessions.filter { $0.state == .waiting }.count
        button.toolTip = sessions.isEmpty ? L("Watchlamp: no sessions")
            : L("Watchlamp: %ld working, %ld waiting for you, %ld sessions in total", working, waiting, sessions.count)
    }

    private func appName(_ bundle: String?) -> String? {
        guard let bundle else { return nil }
        if let cached = appNames[bundle] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        appNames[bundle] = name
        return name
    }

    // MARK: - Panel placement

    private func fitPanel() {
        let size = board.preferredSize
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        var origin = old.origin
        if let visible = (panel.screen ?? NSScreen.screens.first)?.visibleFrame {
            // Grow away from the nearest screen edges so the board stays where it was parked.
            if old.midX > visible.midX { origin.x = old.maxX - size.width }
            if old.midY > visible.midY { origin.y = old.maxY - size.height }
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    private func restorePosition() {
        if let origin = prefs.origin {
            let frame = NSRect(origin: origin, size: panel.frame.size)
            let core = frame.insetBy(dx: frame.width * 0.3, dy: frame.height * 0.3)
            if NSScreen.screens.contains(where: { $0.frame.intersects(core) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        if let screen = NSScreen.screens.first { move(to: screen) }
    }

    private func move(to screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24))
        prefs.origin = panel.frame.origin
    }

    @objc private func panelMoved() {
        prefs.origin = panel.frame.origin
    }

    @objc private func screensChanged() {
        edge.rebuild()
        restorePosition()
        refresh()
    }

    // MARK: - Actions

    private func reveal(_ record: SessionRecord) {
        guard let bundle = record.hostBundle,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            NSSound.beep()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private func change(_ edit: (Prefs) -> Void) {
        edit(prefs)
        iconKey = ""
        refresh()
    }

    private func runDemo() {
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["demo", "12"]
        try? process.run()
    }

    private func setLanguage(_ code: String?) {
        Lang.use(code)
        change { $0.language = code }
    }

    private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Couldn't change the login item")
            alert.informativeText = error.localizedDescription + "\n" + L("You can also add it in System Settings › General › Login Items.")
            bringToFront()
            alert.runModal()
        }
    }

    // MARK: - Menu (menu bar icon and right-click on the board)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    private func fill(_ menu: NSMenu) {
        menu.autoenablesItems = false
        let now = Date().timeIntervalSince1970
        menu.addItem(ActionItem("Watchlamp", enabled: false))
        if connection != .connected {
            menu.addItem(ActionItem(L("Connect to Claude Code")) { [weak self] in self?.connectNow() })
        }
        if sessions.isEmpty { menu.addItem(ActionItem(L("No Claude Code sessions"), enabled: false)) }
        for item in items(now: now) {
            guard let record = item.record else { continue }
            let entry = ActionItem("\(item.label)　\(item.status)") { [weak self] in self?.reveal(record) }
            entry.image = dot(item.state)
            entry.toolTip = item.tooltip
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        menu.addItem(submenu(L("Lamp size"), Prefs.sizes.map { title, value in
            ActionItem(L(title), checked: prefs.size == value) { [weak self] in self?.change { $0.size = value } }
        }))
        menu.addItem(submenu(L("Text size"), Prefs.textSizes.map { title, value in
            ActionItem(L(title), checked: prefs.textScale == value) { [weak self] in self?.change { $0.textScale = value } }
        }))
        menu.addItem(submenu(L("Layout"), [
            ActionItem(L("Horizontal"), checked: !prefs.vertical) { [weak self] in self?.change { $0.vertical = false } },
            ActionItem(L("Vertical"), checked: prefs.vertical) { [weak self] in self?.change { $0.vertical = true } },
        ]))
        menu.addItem(submenu(L("Colors"), Palette.all.map { palette in
            ActionItem(L(palette.title), checked: prefs.paletteID == palette.id) { [weak self] in
                self?.change { $0.paletteID = palette.id }
            }
        }))
        menu.addItem(ActionItem(L("Show what it's doing"), checked: prefs.showDetail) { [weak self] in
            self?.change { $0.showDetail.toggle() }
        })
        menu.addItem(.separator())

        menu.addItem(submenu(L("Screen edge glow"), Prefs.edgeModes.enumerated().map { index, title in
            ActionItem(L(title), checked: prefs.edgeMode == index) { [weak self] in self?.change { $0.edgeMode = index } }
        }))
        menu.addItem(submenu(L("Move board to"), NSScreen.screens.enumerated().map { index, screen in
            ActionItem(index == 0 ? L("%@ (main)", screen.localizedName) : screen.localizedName) { [weak self] in
                self?.move(to: screen)
            }
        }))
        menu.addItem(ActionItem(L("Hide board when there are no sessions"), checked: prefs.hideWhenEmpty) { [weak self] in
            self?.change { $0.hideWhenEmpty.toggle() }
        })
        menu.addItem(.separator())

        menu.addItem(ActionItem(L("Demo the three states (12 s)")) { [weak self] in self?.runDemo() })
        menu.addItem(submenu(L("Language"), [ActionItem(L("Follow system"), checked: prefs.language == nil) { [weak self] in
            self?.setLanguage(nil)
        }] + Lang.choices.map { choice in
            ActionItem(choice.name, checked: prefs.language == choice.code) { [weak self] in self?.setLanguage(choice.code) }
        }))
        if connection == .connected {
            menu.addItem(ActionItem(L("Connected to Claude Code"), checked: true, enabled: false))
            menu.addItem(ActionItem(L("Disconnect from Claude Code")) { [weak self] in self?.disconnectNow() })
        }
        menu.addItem(ActionItem(L("Launch at login"), checked: SMAppService.mainApp.status == .enabled) { [weak self] in
            self?.toggleLogin()
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem(L("Quit Watchlamp")) { NSApp.terminate(nil) })
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    private func dot(_ state: LightState) -> NSImage {
        let palette = prefs.palette
        let color = palette.lit(state) ? palette.color(state) : NSColor.tertiaryLabelColor
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }
}
