import Foundation

/// `Watchlamp hook`: Claude Code pipes one hook event (JSON) to stdin.
/// Prints nothing and always exits 0, so it can never block or alter Claude Code.
enum Hook {
    static func run() -> Int32 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            handle(event, now: Date().timeIntervalSince1970)
        }
        return 0
    }

    static func handle(_ obj: [String: Any], now: Double) {
        guard let sid = obj["session_id"] as? String, !sid.isEmpty else { return }
        let event = obj["hook_event_name"] as? String ?? ""
        if event == "SessionEnd" {
            Store.locked { Store.remove(sid) }
            return
        }
        Store.locked {
            var r = Store.load(sid) ?? SessionRecord(sessionId: sid, now: now)
            identify(&r, obj)
            // Hooks can finish out of order; an event older than the last one applied only refreshes identity.
            if now >= r.updated {
                apply(&r, event: event, obj: obj, now: now)
                r.updated = now
                r.lastEvent = event
            }
            r.recompute(now)
            Store.save(r)
        }
    }

    static func identify(_ r: inout SessionRecord, _ obj: [String: Any]) {
        let isSubagent = !(obj["agent_id"] as? String ?? "").isEmpty
        if !isSubagent, let t = obj["transcript_path"] as? String, !t.isEmpty { r.transcript = t }
        let cwd = obj["cwd"] as? String ?? ""
        if let root = projectRoot(cwd: cwd, transcript: r.transcript) {
            r.project = projectName(root)
            r.cwd = root
        } else if r.project.isEmpty && !cwd.isEmpty {
            r.project = projectName(cwd)
            r.cwd = cwd
        }
        if let t = obj["session_title"] as? String, !t.isEmpty { r.title = t }
        if let pid = Proc.claudePID() { r.pid = pid }
        if r.hostBundle == nil { r.hostBundle = Proc.hostBundleID() }
    }

    static func apply(_ r: inout SessionRecord, event: String, obj: [String: Any], now: Double) {
        let agentID = obj["agent_id"] as? String ?? ""
        let agent = agentID.isEmpty ? "main" : agentID
        let tool = obj["tool_name"] as? String ?? ""
        let input = obj["tool_input"] as? [String: Any]
        let toolUseID = obj["tool_use_id"] as? String ?? ""

        func markActive() {
            if agent == "main" {
                r.beginTurn(now)
            } else if !r.activeAgents.contains(agent) {
                r.activeAgents.append(agent)
            }
        }
        // Activity from an agent means its earlier permission prompt has been answered.
        func clearPermissionWaits() {
            r.pending.removeAll { ($0.key.hasPrefix("perm:") && $0.agent == agent) || $0.agent == "?" }
        }

        switch event {
        case "SessionStart":
            if obj["source"] as? String != "compact" {
                r.mainActive = false
                r.activeAgents = []
                r.backgroundAgents = 0
                r.pending = []
                r.turnStarted = nil
                r.endNote = nil
                r.activity = ""
            }
        case "UserPromptSubmit":
            r.pending.removeAll()
            r.turnStarted = now
            r.beginTurn(now)
            r.activity = "@thinking"
        case "PreToolUse":
            clearPermissionWaits()
            markActive()
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" {
                let what = tool == "AskUserQuestion" ? "@ask" : "@plan"
                r.addPending("ask:" + (toolUseID.isEmpty ? tool : toolUseID), agent: agent, detail: what, now: now)
            } else {
                r.activity = describe(tool, input)
            }
        case "PermissionRequest":
            markActive()
            r.addPending("perm:" + tool, agent: agent, detail: "@perm:" + describe(tool, input), now: now)
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            r.pending.removeAll { $0.key == "ask:" + toolUseID || $0.key == "ask:" + tool }
            clearPermissionWaits()
            if event == "PostToolUseFailure" && obj["is_interrupt"] as? Bool == true {
                r.endTurn(now, note: "@interrupted")
            } else {
                markActive()
                if agent == "main" { r.activity = "@thinking" }
            }
        case "Notification":
            let type = obj["notification_type"] as? String ?? ""
            let message = obj["message"] as? String ?? ""
            if type == "permission_prompt" || (type.isEmpty && message.contains("permission")) {
                // Sent 6s after a prompt appears and cancelled if answered sooner; a fallback for PermissionRequest.
                let what = toolFromMessage(message)
                r.addPending("perm:" + what, agent: "?", detail: "@perm:" + what, now: now)
            } else if type == "idle_prompt" && r.pending.isEmpty && r.mainActive {
                r.endTurn(now, note: nil)
            }
        case "Elicitation":
            let id = obj["elicitation_id"] as? String ?? ""
            let server = obj["mcp_server_name"] as? String ?? "MCP"
            r.addPending("elic:" + id, agent: agent, detail: "@input:" + server, now: now)
        case "ElicitationResult":
            let id = obj["elicitation_id"] as? String ?? ""
            r.pending.removeAll { $0.key == "elic:" + id }
        case "PreCompact":
            markActive()
            r.activity = "@compacting"
        case "SubagentStart":
            if agent != "main" && !r.activeAgents.contains(agent) { r.activeAgents.append(agent) }
        case "SubagentStop":
            r.activeAgents.removeAll { $0 == agent }
            r.pending.removeAll { $0.agent == agent }
            if r.backgroundAgents > 0 { r.backgroundAgents -= 1 }
        case "Stop":
            r.endTurn(now, note: nil)
            r.backgroundAgents = runningBackgroundAgents(obj)
        case "StopFailure":
            r.endTurn(now, note: "@failed")
            let error = clip(errorText(obj["error"]), 40)
            r.addPending("error", agent: "main", detail: error.isEmpty ? "@error" : "@error:" + error, now: now)
        default:
            break
        }
    }

    /// Background agents and workflows still running when the main agent stops keep the lamp on.
    /// Background shells (dev servers, monitors) do not: they can run forever.
    static func runningBackgroundAgents(_ obj: [String: Any]) -> Int {
        guard let tasks = obj["background_tasks"] as? [[String: Any]] else { return 0 }
        return tasks.filter { task in
            let type = (task["type"] as? String ?? "").lowercased()
            let status = (task["status"] as? String ?? "running").lowercased()
            let agentLike = type.contains("agent") || type.contains("workflow") || type.contains("teammate")
            return agentLike && (status == "running" || status == "pending")
        }.count
    }

    static func errorText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let d = value as? [String: Any] { return (d["message"] as? String) ?? (d["type"] as? String) ?? "" }
        return ""
    }

    static func toolFromMessage(_ message: String) -> String {
        guard let range = message.range(of: "permission to use ") else { return "?" }
        let rest = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? "?" : rest
    }

    /// The directory the session was started in. `cwd` follows Claude's `cd`s, but the transcript lives in
    /// ~/.claude/projects/<start dir with every non-alphanumeric character turned into "-">/, so the
    /// ancestor of `cwd` that encodes to that folder name is the project.
    static func projectRoot(cwd: String, transcript: String?) -> String? {
        guard let transcript, !cwd.isEmpty else { return nil }
        let folder = ((transcript as NSString).deletingLastPathComponent as NSString).lastPathComponent
        func encode(_ path: String) -> String {
            String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        }
        var path = cwd
        while path.count > 1 {
            if encode(path) == folder { return path }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func projectName(_ cwd: String) -> String {
        if cwd == NSHomeDirectory() { return "~" }
        // Claude Code worktrees live in <repo>/.claude/worktrees/<name>.
        if let range = cwd.range(of: "/.claude/worktrees/") {
            let repo = (String(cwd[..<range.lowerBound]) as NSString).lastPathComponent
            let tree = cwd[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            return tree.isEmpty ? repo : "\(repo) · \(tree)"
        }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    static func describe(_ tool: String, _ input: [String: Any]?) -> String {
        func field(_ key: String) -> String {
            (input?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func file(_ key: String) -> String { (field(key) as NSString).lastPathComponent }
        func join(_ verb: String, _ object: String) -> String { object.isEmpty ? "@" + verb : "@\(verb):\(clip(object))" }

        switch tool {
        case "Bash", "PowerShell": return join("cmd", field("description").isEmpty ? field("command") : field("description"))
        case "Read": return join("read", file("file_path"))
        case "Edit", "MultiEdit": return join("edit", file("file_path"))
        case "Write": return join("write", file("file_path"))
        case "NotebookEdit": return join("edit", file("notebook_path"))
        case "Grep": return join("search", field("pattern"))
        case "Glob": return join("find", field("pattern"))
        case "WebFetch": return join("fetch", URL(string: field("url"))?.host ?? "")
        case "WebSearch": return join("web", field("query"))
        case "Task", "Agent": return join("task", field("description"))
        case "TodoWrite": return "@todo"
        case "Skill": return join("skill", field("skill"))
        case "": return "@thinking"
        default:
            if tool.hasPrefix("mcp__") { return join("tool", tool.components(separatedBy: "__").last ?? tool) }
            return tool
        }
    }

    static func clip(_ text: String, _ limit: Int = 44) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
