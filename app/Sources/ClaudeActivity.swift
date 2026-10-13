import Foundation
import Darwin

struct ClaudeProcessIdentity: Codable, Equatable, Hashable {
    var pid: Int32
    var startedSeconds: UInt64
    var startedMicroseconds: UInt64

    var isValid: Bool { pid > 1 && startedSeconds > 0 && startedMicroseconds < 1_000_000 }
    var key: String { "\(pid)-\(startedSeconds)-\(startedMicroseconds)" }
}

private enum ClaudeActivityError: Error { case unsafeFile, invalidEvent, unavailable }

enum ClaudeProcesses {
    struct Details {
        var identity: ClaudeProcessIdentity
        var parent: Int32
        var path: String
    }

    private static func isNativeVersionName(_ name: String) -> Bool {
        name.range(of: #"^\d+\.\d+\.\d+([-+][A-Za-z0-9.-]+)?$"#,
                   options: .regularExpression) != nil
    }

    static func isPossibleCodeName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return true }
        let normalized = name.lowercased()
        return ["claude", "claude-code", "node"].contains(normalized) || isNativeVersionName(normalized)
    }

    static func details(_ pid: Int32) -> Details? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let identity = ClaudeProcessIdentity(pid: pid, startedSeconds: info.pbi_start_tvsec,
                                             startedMicroseconds: info.pbi_start_tvusec)
        guard identity.isValid else { return nil }
        return Details(identity: identity, parent: Int32(info.pbi_ppid), path: String(cString: path))
    }

    static func isNativeCode(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name == "claude" && path.contains(".app/Contents/MacOS/") { return false }
        if ["claude", "claude-code"].contains(name) && !path.contains("/Claude.app/") { return true }
        if path.contains("/.local/share/claude/versions/") {
            return isNativeVersionName(name)
        }
        return path.contains("/Claude.app/Contents/Resources/") &&
            (name == "claude" || name == "claude-code")
    }

    static func sourceProcess() -> ClaudeProcessIdentity? {
        var pid = getppid()
        var seen = Set<Int32>()
        var fallback: ClaudeProcessIdentity?
        for _ in 0..<32 {
            guard pid > 1, seen.insert(pid).inserted, let details = details(pid) else { break }
            let name = URL(fileURLWithPath: details.path).lastPathComponent.lowercased()
            if isNativeCode(details.path) { return details.identity }
            if fallback == nil && (name == "node" || details.path.hasSuffix("/Claude.app/Contents/MacOS/Claude")) {
                fallback = details.identity
            }
            pid = details.parent
        }
        return fallback
    }

    static func nativeSources() -> (identities: [ClaudeProcessIdentity], unknown: Int) {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0, needed < 4_000_000 else { return ([], 1) }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 256)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids,
                                 Int32(pids.count * MemoryLayout<Int32>.size))
        guard bytes > 0, Int(bytes) < pids.count * MemoryLayout<Int32>.size else { return ([], 1) }
        var identities: [ClaudeProcessIdentity] = []
        var unknown = 0
        for pid in pids.prefix(Int(bytes) / MemoryLayout<Int32>.size) where pid > 1 {
            if let process = details(pid) {
                if isNativeCode(process.path) { identities.append(process.identity) }
            } else {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                   info.pbi_uid == getuid(), info.pbi_ruid == getuid() {
                    let name = withUnsafeBytes(of: info.pbi_name) {
                        String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8)
                    }
                    if isPossibleCodeName(name) { unknown += 1 }
                }
            }
        }
        // shortcut: unlinked node installs need a supported session API before they can be detected without arguments.
        return (identities, unknown)
    }
}

struct ClaudeSessionRecord: Codable {
    var schema = 1
    var sessionID: String
    var identity: ClaudeProcessIdentity
    var state: AgentState = .idle
    var updatedAt: Double
    var candidateAt: Double?
    var registriesEmpty = false
    var agents: [String: AgentState] = [:]

    var filename: String { "session-\(sessionID)-\(identity.key).json" }
    var observationID: String { "claude:\(sessionID):\(identity.key)" }

