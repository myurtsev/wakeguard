import Foundation
import Darwin

@main struct CodexActivityTests {
    static let session = "00000001-86a0-7000-8000-000000000001"
    static let parent = "00000001-5f90-7000-8000-000000000002"
    static let turn = "00000001-8a88-7000-8000-000000000003"
    static let other = "00000001-8e70-7000-8000-000000000004"
    static let future = "00000001-9640-7000-8000-000000000005"

    static func record(_ type: String, _ payload: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload], options: [.sortedKeys])
        data.append(10)
        return data
    }
    static func meta(_ id: String = session, version: String = "0.162.0-alpha.17.2") -> Data {
        record("session_meta", ["id": id, "cli_version": version])
    }
    static func event(_ type: String, id: String = turn, start: Double = 101, end: Double = 102) -> Data {
        record("event_msg", ["type": type, "turn_id": id, "started_at": start, "completed_at": end])
    }
    static func parse(_ data: Data, truncated: Bool = false, writerStart: Double = 100) -> CodexRolloutParser {
        CodexRolloutParser.parse(header: meta(), tail: data, writerStartedAt: writerStart, truncatedStart: truncated)!
    }

    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            let snapshot = CodexActivityReader().snapshot()
            print("Codex snapshot: \(snapshot.observations.count) sources, \(snapshot.activeCount) active, \(snapshot.unknownCount) unknown")
            return
        }
        assert(parse(event("task_started")).state == .working)
        assert(parse(event("task_started") + event("task_complete")).state == .idle)
        assert(parse(event("task_started") + event("turn_aborted")).state == .ended)
        assert(parse(event("task_started") + event("task_complete", id: other)).state == .unknown)
        assert(parse(event("task_started") + event("task_complete", start: 100.5)).state == .unknown)
        assert(parse(event("task_started") + event("task_complete", end: 100)).state == .unknown)
        assert(parse(event("task_complete")).state == .unknown)
        assert(parse(meta()).state == .unknown)
        assert(parse(event("task_started", start: 99)).state == .unknown)
        assert(parse(event("task_started", start: 99) + event("task_complete", start: 99)).state == .idle)
        assert(parse(event("task_started", id: session)).state == .unknown)
        assert(parse(event("task_started", id: session) + event("task_complete", id: session)).state == .unknown)
        assert(parse(event("task_started", start: 100), writerStart: 100.75).state == .working)
        assert(parse(event("task_started", start: 101), writerStart: 101.75).state == .unknown)
        assert(parse(event("task_started") + Data("{\"type\":".utf8)).state == .unknown)
        assert(parse(event("task_started") + Data("broken\n".utf8)).state == .unknown)
        assert(parse(event("task_started") + event("task_new_unknown_event")).state == .unknown)
        assert(parse(event("task_started") + record("unknown_record", [:])).state == .unknown)
        assert(parse(event("task_started") + record("unknown_record", [:]) + event("task_complete")).state == .unknown)
        assert(parse(Data("partial older record\n".utf8) + event("task_started") + event("task_complete"), truncated: true).state == .idle)
        assert(parse(Data("partial older record\n".utf8) + event("task_complete"), truncated: true).state == .unknown)
        assert(parse(meta(parent) + event("task_started", id: parent)).state == .unknown)
        let fork = meta() + meta(parent) + event("task_started", id: parent) + event("task_started") + event("task_complete")
        let parsedFork = parse(fork)
        assert(parsedFork.sessionID == session && parsedFork.turnID == turn && parsedFork.state == .idle)
        assert(CodexRolloutParser(header: meta(version: ""), writerStartedAt: 100) == nil)
        assert(CodexRolloutParser(header: meta("invalid"), writerStartedAt: 100) == nil)
        let migratedName = "rollout-old-\(parent)_\(session).jsonl"
        let migrated = CodexRolloutParser.parse(header: meta(parent), tail: meta(session) + event("task_started"), writerStartedAt: 100)!
        assert(migratedName.hasSuffix("\(session).jsonl") && migrated.sessionID == parent)
        var incremental = parse(event("task_started"))
        incremental.append(record("response_item", ["type": "function_call"]))
        assert(incremental.state == .working)
        incremental.append(event("task_complete"))
        assert(incremental.state == .idle)
        let oldHistory = event("task_started", start: 99) + event("task_complete", start: 99)
        assert(parse(oldHistory).state == .idle)
        var restarted = CodexRolloutParser.parse(header: meta(), tail: oldHistory, writerStartedAt: 102,
                                                requireFreshStart: true, freshStartAfter: 102)!
        assert(restarted.state == .unknown)
        restarted.append(event("task_complete", start: 99))
        assert(restarted.state == .unknown)
        restarted.append(event("task_started", id: future, start: 104))
        assert(restarted.state == .working)
        restarted.append(event("task_complete", id: future, start: 104, end: 105))
        assert(restarted.state == .idle)
        var rollback = CodexRolloutParser.parse(header: meta(), tail: event("task_started") + event("task_complete"),
                                               writerStartedAt: 100, requireFreshStart: true, freshStartAfter: 103)!
        assert(rollback.state == .unknown)
        rollback.append(event("task_complete"))
        assert(rollback.state == .unknown)
        rollback.append(event("task_started", id: future, start: 104) + event("task_complete", id: future, start: 104, end: 105))
        assert(rollback.state == .idle)
        var closed = parse(event("task_started"))
        let expectedTurn = closed.turnID
        closed.append(event("task_complete"))
        assert(closed.turnID == expectedTurn && closed.state == .idle)
        var differentClosed = parse(event("task_started"))
        differentClosed.append(event("task_started", id: future, start: 104) + event("task_complete", id: future, start: 104, end: 105))
        assert(differentClosed.turnID != expectedTurn)
        var file = stat()
        file.st_mode = S_IFREG | 0o600
        file.st_uid = getuid()
        file.st_nlink = 1
        file.st_dev = 10
        file.st_ino = 44
        file.st_size = 16
        assert(CodexActivityReader.validFile(file, uid: getuid(), device: 10, inode: 44))
        var unsafe = file
        unsafe.st_nlink = 2
        assert(!CodexActivityReader.validFile(unsafe, uid: getuid(), device: 10, inode: 44))
        unsafe = file
        unsafe.st_mode = S_IFLNK | 0o600
        assert(!CodexActivityReader.validFile(unsafe, uid: getuid(), device: 10, inode: 44))
        unsafe = file
        unsafe.st_mode = S_IFREG | 0o666
        assert(!CodexActivityReader.validFile(unsafe, uid: getuid(), device: 10, inode: 44))
        assert(!CodexActivityReader.validFile(file, uid: getuid() + 1, device: 10, inode: 44))
        assert(!CodexActivityReader.validFile(file, uid: getuid(), device: 10, inode: 45))
        assert(CodexActivityReader.sameFileVersion(file, file))
        var appended = file
        appended.st_size += 1
        assert(!CodexActivityReader.sameFileVersion(file, appended))
        appended = file
        appended.st_mtimespec.tv_nsec += 1
        assert(!CodexActivityReader.sameFileVersion(file, appended))
        var ownProcess = proc_bsdinfo()
        assert(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &ownProcess, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size)
        let ownStart = Double(ownProcess.pbi_start_tvsec) + Double(ownProcess.pbi_start_tvusec) / 1_000_000
        assert(!CodexActivityReader.identityHasExited(pid: getpid(), startedAt: ownStart))
        assert(CodexActivityReader.identityHasExited(pid: getpid(), startedAt: ownStart - 1))
        assert(CodexActivityReader.identityHasExited(pid: Int32.max, startedAt: 1))
        print("Codex lifecycle metadata checks passed")
    }
}
