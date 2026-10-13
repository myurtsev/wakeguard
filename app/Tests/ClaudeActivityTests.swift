import Foundation
import Darwin

private final class ClaudeFixture {
    let root: URL
    let store: ClaudeEventStore
    var time = 1_000.0
    let identity = ClaudeProcessIdentity(pid: 1_001, startedSeconds: 100, startedMicroseconds: 2)
    var live: [Int32: ClaudeProcessIdentity] = [:]
    var native: [ClaudeProcessIdentity] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WakeGuard-ClaudeTests-\(UUID().uuidString)")
        guard mkdir(root.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        store = try ClaudeEventStore(directory: root.appendingPathComponent("agent-events"), create: true)
        live[identity.pid] = identity
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func input(_ event: String, session: String = "session", extra: [String: Any] = [:]) -> [String: Any] {
        var input: [String: Any] = ["session_id": session, "hook_event_name": event]
        extra.forEach { input[$0] = $1 }
        return input
    }

    func emit(_ event: String, session: String = "session", extra: [String: Any] = [:], process: ClaudeProcessIdentity? = nil) throws {
        time += 1
        try store.commit(input(event, session: session, extra: extra), identity: process ?? identity,
                         now: time, pending: store.beginPending())
    }

    func snapshot() -> AgentSnapshot {
        ClaudeActivityReader(directory: store.directory, now: { self.time },
            processIdentity: { self.live[$0] }, nativeSources: { (self.native, 0) }).snapshot()
    }

    func recordURL(session: String = "session", process: ClaudeProcessIdentity? = nil) -> URL {
        let record = ClaudeSessionRecord(sessionID: session, identity: process ?? identity, updatedAt: time)
        return store.directory.appendingPathComponent(record.filename)
    }

    func report(_ data: Data, process: ClaudeProcessIdentity?) throws {
        let url = root.appendingPathComponent("input.json")
        try data.write(to: url)
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        try ClaudeEventReporter.report(input: source, store: store, identity: { process }, now: { self.time })
    }
}

private final class ClaudeParallelResults: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    func fail() { lock.lock(); failures += 1; lock.unlock() }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }
}

@main enum ClaudeActivityTests {
    static let emptyRegistries: [String: Any] = ["background_tasks": [], "session_crons": []]

    static func expectFailure(_ action: () throws -> Void) {
        do { try action(); assertionFailure("Expected rejection") } catch {}
    }

