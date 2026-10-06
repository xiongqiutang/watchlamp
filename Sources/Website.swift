import AppKit
import UserNotifications

/// Watchlamp on thermport.com.
enum Website {
    /// "Leave a Tip…" opens the Lemon Squeezy checkout through a redirect on thermport.com (site/_redirects),
    /// so the checkout can change without an app update.
    static func tip() {
        NSWorkspace.shared.open(URL(string: "https://thermport.com/watchlamp/tip")!)
    }
}

/// Updates come from thermport.com/watchlamp/version.json, shaped {"version": "1.2", "url": "…"}: at launch and then
/// once a day (a newer version posts one notification), and from "Check for Updates…" (always answers).
/// Nothing installs by itself; a newer version opens its download.
@MainActor
enum Updates {
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    struct Release { let version: String; let url: URL }

    /// `Watchlamp fetch-update`: reads the feed and prints the version and the download link, one per line (exit 0),
    /// or exits 1. The app runs it as a short-lived process of its own, like the sounds, so the networking machinery
    /// never loads into the app itself. Its request carries the standard user agent (Watchlamp/<build> CFNetwork/…
    /// Darwin/…), from which the developer page counts Macs and versions.
    nonisolated static func fetchAndPrint() -> Int32 {
        let feed = URL(string: ProcessInfo.processInfo.environment["WATCHLAMP_FEED"] ?? "https://thermport.com/watchlamp/version.json")!
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var line: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            if let version = json?["version"] as? String, let url = json?["url"] as? String, URL(string: url) != nil,
               !version.contains("\n"), !url.contains("\n") {
                line = version + "\n" + url + "\n"
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 30) == .success, let line else { return 1 }
        FileHandle.standardOutput.write(Data(line.utf8))
        return 0
    }

    /// Runs `fetch-update` and hands back what it found (nil: no answer).
    static func fetch(_ done: @escaping @MainActor (Release?) -> Void) {
        guard let me = Bundle.main.executableURL else { return done(nil) }
        let process = Process(), pipe = Pipe()
        process.executableURL = me
        process.arguments = ["fetch-update"]
        process.standardOutput = pipe
        process.terminationHandler = { finished in
            let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
            let release = finished.terminationStatus == 0 && lines.count == 2
                ? URL(string: String(lines[1])).map { Release(version: String(lines[0]), url: $0) } : nil
            Task { @MainActor in done(release) }
        }
        do { try process.run() } catch { done(nil) }
    }

    /// "Check for Updates…".
    static func check() { fetch { show($0) } }

    /// Called at launch and then every hour; it goes online once a day. A failed check (offline at login, say) tries
    /// again the next hour. One notification per new version; clicking it opens the download.
    static func checkDaily() {
        let defaults = UserDefaults.standard
        guard Date().timeIntervalSince1970 - defaults.double(forKey: "updateLastCheck") >= 86_400 else { return }
        fetch { release in
            guard let release else { return }
            defaults.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
            guard isNewer(release.version, than: current), defaults.string(forKey: "updateNotifiedVersion") != release.version else { return }
            defaults.set(release.version, forKey: "updateNotifiedVersion")
            Notifier.post(title: L("Watchlamp %@ is available", release.version),
                          body: L("You have %@. To update, download it, quit Watchlamp, and drag the new copy into Applications.", current),
                          id: "update-" + release.version, url: release.url)
        }
    }

    /// At launch: when an update notice from an earlier run may still be waiting in Notification Center, listen for
    /// its click. Otherwise the notification machinery stays unloaded.
    static func listenIfNoticePending() {
        if let notified = UserDefaults.standard.string(forKey: "updateNotifiedVersion"), isNewer(notified, than: current) {
            Notifier.listen()
        }
    }

    private static func show(_ release: Release?) {
        let alert = NSAlert()
        if let release, isNewer(release.version, than: current) {
            alert.messageText = L("Watchlamp %@ is available", release.version)
            alert.informativeText = L("You have %@. To update, download it, quit Watchlamp, and drag the new copy into Applications.", current)
            alert.addButton(withTitle: L("Download"))
            alert.addButton(withTitle: L("Not now"))
            activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
        } else {
            alert.messageText = release == nil ? L("Couldn't check for updates") : L("Watchlamp is up to date")
            alert.informativeText = release == nil ? L("Check your internet connection and try again.")
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

/// The update notice in Notification Center. Permission is asked the first time there is a new version to announce,
/// never at launch; if it is refused, the daily check stays quiet ("Check for Updates…" still answers).
@MainActor
enum Notifier {
    private static let presenter = Presenter()

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        /// Shown even while a Watchlamp window (the menu, a form) is in front.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list, .sound])
        }

        /// A click opens the download.
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            completionHandler()
        }
    }

    static func listen() { UNUserNotificationCenter.current().delegate = presenter }

    static func post(title: String, body: String, id: String, url: URL) {
        listen()
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url.absoluteString]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .denied: return
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { center.add(request) } }
            default: center.add(request)
            }
        }
    }
}
