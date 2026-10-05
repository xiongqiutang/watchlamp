import Foundation
import JavaScriptCore

/// Adds or removes Watchlamp's hooks in Claude Code's ~/.claude/settings.json.
/// The edit itself runs in JavaScriptCore: JSON.parse/stringify keep the file's key order and two-space style,
/// the way Claude Code writes it, where JSONSerialization would reorder the user's settings.
enum Connection {
    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied",
        "Notification", "Elicitation", "ElicitationResult", "PreCompact",
        "SubagentStart", "SubagentStop", "Stop", "StopFailure",
    ]
    static let toolEvents = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"]
    /// Hooks whose command mentions one of these belong to us (ClaudeStatusLight was the name before).
    static let markers = ["Watchlamp", "ClaudeStatusLight"]

    enum State { case connected, elsewhere, disconnected, noClaude }

    enum Failure: Error {
        case noClaude, invalidSettings, write(String)

        var message: String {
            switch self {
            case .noClaude:
                return L("Claude Code isn't installed yet (there is no ~/.claude folder). Install it, then choose “Connect to Claude Code” from this menu.")
            case .invalidSettings: return L("Claude Code's settings file isn't valid JSON, so it was left unchanged.")
            case .write(let reason): return reason
            }
        }
    }

    static var claudeDir: URL {
        if let dir = ProcessInfo.processInfo.environment["WATCHLAMP_CLAUDE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    /// The hook command for this copy of the app.
    static var command: String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' hook 2>/dev/null || true"
    }

    /// `.elsewhere`: hooked up, but to another copy of the app (it was moved).
    static func state() -> State {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return .noClaude }
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return .disconnected }
        var ours = 0, others = 0
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                for case let hook as [String: Any] in group["hooks"] as? [Any] ?? [] {
                    guard let command = hook["command"] as? String, markers.contains(where: command.contains) else { continue }
                    if command == self.command { ours += 1 } else { others += 1 }
                }
            }
        }
        if ours == events.count && others == 0 { return .connected }
        return ours + others > 0 ? .elsewhere : .disconnected
    }

    static func connect() throws { try edit(install: true) }
    static func disconnect() throws { try edit(install: false) }

    private static func edit(install: Bool) throws {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { throw Failure.noClaude }
        let original = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""
        guard let updated = rewrite(original, install: install) else { throw Failure.invalidSettings }
        guard updated != original else { return }
        if !original.isEmpty {
            let backups = Paths.root.appendingPathComponent("backups", isDirectory: true)
            try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            try? original.write(to: backups.appendingPathComponent("settings.json.\(stamp.string(from: Date()))"),
                                atomically: true, encoding: .utf8)
        }
        do {
            try updated.write(to: settingsURL, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
    }

    /// Returns the new file text, or nil if the current text isn't a JSON object.
    static func rewrite(_ text: String, install: Bool) -> String? {
        guard let context = JSContext() else { return nil }
        context.evaluateScript(script)
        let result = context.objectForKeyedSubscript("rewrite")?
            .call(withArguments: [text, command, markers, events, toolEvents, install])
        guard context.exception == nil, let result, result.isString else { return nil }
        return result.toString()
    }

    private static let script = """
    function rewrite(text, command, markers, events, toolEvents, install) {
      const settings = text.trim() ? JSON.parse(text) : {};
      if (settings === null || typeof settings !== 'object' || Array.isArray(settings)) throw new Error('not an object');
      const hooks = settings.hooks && typeof settings.hooks === 'object' && !Array.isArray(settings.hooks) ? settings.hooks : {};
      const ours = (hook) => hook && markers.some((m) => String(hook.command || '').includes(m));
      for (const event of Object.keys(hooks)) {
        if (!Array.isArray(hooks[event])) continue;
        for (const group of hooks[event]) {
          if (group && Array.isArray(group.hooks)) group.hooks = group.hooks.filter((hook) => !ours(hook));
        }
        hooks[event] = hooks[event].filter((group) => !(group && Array.isArray(group.hooks) && group.hooks.length === 0));
        if (hooks[event].length === 0) delete hooks[event];
      }
      if (install) {
        for (const event of events) {
          const hook = { type: 'command', command: command, timeout: 5 };
          const group = toolEvents.includes(event) ? { matcher: '*', hooks: [hook] } : { hooks: [hook] };
          hooks[event] = (hooks[event] || []).concat([group]);
        }
      }
      if (Object.keys(hooks).length) settings.hooks = hooks; else delete settings.hooks;
      return JSON.stringify(settings, null, 2) + '\\n';
    }
    """
}
