import AppKit
import ServiceManagement

/// `Watchlamp login on|off|status` (used by uninstall.sh) and `Watchlamp demo [seconds]` (the menu's demo).
/// Developer commands live behind -D DEVTOOLS so they are not shipped; build them with scripts/devtools.sh.
enum Tools {
    static func login(_ command: String) {
        let service = SMAppService.mainApp
        do {
            switch command {
            case "on": try service.register()
            case "off": try service.unregister()
            default: break
            }
        } catch {
            print(L("Couldn't change the login item: %@", error.localizedDescription))
        }
        print(L(service.status == .enabled ? "Launch at login: on" : "Launch at login: off"))
    }
}

extension Tools {
    /// Three sample sessions, one per state.
    static func sampleRecords(now: Double, pid: Int32?) -> [SessionRecord] {
        func make(_ id: String, _ project: String, _ setup: (inout SessionRecord) -> Void) -> SessionRecord {
            var r = SessionRecord(sessionId: id, now: now - 3600)
            r.project = project
            r.cwd = "/sample/" + project
            r.pid = pid
            setup(&r)
            r.updated = now
            r.recompute(now)
            return r
        }
        return [
            make("sample-1", L("Website frontend")) {
                $0.beginTurn(now - 222)
                $0.activity = Hook.describe("Bash", ["description": L("Run the unit tests and report coverage")])
            },
            make("sample-2", L("Data analysis")) {
                $0.beginTurn(now - 95)
                $0.addPending("perm:Bash", agent: "main",
                              detail: "@perm:" + Hook.describe("Bash", ["description": L("Install dependencies")]), now: now - 37)
            },
            make("sample-3", L("Project docs")) {
                $0.lastTurnSeconds = 312
                $0.finishedAt = now - 420
            },
        ]
    }

    /// Writes the sample sessions for a while; owned by this process, so the app drops them if it dies.
    static func demo(seconds: Double) {
        let records = sampleRecords(now: Date().timeIntervalSince1970, pid: getpid())
        Store.locked { records.forEach(Store.save) }
        Thread.sleep(forTimeInterval: seconds)
        Store.locked { records.forEach { Store.remove($0.sessionId) } }
    }

}

#if DEVTOOLS
extension Tools {
    static func printStatus() {
        let now = Date().timeIntervalSince1970
        let records = Store.loadAll().sorted { $0.started < $1.started }
        if records.isEmpty { print("暂无会话（\(Paths.sessions.path)）") }
        for r in records {
            let alive = r.pid.map { Proc.alive($0) ? "pid \($0)" : "pid \($0) 已退出" } ?? "无 pid"
            print("[\(r.state.rawValue)] \(r.project)  \(Format.status(r, now: now))  \(Format.detail(r, now: now))")
            print("    \(r.cwd) · \(alive) · \(r.hostBundle ?? "?") · 最后事件 \(r.lastEvent) \(Format.ago(now - r.updated))")
            if !r.pending.isEmpty { print("    等待中: " + r.pending.map { "\($0.key)(\($0.agent))" }.joined(separator: ", ")) }
        }
    }

    /// Renders the board offscreen to a PNG, for checking layouts without screen recording.
    @MainActor
    static func snapshot(to path: String, vertical: Bool, size: Double, paletteID: String) {
        _ = NSApplication.shared
        let now = Date().timeIntervalSince1970
        let look = Look(size: size, vertical: vertical, showDetail: true,
                        palette: Palette.all.first { $0.id == paletteID } ?? Palette.all[0], rtl: Lang.rtl)
        let only = ProcessInfo.processInfo.environment["SAMPLES"].map { Set($0.compactMap { $0.wholeNumberValue }) }
        let samples = sampleRecords(now: now, pid: nil).enumerated().filter { only?.contains($0.offset + 1) ?? true }.map(\.element)
        let items = samples.map { r in
            LampItem(id: r.sessionId, label: r.project, state: r.state,
                     status: Format.status(r, now: now, yourTurn: look.palette.idleLit),
                     detail: Format.detail(r, now: now), tooltip: "", record: r, glyph: Format.glyph(r))
        }
        let board = BoardView(frame: .zero)
        board.update(items, look: look, scale: 2)
        let box = board.preferredSize
        board.frame = NSRect(origin: .zero, size: box)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width * scale),
                                         pixelsHigh: Int(box.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
        if ProcessInfo.processInfo.environment["SNAPSHOT_CLEAR"] == nil {   // a transparent PNG for web pages
            context.setFillColor(NSColor(white: 0.3, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
        }
        context.scaleBy(x: scale, y: scale)
        board.layer?.render(in: context)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("\(path) \(Int(box.width))x\(Int(box.height))")
    }
}
#endif
