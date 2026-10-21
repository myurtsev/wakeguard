import Foundation
import Darwin
import CoreFoundation

struct CodexRolloutParser {
    let sessionID: String
    private let writerStartedAt: Double
    private let sessionTime: UInt64
    private(set) var turnID: String?
    private(set) var state: AgentState = .unknown
    private var startedAt: Double?
    private var gap = false
    private var requiresFreshStart: Bool
    private let freshStartAfter: Double

    init?(header: Data, writerStartedAt: Double, requireFreshStart: Bool = false,
          freshStartAfter: Double? = nil) {
        guard let end = header.firstIndex(of: 10),
              let record = try? JSONSerialization.jsonObject(with: header[..<end]) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any],
              let id = payload["id"] as? String, let sessionTime = Self.uuidTime(id),
              let version = payload["cli_version"] as? String, !version.isEmpty, version.utf8.count <= 100,
              writerStartedAt.isFinite, writerStartedAt > 0,
              freshStartAfter?.isFinite != false else { return nil }
        sessionID = id.lowercased()
        self.sessionTime = sessionTime
        self.writerStartedAt = writerStartedAt
        requiresFreshStart = requireFreshStart
        self.freshStartAfter = max(writerStartedAt, freshStartAfter ?? writerStartedAt)
    }

    mutating func append(_ completeLines: Data) {
        for line in completeLines.split(separator: 10, omittingEmptySubsequences: true) {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                state = .unknown
                gap = true
                continue
            }
            guard let recordType = record["type"] as? String,
                  ["session_meta", "turn_context", "response_item", "compacted", "event_msg", "world_state",
                   "inter_agent_communication_metadata", "token_usage_record"].contains(recordType) else {
                state = .unknown; gap = true; continue
            }
            guard recordType == "event_msg" else { continue }
            guard let payload = record["payload"] as? [String: Any],
                  let event = payload["type"] as? String else { state = .unknown; gap = true; continue }
            guard ["task_started", "task_complete", "turn_aborted"].contains(event) else {
                if event.hasPrefix("task_") { state = .unknown; gap = true }
                continue
            }
            guard let id = payload["turn_id"] as? String, let turnTime = Self.uuidTime(id) else {
                state = .unknown
                gap = true
                continue
            }
            // Forks copy older parent lifecycle records into the new rollout.
            if turnTime < sessionTime { continue }
            guard turnTime > sessionTime, let start = Self.number(payload["started_at"]) else {
                state = .unknown; gap = true; continue
            }
            if event == "task_started" {
                let fresh = start >= floor(writerStartedAt) && Double(turnTime) > floor(writerStartedAt * 1000)
                if requiresFreshStart {
                    guard fresh, Double(turnTime) > floor(freshStartAfter * 1000) else {
                        state = .unknown; gap = true; continue
                    }
                    requiresFreshStart = false
                }
                turnID = id
                startedAt = start
                gap = false
                state = fresh ? .working : .unknown
            } else {
                guard !requiresFreshStart, id == turnID, start == startedAt, !gap,
                      let end = Self.number(payload["completed_at"]), end >= start else {
                    state = .unknown
                    gap = true
                    continue
                }
                state = event == "task_complete" ? .idle : .ended
            }
        }
    }

    static func parse(header: Data, tail: Data, writerStartedAt: Double, truncatedStart: Bool = false,
                      requireFreshStart: Bool = false, freshStartAfter: Double? = nil)
        -> CodexRolloutParser? {
        guard var parser = Self(header: header, writerStartedAt: writerStartedAt,
                                requireFreshStart: requireFreshStart, freshStartAfter: freshStartAfter) else { return nil }
        var bytes = tail
        if truncatedStart {
            guard let newline = bytes.firstIndex(of: 10) else { return parser }
            bytes = Data(bytes[(newline + 1)...])
        }
        guard let newline = bytes.lastIndex(of: 10) else { return parser }
        parser.append(Data(bytes[...newline]))
        if newline != bytes.index(before: bytes.endIndex) { parser.state = .unknown }
        return parser
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func uuidTime(_ text: String) -> UInt64? {
        guard let uuid = UUID(uuidString: text) else { return nil }
        let packed = uuid.uuid
        let bytes = withUnsafeBytes(of: packed) { Array($0) }
        guard bytes[6] >> 4 == 7 else { return nil }
        return bytes.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

final class CodexActivityReader {
    private struct Identity: Hashable {
        let pid: pid_t
        let startedAt: Double
        let executable: String
    }
    private struct OpenFile {
        let pid: pid_t
        var writable: Bool?
        var regular = false
        var inode: UInt64?
        var device: UInt64?
        var path: String?
    }
    private struct Cache {
        let path: String
        let writer: Identity
        var parser: CodexRolloutParser
        var offset: off_t
        var size: off_t
        var modified: timespec
        var invalidated = false
        let observationID: String
    }
    private var cache: [String: Cache] = [:]
    private var previous: [String: AgentObservation] = [:]
    private let uid = getuid()
    private let sessions: String
    private let maximumRead = 8 * 1024 * 1024

    init(sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)) {
        sessions = sessionsDirectory.path + "/"
    }

    func snapshot() -> AgentSnapshot {
        let now = Date().timeIntervalSince1970
        var unknown = 0
        var current: [String: AgentObservation] = [:]
        guard previous.count <= 512, cache.count <= 512,
              let identities = processes(), identities.count <= 256 else {
            return unknownSnapshot(now: now)
        }
        if !identities.isEmpty {
            guard let output = lsof(pids: identities.map(\.pid)) else { return unknownSnapshot(now: now) }
            let writers = Dictionary(uniqueKeysWithValues: identities.map { ($0.pid, $0) })
            let files = Self.openFiles(output).filter {
                guard let path = $0.path else { return false }
                return $0.writable != false && path.hasPrefix(sessions) &&
                    URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") && path.hasSuffix(".jsonl")
            }
            guard files.count <= 128 else { return unknownSnapshot(now: now) }
            let groups = Dictionary(grouping: files) { "\($0.device ?? 0):\($0.inode ?? 0)" }
            var visited = Set<String>()
            for file in files {
                let key = "\(file.device ?? 0):\(file.inode ?? 0)"
                guard visited.insert(key).inserted else { continue }
                guard let group = groups[key], Set(group.map(\.pid)).count == 1 else {
                    cache[key]?.invalidated = true
                    unknown += 1
                    continue
                }
                guard let path = file.path else { unknown += 1; continue }
                guard file.writable == true, file.regular, let writer = writers[file.pid],
                      process(file.pid) == writer, let inode = file.inode, let device = file.device,
                      let observation = read(path: path, inode: inode, device: device, writer: writer, now: now)
                else { unknown += 1; continue }
                current[observation.id] = observation
            }
        }
        for (key, item) in cache where current[item.observationID] == nil && item.parser.state == .working {
            guard let prior = previous[item.observationID], prior.state.isActive || prior.state == .unknown,
                  let turn = item.parser.turnID, Self.identityHasExited(pid: item.writer.pid, startedAt: item.writer.startedAt),
                  let separator = key.firstIndex(of: ":"),
                  let device = UInt64(key[..<separator]), let inode = UInt64(key[key.index(after: separator)...]),
                  let completed = read(path: item.path, inode: inode, device: device, writer: item.writer,
                                       now: now, closedTurnID: turn) else { continue }
            current[completed.id] = completed
            // An exact closed-turn terminal remains proven even if another process changes during this poll.
            previous[completed.id] = completed
        }
        guard let after = processes(), Set(after) == Set(identities) else { return unknownSnapshot(now: now) }
        for (id, old) in previous where current[id] == nil {
            current[id] = AgentObservation(id: id, provider: "codex",
                                          state: old.state.isActive ? .unknown : old.state,
                                          updatedAt: now)
        }
        previous = current
        return AgentSnapshot(observations: Array(current.values), unknownSources: unknown)
    }

    private func unknownSnapshot(now: Double) -> AgentSnapshot {
        previous = previous.mapValues {
            AgentObservation(id: $0.id, provider: "codex", state: $0.state.isActive ? .unknown : $0.state,
                             updatedAt: now)
        }
        return AgentSnapshot(observations: Array(previous.values), unknownSources: 1)
    }

    private func processes() -> [Identity]? {
        var pids = [pid_t](repeating: 0, count: 8192)
        let capacity = pids.count * MemoryLayout<pid_t>.size
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, bytes < capacity, bytes % Int32(MemoryLayout<pid_t>.size) == 0 else { return nil }
        var result: [Identity] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path)
            guard URL(fileURLWithPath: executable).lastPathComponent == "codex" else { continue }
            var metadata = stat()
            guard lstat(executable, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == 0 || metadata.st_uid == uid, metadata.st_mode & 0o022 == 0,
                  let identity = process(pid) else { return nil }
            result.append(identity)
        }
        return result
    }

    private func process(_ pid: pid_t) -> Identity? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        guard URL(fileURLWithPath: executable).lastPathComponent == "codex" else { return nil }
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard bytes == MemoryLayout<proc_bsdinfo>.size, info.pbi_uid == uid,
              info.pbi_start_tvsec > 0 else { return nil }
        return Identity(pid: pid, startedAt: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000,
                        executable: executable)
    }

    private func read(path: String, inode: UInt64, device: UInt64, writer: Identity, now: Double,
                      closedTurnID: String? = nil)
        -> AgentObservation? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, Self.validFile(metadata, uid: uid, device: device, inode: inode) else { return nil }
        let key = "\(device):\(inode)"
        var item = cache[key]
        let overwritten = item.map {
            metadata.st_size < $0.size || (metadata.st_size == $0.size &&
                (metadata.st_mtimespec.tv_sec != $0.modified.tv_sec || metadata.st_mtimespec.tv_nsec != $0.modified.tv_nsec))
        } ?? false
        let reset = item?.writer != writer || item?.path != path || item?.invalidated == true || overwritten
        if let closedTurnID {
            guard !reset, item?.parser.state == .working, item?.parser.turnID == closedTurnID,
                  metadata.st_size - (item?.offset ?? 0) <= maximumRead,
                  Self.identityHasExited(pid: writer.pid, startedAt: writer.startedAt) else { return nil }
        }
        if reset {
            let prior = item.flatMap { previous[$0.observationID] }
            let requireFresh = item.map { $0.parser.state.isActive || $0.parser.state == .unknown } == true ||
                prior?.state.isActive == true || prior?.state == .unknown
            // shortcut: rollout schema is private; unknown metadata stays unknown until its lifecycle is verified.
            guard let header = data(fd: fd, offset: 0, count: min(128 * 1024, Int(metadata.st_size))),
                  let parser = CodexRolloutParser(header: header, writerStartedAt: writer.startedAt,
                      requireFreshStart: requireFresh, freshStartAfter: prior?.updatedAt) else { return nil }
            item = Cache(path: path, writer: writer, parser: parser, offset: max(0, metadata.st_size - off_t(maximumRead)),
                         size: metadata.st_size, modified: metadata.st_mtimespec,
                         observationID: "codex:\(key):\(parser.sessionID)")
        }
        guard var value = item,
              var bytes = data(fd: fd, offset: value.offset,
                               count: Int(min(off_t(maximumRead), metadata.st_size - value.offset))) else { return nil }
        let initialParser = value.parser
        let truncatedStart = reset && value.offset > 0
        if truncatedStart {
            guard let newline = bytes.firstIndex(of: 10) else { return nil }
            value.offset += off_t(newline + 1)
            bytes = Data(bytes[(newline + 1)...])
        }
        var state = value.parser.state
        if !bytes.isEmpty {
            guard let newline = bytes.lastIndex(of: 10) else { return nil }
            value.parser.append(Data(bytes[...newline]))
            value.offset += off_t(newline + 1)
            state = value.offset == metadata.st_size ? value.parser.state : .unknown
        }
        if truncatedStart && value.parser.turnID == nil {
            value.parser = initialParser
            value.offset = 0
            state = .unknown
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Self.validFile(after, uid: uid, device: device, inode: inode),
              Self.sameFileVersion(metadata, after) else { return nil }
        if let closedTurnID {
            guard Self.identityHasExited(pid: writer.pid, startedAt: writer.startedAt), value.parser.turnID == closedTurnID,
                  state == .idle || state == .ended else { return nil }
        } else if process(writer.pid) != writer { return nil }
        value.size = metadata.st_size
        value.modified = metadata.st_mtimespec
        cache[key] = value
        return AgentObservation(id: value.observationID, provider: "codex", state: state, updatedAt: now)
    }

    static func validFile(_ metadata: stat, uid: uid_t, device: UInt64, inode: UInt64) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == uid && metadata.st_mode & 0o022 == 0 &&
            metadata.st_nlink == 1 && UInt64(metadata.st_ino) == inode &&
            UInt64(UInt32(bitPattern: metadata.st_dev)) == device && metadata.st_size > 0
    }

    static func sameFileVersion(_ first: stat, _ last: stat) -> Bool {
        first.st_size == last.st_size && first.st_mtimespec.tv_sec == last.st_mtimespec.tv_sec &&
            first.st_mtimespec.tv_nsec == last.st_mtimespec.tv_nsec && first.st_ctimespec.tv_sec == last.st_ctimespec.tv_sec &&
            first.st_ctimespec.tv_nsec == last.st_ctimespec.tv_nsec
    }

    static func identityHasExited(pid: pid_t, startedAt: Double) -> Bool {
        guard pid > 0, startedAt.isFinite, startedAt > 0 else { return false }
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if bytes == MemoryLayout<proc_bsdinfo>.size {
            let current = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
            return current != startedAt
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    private func data(fd: Int32, offset: off_t, count: Int) -> Data? {
        guard count >= 0, count <= maximumRead else { return nil }
        if count == 0 { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let readCount = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
        guard readCount == count else { return nil }
        return Data(bytes)
    }

    private static func openFiles(_ output: Data) -> [OpenFile] {
        var files: [OpenFile] = []
        var file: OpenFile?
        var pid: pid_t = 0
        for field in output.split(separator: 0) {
            let field = field.drop(while: { $0 == 10 })
            guard let code = field.first, let value = String(data: Data(field.dropFirst()), encoding: .utf8) else { continue }
            if code == 112 || code == 102 {
                if let file { files.append(file) }
                file = nil
                if code == 112 { pid = pid_t(value) ?? 0 }
                else { file = OpenFile(pid: pid) }
            } else if file != nil {
                switch code {
                case 97: file?.writable = value == "w" || value == "u" ? true : (value == "r" ? false : nil)
                case 116: file?.regular = value == "REG"
                case 105: file?.inode = UInt64(value)
                case 68: file?.device = UInt64(value.hasPrefix("0x") ? String(value.dropFirst(2)) : value, radix: value.hasPrefix("0x") ? 16 : 10)
                case 110: file?.path = value
                default: break
                }
            }
        }
        if let file { files.append(file) }
        return files
    }

    private func lsof(pids: [pid_t]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-w", "-a", "-p", pids.map(String.init).joined(separator: ","), "-F0pfaDint"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        pipe.fileHandleForWriting.closeFile()
        defer { pipe.fileHandleForReading.closeFile() }
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 2 * 1024 * 1024 { break }
            } else if count == 0 && !process.isRunning {
                return process.terminationStatus == 0 ? output : nil
            } else if count < 0 && errno != EAGAIN && errno != EINTR { break }
            else { usleep(10_000) }
        }
        if process.isRunning { process.terminate(); usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return nil
    }
}