    static func validID(_ value: String) -> Bool {
        value.utf8.count <= 128 && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                                               options: .regularExpression) != nil
    }

    func validate(now: Double) throws {
        guard schema == 1, Self.validID(sessionID), identity.isValid,
              now.isFinite, now > 0, updatedAt.isFinite, updatedAt > 0, updatedAt <= now,
              agents.count <= 256, agents.allSatisfy({ Self.validID($0.key) && ($0.value.isActive || $0.value == .ended) }),
              candidateAt.map({ $0.isFinite && $0 > 0 && $0 <= updatedAt }) ?? true,
              !([AgentState.idle, .ended].contains(state) && agents.values.contains(where: { $0.isActive })) else {
            throw ClaudeActivityError.invalidEvent
        }
    }

    mutating func apply(_ input: [String: Any], now: Double) throws {
        guard now.isFinite, now > 0, now >= updatedAt,
              let event = input["hook_event_name"] as? String else { throw ClaudeActivityError.invalidEvent }
        let agentID = input["agent_id"] as? String
        if let agentID, !Self.validID(agentID) { throw ClaudeActivityError.invalidEvent }
        func hasEmptyRegistries() -> Bool {
            guard let background = input["background_tasks"] as? [[String: Any]],
                  let crons = input["session_crons"] as? [[String: Any]] else { return false }
            return background.isEmpty && crons.isEmpty
        }
        func registryExists() -> Bool {
            input["background_tasks"] is [[String: Any]] && input["session_crons"] is [[String: Any]]
        }
        switch event {
        case "SessionStart": break // A resumed or compacted active session must retain its state.
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "ElicitationResult":
            state = .working
            if let agentID { agents[agentID] = .working }
            candidateAt = nil
            registriesEmpty = false
        case "PermissionRequest", "Elicitation":
            if let agentID { agents[agentID] = .waiting; state = .working } else { state = .waiting }
            candidateAt = nil
            registriesEmpty = false
        case "SubagentStart":
            guard let agentID else { throw ClaudeActivityError.invalidEvent }
            agents[agentID] = .working
            state = .working
            candidateAt = nil
            registriesEmpty = false
        case "SubagentStop":
            guard let agentID else { throw ClaudeActivityError.invalidEvent }
            if agents[agentID] != nil { agents[agentID] = .ended }
            registriesEmpty = hasEmptyRegistries()
            if !registryExists() { state = .unknown; candidateAt = nil }
        case "Stop":
            state = registryExists() ? .working : .unknown
            candidateAt = registryExists() ? now : nil
            registriesEmpty = hasEmptyRegistries()
        case "Notification":
            guard let type = input["notification_type"] as? String else { throw ClaudeActivityError.invalidEvent }
            if type == "idle_prompt", let candidateAt, now - candidateAt >= 55,
               registriesEmpty, !agents.values.contains(where: { $0.isActive }) {
                state = .idle
                self.candidateAt = nil
            } else if ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(type) {
                state = .waiting
                self.candidateAt = nil
                registriesEmpty = false
            } else if type == "quota_auto_resume_fired" {
                state = .working
                self.candidateAt = nil
                registriesEmpty = false
            } else if ["quota_auto_resume_stale", "quota_auto_resume_disabled"].contains(type) {
                state = .unknown
                self.candidateAt = nil
                registriesEmpty = false
            }
        case "StopFailure":
            state = .unknown
            candidateAt = nil
            registriesEmpty = false
        case "SessionEnd":
            state = .ended
            agents = agents.mapValues { _ in .ended }
            candidateAt = nil
            registriesEmpty = true
        default: throw ClaudeActivityError.invalidEvent
        }
        updatedAt = now
        try validate(now: now)
    }
}

final class ClaudeEventStore {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WakeGuard/agent-events", isDirectory: true)
    static let maximumFileSize = 65_536
    let directory: URL
    let descriptor: Int32
    private var pendingDescriptors: [String: Int32] = [:]

