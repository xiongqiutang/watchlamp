import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
func argument(_ index: Int, _ fallback: String) -> String { arguments.count > index ? arguments[index] : fallback }

switch arguments.first {
case "hook":
    exit(Hook.run())
case "connect", "disconnect":
    // Used by install.sh / uninstall.sh; the app does the same from its menu.
    Lang.use(UserDefaults.standard.string(forKey: "language"))
    do {
        if arguments.first == "connect" { try Connection.connect() } else { try Connection.disconnect() }
        print(L(arguments.first == "connect" ? "Connected to Claude Code" : "Disconnected from Claude Code"))
    } catch {
        print((error as? Connection.Failure)?.message ?? error.localizedDescription)
        exit(1)
    }
case "connection":
    print(Connection.state())
case "login":
    Lang.use(UserDefaults.standard.string(forKey: "language"))
    Tools.login(argument(1, "status"))
case "demo":
    Lang.use(UserDefaults.standard.string(forKey: "language"))
    Tools.demo(seconds: Double(argument(1, "12")) ?? 12)
#if DEVTOOLS
case "status":
    Tools.printStatus()
case "snapshot":
    if arguments.count > 5 { Lang.use(lprojAt: "Resources/\(arguments[5]).lproj") }
    MainActor.assumeIsolated {
        Tools.snapshot(to: argument(1, "snapshot.png"), vertical: argument(2, "h") == "v",
                       size: Double(argument(3, "110")) ?? 110, paletteID: argument(4, "classic"),
                       textScale: Double(argument(6, "1")) ?? 1)
    }
#endif
default:
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