    static func main() throws {
        let normal = try ClaudeFixture()
        try normal.emit("SessionStart")
        assert(normal.snapshot().observations.first?.state == .idle)
        try normal.emit("UserPromptSubmit", extra: ["prompt": "PRIVATE_PROMPT_SENTINEL", "cwd": "/PRIVATE_PATH_SENTINEL"])
        assert(normal.snapshot().activeCount == 1)
        try normal.emit("PermissionRequest")
        assert(normal.snapshot().waitingCount == 1)
        try normal.emit("PostToolUse")
        assert(normal.snapshot().waitingCount == 0 && normal.snapshot().activeCount == 1)
        try normal.emit("SubagentStart", extra: ["agent_id": "child"])
        var waiter = AgentWaiter()
        assert(waiter.arm(normal.snapshot(), now: normal.time))
        try normal.emit("Stop", extra: emptyRegistries)
        normal.time += 60
        try normal.emit("Notification", extra: ["notification_type": "idle_prompt"])
        assert(normal.snapshot().activeCount == 2) // A registered child still works.
        try normal.emit("SubagentStop", extra: emptyRegistries.merging(["agent_id": "child"]) { _, new in new })
        normal.time += 60
        try normal.emit("Notification", extra: ["notification_type": "idle_prompt"])
        let finished = normal.snapshot()
        assert(finished.activeCount == 0 && finished.unknownCount == 0)
        assert(finished.observations.map(\.state).contains(.ended))
        assert(!waiter.step(finished, now: normal.time))
        assert(waiter.step(finished, now: normal.time + 30))
        let saved = try String(contentsOf: normal.recordURL(), encoding: .utf8)
        assert(!saved.contains("PRIVATE_PROMPT_SENTINEL") && !saved.contains("PRIVATE_PATH_SENTINEL"))
        assert(!saved.contains("cwd") && !saved.contains("prompt") && !saved.contains("transcript"))
        var info = stat()
        assert(lstat(normal.recordURL().path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
        assert(lstat(normal.store.directory.path, &info) == 0 && info.st_mode & 0o7777 == 0o700)

        let candidate = try ClaudeFixture()
        try candidate.emit("UserPromptSubmit")
        try candidate.emit("Stop", extra: emptyRegistries)
        try candidate.emit("Notification", extra: ["notification_type": "idle_prompt"])
        assert(candidate.snapshot().activeCount == 1) // A late notification cannot end a new candidate immediately.
        try candidate.emit("PreToolUse")
        candidate.time += 100
        try candidate.emit("Notification", extra: ["notification_type": "idle_prompt"])
        assert(candidate.snapshot().activeCount == 1)
        try candidate.emit("Stop", extra: ["background_tasks": [["id": "background"]], "session_crons": []])
        candidate.time += 60
        try candidate.emit("Notification", extra: ["notification_type": "idle_prompt"])
        assert(candidate.snapshot().activeCount == 1)
        try candidate.emit("Stop", extra: ["background_tasks": [], "session_crons": [["id": "cron"]]])
        candidate.time += 60
        try candidate.emit("Notification", extra: ["notification_type": "idle_prompt"])
        assert(candidate.snapshot().activeCount == 1)
        try candidate.emit("Stop")
        assert(candidate.snapshot().unknownCount == 1)
        try candidate.emit("UserPromptSubmit")
        try candidate.emit("StopFailure")
        assert(candidate.snapshot().unknownCount == 1)
        try candidate.emit("UserPromptSubmit")
        try candidate.emit("Elicitation")
        assert(candidate.snapshot().waitingCount == 1)
        try candidate.emit("ElicitationResult")
        assert(candidate.snapshot().activeCount == 1 && candidate.snapshot().waitingCount == 0)
        try candidate.emit("SessionStart")
        assert(candidate.snapshot().activeCount == 1) // Resume/compaction must not discard work.
        try candidate.emit("SessionEnd")
        candidate.live.removeAll()
        assert(candidate.snapshot().unknownCount == 0 && candidate.snapshot().observations.first?.state == .ended)

        let unseenParent = try ClaudeFixture()
        try unseenParent.emit("SubagentStop", extra: emptyRegistries.merging(["agent_id": "unseen"]) { _, new in new })
        assert(unseenParent.snapshot().unknownCount == 1)
        try unseenParent.emit("Notification", extra: ["notification_type": "quota_auto_resume_fired"])
        assert(unseenParent.snapshot().activeCount == 1)
        try unseenParent.emit("Notification", extra: ["notification_type": "quota_auto_resume_stale"])
        assert(unseenParent.snapshot().unknownCount == 1)

        let multiple = try ClaudeFixture()
        let second = ClaudeProcessIdentity(pid: 1_002, startedSeconds: 101, startedMicroseconds: 3)
        multiple.live[second.pid] = second
        try multiple.emit("UserPromptSubmit")
        try multiple.emit("UserPromptSubmit", session: "second", process: second)
        assert(multiple.snapshot().activeCount == 2)
        try multiple.emit("SessionEnd", session: "second", process: second)
        assert(multiple.snapshot().activeCount == 1)
        multiple.live.removeValue(forKey: multiple.identity.pid)
        assert(multiple.snapshot().unknownCount == 1) // Linked active records stay unknown without a live process.
        multiple.live[multiple.identity.pid] = ClaudeProcessIdentity(pid: multiple.identity.pid, startedSeconds: 200, startedMicroseconds: 0)
        assert(multiple.snapshot().unknownCount == 1) // PID reuse cannot keep a dead task alive or mark it done.
        multiple.native = [second, ClaudeProcessIdentity(pid: 2_002, startedSeconds: 100, startedMicroseconds: 0)]
        assert(multiple.snapshot().unknownSources == 1)
        try multiple.emit("UserPromptSubmit", process: second) // Same session identifier, different process.
        assert(multiple.snapshot().observations.count == 3)

        let incomplete = try ClaudeFixture()
        try incomplete.emit("SessionStart")
        _ = try incomplete.store.beginPending() // Created before stdin; a killed or blocked writer remains unknown.
        assert(incomplete.snapshot().unknownSources == 1)
        try incomplete.emit("SessionEnd")
        assert(incomplete.snapshot().unknownSources == 1) // Another event must never hide an earlier lost event.

        let locked = try ClaudeFixture()
        try locked.emit("SessionStart")
        let lock = try locked.store.checkedFile("lock-session-\(locked.identity.key)", flags: O_RDWR, maximumSize: 0)
        assert(flock(lock, LOCK_EX | LOCK_NB) == 0)
        expectFailure { try locked.emit("UserPromptSubmit") }
        assert(locked.snapshot().unknownSources == 1)
        flock(lock, LOCK_UN)
        close(lock)

        let parallel = try ClaudeFixture()
        try parallel.emit("SessionStart")
        let parallelLock = try parallel.store.checkedFile("lock-session-\(parallel.identity.key)", flags: O_RDWR, maximumSize: 0)
        assert(flock(parallelLock, LOCK_EX | LOCK_NB) == 0)
        let ready = DispatchSemaphore(value: 0)
        let complete = DispatchGroup()
        let results = ClaudeParallelResults()
        let directory = parallel.store.directory
        let process = parallel.identity
        for event in ["UserPromptSubmit", "PreToolUse"] {
            complete.enter()
            DispatchQueue.global().async {
                defer { complete.leave() }
                do {
                    let store = try ClaudeEventStore(directory: directory, create: false)
                    let pending = try store.beginPending()
                    ready.signal()
                    try store.commit(["session_id": "session", "hook_event_name": event], identity: process,
                                     now: { Date().timeIntervalSince1970 }, pending: pending)
                } catch { results.fail() }
            }
        }
        assert(ready.wait(timeout: .now() + 2) == .success)
        assert(ready.wait(timeout: .now() + 2) == .success)
        assert(parallel.snapshot().unknownSources == 2)
        usleep(100_000)
        flock(parallelLock, LOCK_UN)
        close(parallelLock)
        assert(complete.wait(timeout: .now() + 3) == .success)
        parallel.time = Date().timeIntervalSince1970 + 1
        assert(results.failureCount == 0)
        assert(parallel.snapshot().activeCount == 1 && parallel.snapshot().unknownCount == 0)

        for unsafe in ["mode", "link", "symlink", "json", "clock", "directory"] {
            let fixture = try ClaudeFixture()
            try fixture.emit("UserPromptSubmit")
            let url = fixture.recordURL()
            switch unsafe {
            case "mode": assert(chmod(url.path, 0o644) == 0)
            case "link": assert(link(url.path, fixture.root.appendingPathComponent("linked").path) == 0)
            case "symlink":
                assert(unlink(url.path) == 0)
                assert(symlink(fixture.root.appendingPathComponent("missing").path, url.path) == 0)
            case "json": try Data("{broken".utf8).write(to: url)
            case "clock": fixture.time -= 100
            default: assert(chmod(fixture.store.directory.path, 0o755) == 0)
            }
            assert(fixture.snapshot().unknownSources > 0)
        }

        for invalid in [Data("not json".utf8), Data(repeating: 32, count: 1_048_577),
                        try JSONSerialization.data(withJSONObject: ["session_id": "../escape", "hook_event_name": "SessionStart"])] {
            let fixture = try ClaudeFixture()
            expectFailure { try fixture.report(invalid, process: fixture.identity) }
            assert(fixture.snapshot().unknownSources == 1)
        }
        let missingProcess = try ClaudeFixture()
        expectFailure { try missingProcess.report(JSONSerialization.data(withJSONObject: missingProcess.input("SessionStart")), process: nil) }
        assert(missingProcess.snapshot().unknownSources == 1)
        let report = try ClaudeFixture()
        try report.report(JSONSerialization.data(withJSONObject: report.input("UserPromptSubmit", extra: ["prompt": "PRIVATE_INPUT"])), process: report.identity)
        assert(report.snapshot().activeCount == 1 && report.snapshot().unknownCount == 0)

        let recovery = try ClaudeFixture()
        try recovery.emit("UserPromptSubmit")
        let pending = try recovery.store.beginPending()
        let beforeReset = try FileManager.default.contentsOfDirectory(atPath: recovery.store.directory.path)
        expectFailure { try ClaudeEventReporter.reset(directory: recovery.store.directory) }
        let blockedResetNames = try FileManager.default.contentsOfDirectory(atPath: recovery.store.directory.path)
        assert(Set(blockedResetNames) == Set(beforeReset))
        recovery.store.releasePending(pending) // Simulate reporter termination releasing its marker lock.
        let leftover = recovery.store.directory.appendingPathComponent("temporary-\(UUID().uuidString)")
        let temporary = try recovery.store.checkedFile(leftover.lastPathComponent, flags: O_WRONLY | O_CREAT | O_EXCL)
        close(temporary)
        recovery.native = [recovery.identity]
        try ClaudeEventReporter.reset(directory: recovery.store.directory)
        let resetNames = try FileManager.default.contentsOfDirectory(atPath: recovery.store.directory.path)
        assert(resetNames.isEmpty)
        assert(recovery.snapshot().unknownSources == 1 && recovery.snapshot().observations.isEmpty)
        try recovery.emit("UserPromptSubmit")
        assert(recovery.snapshot().activeCount == 1 && recovery.snapshot().unknownCount == 0)

        for unsafe in ["unknown", "symlink", "link", "mode", "directory"] {
            let fixture = try ClaudeFixture()
            try fixture.emit("SessionStart")
            let url = fixture.recordURL()
            switch unsafe {
            case "unknown": try Data().write(to: fixture.store.directory.appendingPathComponent("unrelated.txt"))
            case "symlink":
                assert(unlink(url.path) == 0)
                assert(symlink(fixture.root.appendingPathComponent("other-app").path, url.path) == 0)
            case "link": assert(link(url.path, fixture.root.appendingPathComponent("other-link").path) == 0)
            case "mode": assert(chmod(url.path, 0o644) == 0)
            default: assert(chmod(fixture.store.directory.path, 0o755) == 0)
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.store.directory.path)
            expectFailure { try ClaudeEventReporter.reset(directory: fixture.store.directory) }
            let remainingNames = try FileManager.default.contentsOfDirectory(atPath: fixture.store.directory.path)
            assert(Set(remainingNames) == Set(names))
        }

        assert(ClaudeProcesses.isNativeCode("/Users/person/.local/share/claude/versions/2.1.292"))
        assert(ClaudeProcesses.isNativeCode("/usr/local/bin/claude"))
        assert(!ClaudeProcesses.isNativeCode("/usr/local/bin/node"))
        assert(!ClaudeProcesses.isNativeCode("/Applications/Claude.app/Contents/MacOS/Claude"))
        assert(!ClaudeProcesses.isNativeCode("/Applications/Claude Copy.app/Contents/MacOS/Claude"))
        assert(!ClaudeProcesses.isPossibleCodeName("browser_crashpad_handler"))
        assert(!ClaudeProcesses.isPossibleCodeName("browser_crashpa")) // Truncated BSD comm must not become a Claude candidate.
        assert(!ClaudeProcesses.isPossibleCodeName("ordinary-app"))
        for name in ["claude", "claude-code", "Claude", "node", "2.1.292", "2.1.292-preview.1", "2.1.292+build"] {
            assert(ClaudeProcesses.isPossibleCodeName(name))
        }
        assert(ClaudeProcesses.isPossibleCodeName(""))
        assert(ClaudeProcesses.isPossibleCodeName(nil))
        assert(ClaudeSessionRecord.validID("abc-123_45.xyz") && !ClaudeSessionRecord.validID(".."))
        print("Claude activity tests passed")
    }
}