    init(directory: URL, create: Bool) throws {
        self.directory = directory
        if create {
            let parent = directory.deletingLastPathComponent()
            var parentInfo = stat()
            if lstat(parent.path, &parentInfo) != 0 {
                guard errno == ENOENT, mkdir(parent.path, 0o700) == 0 else { throw ClaudeActivityError.unsafeFile }
            } else {
                guard (parentInfo.st_mode & S_IFMT) == S_IFDIR, parentInfo.st_uid == getuid(),
                      parentInfo.st_mode & 0o022 == 0 else { throw ClaudeActivityError.unsafeFile }
            }
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw ClaudeActivityError.unsafeFile }
        }
        let opened = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw ClaudeActivityError.unsafeFile }
        var info = stat()
        guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            close(opened)
            throw ClaudeActivityError.unsafeFile
        }
        descriptor = opened
    }

    deinit {
        pendingDescriptors.values.forEach { close($0) }
        close(descriptor)
    }

    func checkedFile(_ name: String, flags: Int32, maximumSize: Int = maximumFileSize) throws -> Int32 {
        let fd = openat(descriptor, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClaudeActivityError.unsafeFile }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600,
              info.st_size >= 0, info.st_size <= maximumSize else {
            close(fd)
            throw ClaudeActivityError.unsafeFile
        }
        return fd
    }

    func beginPending() throws -> String {
        let name = "pending-\(UUID().uuidString)"
        let fd = try checkedFile(name, flags: O_WRONLY | O_CREAT | O_EXCL, maximumSize: 0)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, fsync(fd) == 0, fsync(descriptor) == 0 else {
            close(fd)
            throw ClaudeActivityError.unavailable
        }
        pendingDescriptors[name] = fd
        return name
    }

    func releasePending(_ name: String) {
        if let fd = pendingDescriptors.removeValue(forKey: name) { close(fd) }
    }

    func readRecord(_ name: String, now: Double) throws -> ClaudeSessionRecord {
        let fd = try checkedFile(name, flags: O_RDONLY)
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: Self.maximumFileSize + 1)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, count <= Self.maximumFileSize else { throw ClaudeActivityError.unsafeFile }
        let record = try JSONDecoder().decode(ClaudeSessionRecord.self, from: Data(bytes.prefix(count)))
        guard record.filename == name else { throw ClaudeActivityError.invalidEvent }
        try record.validate(now: now)
        return record
    }

    func commit(_ input: [String: Any], identity: ClaudeProcessIdentity, now: Double, pending: String) throws {
        try commit(input, identity: identity, now: { now }, pending: pending)
    }

    func commit(_ input: [String: Any], identity: ClaudeProcessIdentity, now: () -> Double, pending: String) throws {
        defer { releasePending(pending) }
        guard let sessionID = input["session_id"] as? String, ClaudeSessionRecord.validID(sessionID),
              identity.isValid else { throw ClaudeActivityError.invalidEvent }
        let filename = "session-\(sessionID)-\(identity.key).json"
        let lock = try checkedFile("lock-\(sessionID)-\(identity.key)", flags: O_RDWR | O_CREAT, maximumSize: 0)
        defer { close(lock) }
        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let (deadline, overflow) = started.addingReportingOverflow(1_000_000_000)
        guard started > 0, !overflow else { throw ClaudeActivityError.unavailable }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            let time = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            guard lockError == EWOULDBLOCK || lockError == EAGAIN,
                  time >= started, time < deadline else { throw ClaudeActivityError.unavailable }
            usleep(10_000)
        }
        defer { flock(lock, LOCK_UN) }
        let time = now() // Stamp after acquiring the lock; concurrent hooks must not create a false clock reversal.
        guard time.isFinite, time > 0 else { throw ClaudeActivityError.invalidEvent }
        var record = ClaudeSessionRecord(sessionID: sessionID, identity: identity, updatedAt: time)
        var existing = stat()
        if fstatat(descriptor, filename, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            record = try readRecord(filename, now: time)
        } else if errno != ENOENT {
            throw ClaudeActivityError.unsafeFile
        } else if input["hook_event_name"] as? String != "SessionStart" {
            record.state = .unknown
        }
        try record.apply(input, now: time)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumFileSize else { throw ClaudeActivityError.invalidEvent }
        let temporary = "temporary-\(UUID().uuidString)"
        let fd = try checkedFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(fd) }
        var success = false
        defer { if !success { unlinkat(descriptor, temporary, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard amount > 0 else { throw ClaudeActivityError.unavailable }
                offset += amount
            }
        }
        guard fsync(fd) == 0, renameat(descriptor, temporary, descriptor, record.filename) == 0,
              fsync(descriptor) == 0 else { throw ClaudeActivityError.unavailable }
        guard pending.hasPrefix("pending-"),
              unlinkat(descriptor, pending, 0) == 0, fsync(descriptor) == 0 else {
            throw ClaudeActivityError.unavailable
        }
        success = true
    }

    private static func validStateName(_ name: String, prefix: String, suffix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let body = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        let components = body.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count >= 4,
              let pid = Int32(components[components.count - 3]),
              let seconds = UInt64(components[components.count - 2]),
              let microseconds = UInt64(components[components.count - 1]) else { return false }
        let sessionID = components.dropLast(3).joined(separator: "-")
        let identity = ClaudeProcessIdentity(pid: pid, startedSeconds: seconds, startedMicroseconds: microseconds)
        return ClaudeSessionRecord.validID(sessionID) && identity.isValid &&
            "\(prefix)\(sessionID)-\(identity.key)\(suffix)" == name
    }

    func reset() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 1_024 else { throw ClaudeActivityError.unsafeFile }
        var files: [(String, Int32, stat)] = []
        defer { files.forEach { close($0.1) } }
        for name in names {
            let session = Self.validStateName(name, prefix: "session-", suffix: ".json")
            let lock = Self.validStateName(name, prefix: "lock-", suffix: "")
            let marker = ["pending-", "temporary-"].contains { prefix in
                guard name.hasPrefix(prefix) else { return false }
                let value = String(name.dropFirst(prefix.count))
                return UUID(uuidString: value)?.uuidString == value
            }
            guard session || lock || marker else { throw ClaudeActivityError.unsafeFile }
            let fd = try checkedFile(name, flags: O_RDWR,
                                     maximumSize: lock || name.hasPrefix("pending-") ? 0 : Self.maximumFileSize)
            var info = stat()
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, fstat(fd, &info) == 0 else {
                close(fd)
                throw ClaudeActivityError.unavailable
            }
            files.append((name, fd, info))
        }
        guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set(names) else {
            throw ClaudeActivityError.unavailable
        }
        for (name, _, original) in files {
            var current = stat()
            guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                  current.st_nlink == 1, current.st_uid == getuid(),
                  (current.st_mode & S_IFMT) == S_IFREG, current.st_mode & 0o7777 == 0o600 else {
                throw ClaudeActivityError.unsafeFile
            }
        }
        for (name, _, _) in files {
            guard unlinkat(descriptor, name, 0) == 0 else { throw ClaudeActivityError.unavailable }
        }
        guard fsync(descriptor) == 0 else { throw ClaudeActivityError.unavailable }
    }
}

