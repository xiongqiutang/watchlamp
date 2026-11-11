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
                r.backgroundJobs = []
                r.pending = []
                r.turnStarted = nil
                r.endNote = nil
                r.activity = ""
            }
        case "UserPromptSubmit":
            r.pending.removeAll()
            r.turnStarted = r.waitingOnBackground ? r.stateSince : now   // the lamp never went out: keep its clock
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
            (r.backgroundAgents, r.backgroundJobs) = background(obj)
        case "StopFailure":
            r.endTurn(now, note: "@failed")
            let error = clip(errorText(obj["error"]), 40)
            r.addPending("error", agent: "main", detail: error.isEmpty ? "@error" : "@error:" + error, now: now)
        default:
            break
        }
    }

    /// What still runs in the background when the main agent stops (Stop's background_tasks) and keeps the lamp on:
    /// - agents: background subagents, workflows and teammates; each one's SubagentStop takes it off again.
    /// - jobs: work that ends by itself and then wakes Claude, which stops again with an updated list: a background
    ///   shell running tests, a build or a script, an MCP task, a cloud session. Described for the lamp's detail line.
    /// Shells that run until stopped (dev servers, watchers, log tails; see isService) never count, nor do monitors
    /// or Claude Code's own housekeeping (memory saves, dreams, scans). Types are friendly labels ("shell"), or the
    /// raw kinds ("local_bash") from older builds.
    static func background(_ obj: [String: Any]) -> (agents: Int, jobs: [String]) {
        guard let tasks = obj["background_tasks"] as? [[String: Any]] else { return (0, []) }
        var agents = 0, jobs: [String] = []
        for task in tasks {
            let status = (task["status"] as? String ?? "running").lowercased()
            guard status == "running" || status == "pending" else { continue }
            let command = task["command"] as? String ?? ""
            var description = (task["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if description.isEmpty { description = command }
            let type = (task["type"] as? String ?? "").lowercased()
            switch type {
            case "subagent", "local_agent", "workflow", "local_workflow", "teammate", "in_process_teammate":
                agents += 1
            case "shell", "local_bash":   // a shell with neither command nor description can't be judged: left out
                if !description.isEmpty && !isService(command: command, description: description) { jobs.append(clip(description)) }
            case "mcp task", "mcp_task", "cloud session", "remote_agent":
                jobs.append(clip(description.isEmpty ? type : description))
            default:
                break
            }
        }
        return (agents, jobs)
    }

    /// A background shell that runs until it is stopped rather than finishing: a dev or preview server, a file
    /// watcher, a log tail. Judged by its command first, then by Claude's description of it: a description that names
    /// a test run or a build wins over one that sounds like a server ("Start the full test suite").
    static func isService(command: String, description: String) -> Bool {
        func has(_ text: String, _ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if has(command, finiteCommand) { return false }
        if has(command, serviceCommand) { return true }
        if has(description, finiteWords) { return false }
        return has(description, serviceWords)
    }

    /// Waits that end on their own although they say "watch".
    private static let finiteCommand = #"\bgh\s+(run\s+watch|pr\s+checks)\b"#
    private static let serviceCommand = [
        #"\bserv(e|er)\b"#, #"runserver"#, #"http[.-]server"#,                      // python -m http.server, server.js
        #"(?<![\w/.\[-])dev(?![\w/.\]-])"#,                                         // npm run dev, wrangler dev; not /dev/null
        #"\b(npm|yarn|pnpm|bun)\s+(run\s+)?start\b"#, #"\b(expo|docusaurus|ng)\s+(start|serve)\b"#,
        #"\bpreview\b"#, #"\bvite\b(?!\s+(build|optimize))"#, #"webpack-dev-server"#,
        #"\bwatch(ing)?\b"#, #"--watch\b"#, #"\b(nodemon|watchexec|fswatch|entr)\b"#, #"--(hot|reload)\b"#,
        #"\btail\b[^|;&]*\s-\w*[fF]\b"#, #"\blog\s+stream\b"#, #"\b(journalctl|logs)\b[^|;&]*\s(-f|--follow)\b"#,
        #"\b(uvicorn|gunicorn|hypercorn|daphne|rackup|puma|live-server|browser-sync|storybook|ngrok|cloudflared)\b"#,
        #"\b(flask|streamlit)\s+run\b"#, #"\bjupyter[-\s]+(notebook|lab)\b"#, #"\bphp\s+-S\b"#, #"\brails\s+s(erver)?\b"#,
        #"\b(mongod|redis-server|ollama\s+serve|port-forward)\b"#, #"\bdocker[-\s]+compose\s+up\b(?![^|;&]*\s-d\b)"#,
        #"\bsleep\s+infinity\b"#,
    ].joined(separator: "|")
    private static let finiteWords = #"\b(tests?|testing|specs?|suite|builds?|compile|lint|check|bench(mark)?|install|deploy|migrate|notari[sz]e|release|package|archive|e2e)\b|测试|构建|编译|打包|安装|部署|公证|发布"#
    private static let serviceWords = #"\bserv(e|er|es|ing)\b|\bwatch(er|ers|es|ing)?\b|\blisten(s|er|ing)?\b|\bdaemon\b|\bpreview\b|\btail\b|^(start|launch|boot|keep)\b|\brun\s+(the\s+)?(app|application)\b|服务|预览|监听|监视|启动|常驻"#

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
