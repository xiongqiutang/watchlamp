import Foundation

/// What a lamp shows.
enum LightState: String, Codable {
    case working   // Claude is busy
    case waiting   // Claude needs you: a permission prompt, a question, or it stopped on an error
    case idle      // the turn is over, nothing is running
}

/// Something blocked on the user. `agent` is "main", a subagent id, or "?" when the event did not say.
struct Pending: Codable, Equatable {
    var key: String
    var agent: String
    var detail: String
    var since: Double
}

/// One Claude Code session, persisted as ~/.claude/watchlamp/sessions/<session_id>.json.
/// Written by the hook process, read (and occasionally corrected) by the app.
struct SessionRecord: Codable {
    var sessionId: String
    var project = ""
    var cwd = ""
    var title: String?
    var hostBundle: String?
    var pid: Int32?
    var transcript: String?
    var started: Double = 0
    var updated: Double = 0
    var lastEvent = ""

    var mainActive = false
    var activeAgents: [String] = []
    var backgroundAgents = 0
    /// What else was still running in the background when the main agent last stopped, and will wake it when it ends:
    /// a test run, a build, a script (see Hook.background). Dev servers and watchers are never listed.
    var backgroundJobs: [String] = []
    var pending: [Pending] = []
    var activity = ""
    var turnStarted: Double?
    var lastTurnSeconds: Double?
    var finishedAt: Double?
    var endNote: String?

    // Derived by recompute(_:), stored so the app does not need the rules.
    var state: LightState = .idle
    var detail = ""
    var stateSince: Double = 0

    init(sessionId: String, now: Double) {
        self.sessionId = sessionId
        started = now
        stateSince = now
    }

    // Tolerates files written by older or newer builds: every field but the id is optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        hostBundle = try c.decodeIfPresent(String.self, forKey: .hostBundle)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        started = try c.decodeIfPresent(Double.self, forKey: .started) ?? 0
        updated = try c.decodeIfPresent(Double.self, forKey: .updated) ?? 0
        lastEvent = try c.decodeIfPresent(String.self, forKey: .lastEvent) ?? ""
        mainActive = try c.decodeIfPresent(Bool.self, forKey: .mainActive) ?? false
        activeAgents = try c.decodeIfPresent([String].self, forKey: .activeAgents) ?? []
        backgroundAgents = try c.decodeIfPresent(Int.self, forKey: .backgroundAgents) ?? 0
        backgroundJobs = try c.decodeIfPresent([String].self, forKey: .backgroundJobs) ?? []
        pending = try c.decodeIfPresent([Pending].self, forKey: .pending) ?? []
        activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? ""
        turnStarted = try c.decodeIfPresent(Double.self, forKey: .turnStarted)
        lastTurnSeconds = try c.decodeIfPresent(Double.self, forKey: .lastTurnSeconds)
        finishedAt = try c.decodeIfPresent(Double.self, forKey: .finishedAt)
        endNote = try c.decodeIfPresent(String.self, forKey: .endNote)
        state = (try? c.decodeIfPresent(LightState.self, forKey: .state)) ?? .idle
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        stateSince = try c.decodeIfPresent(Double.self, forKey: .stateSince) ?? 0
    }

    /// Background work that hasn't woken the session for an hour no longer keeps the lamp on: it is most likely
    /// something that runs until stopped after all (the app drops it; see AppDelegate.maintain).
    static let backgroundJobLimit: Double = 3600

    /// True while the lamp is lit only by background work: the main agent has stopped and is waiting to be woken.
    var waitingOnBackground: Bool { state == .working && !mainActive && activeAgents.isEmpty }

    /// When Claude picks up again while the lamp is still lit by background work (woken by a finished test run, say),
    /// the turn's clock keeps counting from when the lamp lit up.
    mutating func beginTurn(_ now: Double) {
        if turnStarted == nil { turnStarted = waitingOnBackground ? stateSince : now }
        mainActive = true
        endNote = nil
    }

    /// The main agent stopped (finished, interrupted or failed). Subagent prompts stay pending.
    mutating func endTurn(_ now: Double, note: String?) {
        if let t = turnStarted { lastTurnSeconds = now - t }
        turnStarted = nil
        finishedAt = now
        mainActive = false
        activeAgents.removeAll()
        pending.removeAll { $0.agent == "main" || $0.agent == "?" }
        endNote = note
    }

    mutating func addPending(_ key: String, agent: String, detail: String, now: Double) {
        guard !pending.contains(where: { $0.key == key }) else { return }
        pending.append(Pending(key: key, agent: agent, detail: detail, since: now))
    }

    mutating func recompute(_ now: Double) {
        let next: LightState
        if let p = pending.last {
            next = .waiting
            detail = p.detail
        } else if mainActive || !activeAgents.isEmpty || backgroundAgents > 0 || !backgroundJobs.isEmpty {
            next = .working
            let background = backgroundAgents + backgroundJobs.count
            detail = mainActive || !activeAgents.isEmpty ? activity
                : background == 1 && backgroundJobs.count == 1 ? "@bg:" + backgroundJobs[0] : "@background:\(background)"
        } else {
            next = .idle
            detail = endNote ?? ""
        }
        if next != state {
            state = next
            stateSince = now
        }
    }
}
