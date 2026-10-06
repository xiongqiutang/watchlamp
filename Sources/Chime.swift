import AppKit

/// Rings when a session starts waiting for you, and when one is done.
/// Only for changes that happen while the app runs; a prompt answered within two seconds stays quiet,
/// and an interrupted turn is no news to the person who interrupted it.
@MainActor
final class Chime {
    private let launched: Double
    private var firstSeen: [String: Double] = [:]
    private var rungWait: [String: Double] = [:]   // session → start of the wait already announced
    private var rungDone: [String: Double] = [:]   // session → end of the turn already announced
    private var lastRung = 0.0
    var ring: (String) -> Void = { Chime.play($0, volume: Prefs.shared.soundVolume) }

    init(launched: Double = Date().timeIntervalSince1970) {
        self.launched = launched
    }

    /// Where macOS keeps alert sounds, the user's own first.
    private static let folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
                                  URL(fileURLWithPath: "/Library/Sounds"), URL(fileURLWithPath: "/System/Library/Sounds")]
    private static let kinds: Set<String> = ["aiff", "aif", "wav", "caf", "m4a", "mp3"]
    private static var player: Process?

    private static var files: [URL] {
        folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { kinds.contains($0.pathExtension.lowercased()) }
    }

    static var available: [String] {
        Set(files.map { $0.deletingPathExtension().lastPathComponent })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Plays in a process of its own (see Player): the audio machinery never loads into this one.
    static func play(_ name: String, volume: Double) {
        guard let file = files.first(where: { $0.deletingPathExtension().lastPathComponent == name }),
              let me = Bundle.main.executableURL else { return }
        if player?.isRunning == true { player?.terminate() }
        let process = Process()
        process.executableURL = me
        process.arguments = ["play-sound", file.path, String(volume)]
        try? process.run()
        player = process
    }

    func update(_ sessions: [SessionRecord], now: Double, prefs: Prefs) {
        var waits: [(String, Double)] = [], dones: [(String, Double)] = []
        for r in sessions {
            let seen = firstSeen[r.sessionId] ?? now
            firstSeen[r.sessionId] = seen
            if r.state == .waiting, r.stateSince >= launched, now - r.stateSince >= 2, rungWait[r.sessionId] != r.stateSince {
                waits.append((r.sessionId, r.stateSince))
            }
            if r.state == .idle, r.endNote == nil, let end = r.finishedAt, end >= max(launched, seen),
               rungDone[r.sessionId] != end {
                dones.append((r.sessionId, end))
            }
        }
        let ids = Set(sessions.map(\.sessionId))
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        rungWait = rungWait.filter { ids.contains($0.key) }
        rungDone = rungDone.filter { ids.contains($0.key) }

        // One sound at a time, the wait first; news that arrives together shares it.
        let sound = !waits.isEmpty && prefs.soundMode >= 1 ? prefs.waitingSound
            : !dones.isEmpty && prefs.soundMode >= 2 ? prefs.doneSound : nil
        if sound != nil && now - lastRung < 1 { return }   // right after another sound: try again next time
        if let sound {
            ring(sound)
            lastRung = now
        }
        for (id, start) in waits { rungWait[id] = start }
        for (id, end) in dones { rungDone[id] = end }
    }
}