struct ClaudeActivityReader {
    var directory: URL
    var now: () -> Double
    var processIdentity: (Int32) -> ClaudeProcessIdentity?
    var nativeSources: () -> (identities: [ClaudeProcessIdentity], unknown: Int)

    init(directory: URL = ClaudeEventStore.defaultDirectory,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 },
         processIdentity: @escaping (Int32) -> ClaudeProcessIdentity? = { ClaudeProcesses.details($0)?.identity },
         nativeSources: @escaping () -> (identities: [ClaudeProcessIdentity], unknown: Int) = ClaudeProcesses.nativeSources) {
        self.directory = directory
        self.now = now
        self.processIdentity = processIdentity
        self.nativeSources = nativeSources
    }

    func snapshot() -> AgentSnapshot {
        let sources = nativeSources()
        var snapshot = AgentSnapshot(unknownSources: max(0, sources.unknown))
        var covered = Set<ClaudeProcessIdentity>()
        let time = now()
        guard time.isFinite, time > 0 else {
            snapshot.unknownSources += 1
            return snapshot
        }
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 && errno == ENOENT {
            snapshot.unknownSources += sources.identities.count
            return snapshot
        }
        do {
            let store = try ClaudeEventStore(directory: directory, create: false)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard names.count <= 1_024 else { throw ClaudeActivityError.unsafeFile }
            for name in names {
                do {
                    if name.hasPrefix("lock-") {
                        let fd = try store.checkedFile(name, flags: O_RDONLY, maximumSize: 0)
                        close(fd)
                        continue
                    }
                    guard name.hasPrefix("session-"), name.hasSuffix(".json") else {
                        snapshot.unknownSources += 1
                        continue
                    }
                    let record = try store.readRecord(name, now: time)
                    let live = processIdentity(record.identity.pid) == record.identity
                    if live { covered.insert(record.identity) }
                    let uncertain = !live && (record.state.isActive || record.agents.values.contains(where: { $0.isActive }))
                    snapshot.observations.append(AgentObservation(id: record.observationID, provider: "Claude Code",
                        state: uncertain ? .unknown : record.state, updatedAt: record.updatedAt))
                    for (agent, state) in record.agents {
                        snapshot.observations.append(AgentObservation(id: "\(record.observationID):\(agent)", provider: "Claude Code",
                            state: live || state == .ended ? state : .unknown, updatedAt: record.updatedAt))
                    }
                } catch { snapshot.unknownSources += 1 }
            }
        } catch { snapshot.unknownSources += 1 }
        snapshot.unknownSources += sources.identities.filter { !covered.contains($0) }.count
        return snapshot
    }
}

enum ClaudeEventReporter {
    static func reset(directory: URL = ClaudeEventStore.defaultDirectory) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 && errno == ENOENT { return }
        try ClaudeEventStore(directory: directory, create: false).reset()
    }

    static func report(input source: FileHandle, store: ClaudeEventStore,
                       identity: () -> ClaudeProcessIdentity?, now: () -> Double) throws {
        let pending = try store.beginPending()
        let maximumInputSize = 1_048_576
        var input = Data()
        while let bytes = try source.read(upToCount: min(65_536, maximumInputSize + 1 - input.count)),
              !bytes.isEmpty {
            input.append(bytes)
            guard input.count <= maximumInputSize else { throw ClaudeActivityError.invalidEvent }
        }
        guard let event = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let identity = identity() else { throw ClaudeActivityError.invalidEvent }
        try store.commit(event, identity: identity, now: now, pending: pending)
    }

    static func run() {
        do {
            let store = try ClaudeEventStore(directory: ClaudeEventStore.defaultDirectory, create: true)
            try report(input: .standardInput, store: store, identity: ClaudeProcesses.sourceProcess,
                       now: { Date().timeIntervalSince1970 })
        } catch { /* Hook errors must neither print conversation data nor block Claude. */ }
    }
}
