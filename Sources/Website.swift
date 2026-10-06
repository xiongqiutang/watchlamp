import AppKit

/// Watchlamp on thermport.com.
enum Website {
    /// "Leave a Tip…" opens the Lemon Squeezy checkout through a redirect on thermport.com (site/_redirects),
    /// so the checkout can change without an app update.
    static func tip() {
        NSWorkspace.shared.open(URL(string: "https://thermport.com/watchlamp/tip")!)
    }
}

/// "Check for Updates…" reads thermport.com/watchlamp/version.json, shaped {"version": "1.1", "url": "…"}.
/// Only when asked. Nothing installs by itself; a newer version opens its download.
@MainActor
enum Updates {
    static let feed = URL(string: "https://thermport.com/watchlamp/version.json")!
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func check() {
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let version = json?["version"] as? String
            let url = (json?["url"] as? String).flatMap(URL.init(string:))
            Task { @MainActor in show(version: version, url: url) }
        }.resume()
    }

    private static func show(version: String?, url: URL?) {
        let alert = NSAlert()
        if let version, let url, isNewer(version, than: current) {
            alert.messageText = L("Watchlamp %@ is available", version)
            alert.informativeText = L("You have %@. To update, download it, quit Watchlamp, and drag the new copy into Applications.", current)
            alert.addButton(withTitle: L("Download"))
            alert.addButton(withTitle: L("Not now"))
            activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        } else {
            alert.messageText = version == nil ? L("Couldn't check for updates") : L("Watchlamp is up to date")
            alert.informativeText = version == nil ? L("Check your internet connection and try again.")
                : L("You have the latest version, %@.", current)
            activate()
            alert.runModal()
        }
    }

    /// Dotted numbers, so "1.10" is newer than "1.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    private static func activate() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
}
