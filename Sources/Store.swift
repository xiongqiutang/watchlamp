import Foundation
import Darwin

enum Paths {
    static let root: URL = {
        if let dir = ProcessInfo.processInfo.environment["WATCHLAMP_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/watchlamp", isDirectory: true)
    }()
    static var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    static var lock: URL { root.appendingPathComponent(".lock") }
}

/// One JSON file per session. Hook processes and the app take a shared flock around
/// every read-modify-write so concurrent events never clobber each other.
enum Store {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static func ensureDirs() {
        try? FileManager.default.createDirectory(at: Paths.sessions, withIntermediateDirectories: true)
    }

    static func locked<T>(_ body: () throws -> T) rethrows -> T {
        ensureDirs()
        let fd = open(Paths.lock.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 {
            // Never stall Claude Code: give up on the lock after ~2s and write anyway.
            var tries = 0
            while flock(fd, LOCK_EX | LOCK_NB) != 0 && tries < 400 {
                usleep(5_000)
                tries += 1
            }
        }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }

    static func fileURL(_ id: String) -> URL {
        let safe = String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return Paths.sessions.appendingPathComponent(safe + ".json")
    }

    static func load(_ id: String) -> SessionRecord? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    static func save(_ record: SessionRecord) {
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: fileURL(record.sessionId), options: .atomic)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    static func loadAll() -> [SessionRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(SessionRecord.self, from: data)
        }
    }
}

enum Proc {
    static func alive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func parent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return (String(cString: buf) as NSString).lastPathComponent
    }

    /// The Claude Code process that ran this hook: it lives exactly as long as the session.
    static func claudePID() -> Int32? {
        if let s = ProcessInfo.processInfo.environment["CLAUDE_PID"], let pid = Int32(s), pid > 1 {
            return pid
        }
        let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "nice", "nohup"]
        var pid = getppid()
        var hops = 0
        while pid > 1 && hops < 8 {
            if !wrappers.contains(name(pid)) { return pid }
            guard let next = parent(pid) else { break }
            pid = next
            hops += 1
        }
        return nil
    }

    /// The app hosting the session (Terminal, iTerm2, VS Code, Claude desktop...).
    static func hostBundleID() -> String? {
        guard let id = ProcessInfo.processInfo.environment["__CFBundleIdentifier"], !id.isEmpty,
              id != Bundle.main.bundleIdentifier else { return nil }
        return id
    }
}

enum Transcript {
    static func stat(_ path: String) -> (size: UInt64, modified: Double)? {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0 else { return nil }
        let m = info.st_mtimespec
        return (UInt64(info.st_size), Double(m.tv_sec) + Double(m.tv_nsec) / 1e9)
    }

    /// True when the newest conversation line is Claude Code's "[Request interrupted by user...]" marker.
    /// Interrupts (Esc, the stop button, a denied permission) end a turn without a Stop hook.
    static func endsWithInterrupt(_ path: String, after time: Double) -> Bool {
        guard let file = stat(path), file.modified > time,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let chunk: UInt64 = 32 * 1024
        try? handle.seek(toOffset: file.size > chunk ? file.size - chunk : 0)
        guard let data = try? handle.readToEnd() else { return false }
        func has(_ line: Data, _ text: String) -> Bool { line.range(of: Data(text.utf8)) != nil }
        // Walk lines backwards without decoding the whole chunk.
        var end = data.endIndex
        var seen = 0
        while end > data.startIndex && seen < 40 {
            let start = data[data.startIndex..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let line = data[start..<end]
            end = start > data.startIndex ? start - 1 : data.startIndex
            guard !line.isEmpty else { continue }
            seen += 1
            let isUser = has(line, "\"type\":\"user\"")
            if !isUser && !has(line, "\"type\":\"assistant\"") { continue }
            if has(line, "\"isSidechain\":true") || has(line, "\"isMeta\":true") { continue }
            return isUser && (has(line, "\"text\":\"[Request interrupted by user")
                || has(line, "\"content\":\"[Request interrupted by user"))
        }
        return false
    }
}

/// The app's view of the sessions folder: re-decodes a file only when it changed.
final class SessionCache {
    private var entries: [String: (modified: Double, record: SessionRecord)] = [:]

    func loadAll() -> [SessionRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.sessions.path)) ?? []
        var fresh: [String: (modified: Double, record: SessionRecord)] = [:]
        for name in names where name.hasSuffix(".json") {
            let path = Paths.sessions.appendingPathComponent(name).path
            guard let modified = Transcript.stat(path)?.modified else { continue }
            if let hit = entries[name], hit.modified == modified {
                fresh[name] = hit
            } else if let data = FileManager.default.contents(atPath: path),
                      let record = try? Store.decoder.decode(SessionRecord.self, from: data) {
                fresh[name] = (modified, record)
            }
        }
        entries = fresh
        return fresh.values.map(\.record)
    }
}
