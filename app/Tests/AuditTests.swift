import Foundation
import Darwin

@main
enum AuditTests {
    static let power = PowerSample(onAC: true, battery: 80, thermal: .nominal)
    static let generation = UUID().uuidString

    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Invalid audit input accepted") } catch {}
    }

    static func near(_ value: Double, _ expected: Double) { assert(abs(value - expected) < 0.001) }

    static func tracker(history: AuditHistory? = nil, wall: Double = 1_000) -> AuditTracker {
        AuditTracker(history: history, generation: generation, continuous: 100, absolute: 50, wallTime: wall)
    }

    static func sample(_ tracker: AuditTracker, lid: Bool?, at: Double, active: Double? = nil,
                       wall: Double? = nil, mode: String = "awake", verified: Bool = true,
                       reason: String = "", power samplePower: PowerSample? = nil) {
        tracker.sample(lidClosed: lid, continuous: 100 + at, absolute: 50 + (active ?? at),
                       wallTime: wall ?? 1_000 + at, mode: mode, reason: reason, session: nil,
                       verifiedAwake: verified, power: samplePower ?? power)
    }

    static func main() throws {
        let awake = tracker()
        sample(awake, lid: false, at: 0)
        sample(awake, lid: true, at: 0)
        awake.didWrite(continuous: 100)
        assert(!awake.needsWrite && awake.lidClosed == true && awake.latestSummaryID == nil)
        for second in 1...29 { sample(awake, lid: true, at: Double(second)) }
        assert(!awake.needsWrite)
        sample(awake, lid: true, at: 30)
        assert(awake.needsWrite)
        awake.didWrite(continuous: 130)
        sample(awake, lid: false, at: 31)
        let complete = awake.history.summaries.last!
        near(complete.closedSeconds, 31)
        near(complete.protectedAwakeSeconds, 31)
        near(complete.sleepingSeconds, 0)
        assert(!complete.incomplete && complete.openedAt == 1_031)
        assert(awake.latestSummaryID == complete.id && awake.history.current == nil)
        assert(awake.history.events.filter { $0.kind == "lid_closed" }.count == 1)
        assert(awake.history.events.filter { $0.kind == "lid_opened" }.count == 1)
        assert(awake.history.shouldPresentSummary(complete))
        try AuditFormat.validate(awake.history)

        let offOnly = tracker()
        sample(offOnly, lid: false, at: 0, mode: "off", verified: false)
        sample(offOnly, lid: true, at: 1, mode: "off", verified: false)
        sample(offOnly, lid: false, at: 2, mode: "off", verified: false)
        assert(!offOnly.history.shouldPresentSummary(offOnly.history.summaries.last!))

        let usedThenStopped = tracker()
        sample(usedThenStopped, lid: false, at: 0)
        sample(usedThenStopped, lid: true, at: 1)
        sample(usedThenStopped, lid: true, at: 2, mode: "off", verified: false, reason: "Stopped")
        sample(usedThenStopped, lid: false, at: 3, mode: "off", verified: false)
        assert(usedThenStopped.history.shouldPresentSummary(usedThenStopped.history.summaries.last!))

        let usedAcrossGap = tracker()
        sample(usedAcrossGap, lid: false, at: 0)
        sample(usedAcrossGap, lid: true, at: 1)
        sample(usedAcrossGap, lid: true, at: 61, mode: "off", verified: false, reason: "Stopped")
        sample(usedAcrossGap, lid: false, at: 62, mode: "off", verified: false)
        near(usedAcrossGap.history.summaries.last!.protectedAwakeSeconds, 0)
        near(usedAcrossGap.history.summaries.last!.unknownSeconds, 60)
        assert(usedAcrossGap.history.shouldPresentSummary(usedAcrossGap.history.summaries.last!))

        let adjacentUse = tracker()
        sample(adjacentUse, lid: false, at: 0)
        sample(adjacentUse, lid: true, at: 0, mode: "off", verified: false)
        sample(adjacentUse, lid: false, at: 0, mode: "off", verified: false)
        sample(adjacentUse, lid: false, at: 0)
        near(adjacentUse.history.summaries.last!.protectedAwakeSeconds, 0)
        assert(adjacentUse.history.events.contains { $0.verifiedAwake })
        assert(!adjacentUse.history.shouldPresentSummary(adjacentUse.history.summaries.last!))

        let batteryContext = tracker()
        let onBattery = PowerSample(onAC: false, battery: 40, thermal: .nominal)
        sample(batteryContext, lid: false, at: 0, mode: "off", verified: false, power: onBattery)
        batteryContext.didWrite(continuous: 100)
        let eventCount = batteryContext.history.events.count
        let revision = batteryContext.revision
        sample(batteryContext, lid: false, at: 1, mode: "off", verified: false,
               power: PowerSample(onAC: false, battery: 39, thermal: .nominal))
        sample(batteryContext, lid: false, at: 2, mode: "off", verified: false, power: onBattery)
        assert(batteryContext.history.events.count == eventCount && batteryContext.revision == revision)
        assert(!batteryContext.needsWrite)
        sample(batteryContext, lid: false, at: 3, mode: "stopped", verified: false, reason: "Battery too low",
               power: PowerSample(onAC: false, battery: 20, thermal: .nominal))
        assert(batteryContext.history.events.count == eventCount + 1)
        assert(batteryContext.history.events.last!.reason == "Battery too low")
        assert(batteryContext.history.events.last!.battery == 20)
        sample(batteryContext, lid: false, at: 4, mode: "stopped", verified: false, reason: "Battery too low",
               power: PowerSample(onAC: true, battery: 21, thermal: .nominal))
        assert(batteryContext.history.events.last!.onAC == true && batteryContext.history.events.last!.battery == 21)

        let initiallyClosed = tracker()
        sample(initiallyClosed, lid: true, at: 0)
        sample(initiallyClosed, lid: false, at: 1)
        assert(initiallyClosed.history.summaries.last!.incomplete)
        near(initiallyClosed.history.summaries.last!.protectedAwakeSeconds, 1)

        let uncertainClose = tracker()
        sample(uncertainClose, lid: nil, at: 0)
        sample(uncertainClose, lid: true, at: 1)
        let pendingSnapshot = uncertainClose.history
        assert(pendingSnapshot.includesSummary(nil))
        sample(uncertainClose, lid: false, at: 2)
        let newSummaryID = uncertainClose.latestSummaryID!
        assert(uncertainClose.history.summaries.last!.incomplete)
        assert(!pendingSnapshot.includesSummary(newSummaryID))
        assert(uncertainClose.history.includesSummary(newSummaryID))

        let sleeping = tracker()
        sample(sleeping, lid: false, at: 0)
        sample(sleeping, lid: true, at: 0)
        sample(sleeping, lid: true, at: 2, mode: "off", verified: false)
        sleeping.record(kind: "agent_sleep_requested", wallTime: 1_002, mode: "off", reason: "Agents finished",
                        session: nil, verifiedAwake: false, lidClosed: true, power: power)
        sample(sleeping, lid: true, at: 2, mode: "off", verified: false, reason: "Agents finished")
        assert(!sleeping.history.events.contains { $0.kind == "sleep_observed" })
        sample(sleeping, lid: true, at: 602, active: 4, mode: "off", verified: false)
        sample(sleeping, lid: false, at: 604, active: 6, mode: "off", verified: false)
        let sleepSummary = sleeping.history.summaries.last!
        near(sleepSummary.closedSeconds, 604)
        near(sleepSummary.protectedAwakeSeconds, 2)
        near(sleepSummary.sleepingSeconds, 598)
        near(sleepSummary.unprotectedAwakeSeconds, 4)
        assert(!sleepSummary.incomplete)
        assert(sleepSummary.lastStopReason == "Agents finished")
        near(sleeping.history.events.first { $0.kind == "sleep_observed" }!.durationSeconds!, 598)

        let darkWakes = tracker()
        sample(darkWakes, lid: true, at: 0, mode: "off", verified: false)
        sample(darkWakes, lid: true, at: 100, active: 2, mode: "off", verified: false)
        sample(darkWakes, lid: true, at: 102, active: 4, mode: "off", verified: false)
        sample(darkWakes, lid: true, at: 500, active: 6, mode: "off", verified: false)
        assert(darkWakes.latestSummaryID == nil)
        sample(darkWakes, lid: false, at: 502, active: 8, mode: "off", verified: false)
        near(darkWakes.history.summaries.last!.sleepingSeconds, 494)
        near(darkWakes.history.summaries.last!.unprotectedAwakeSeconds, 8)
        assert(darkWakes.history.events.filter { $0.kind == "sleep_observed" }.count == 2)
        let openSleep = tracker()
        sample(openSleep, lid: false, at: 0, mode: "off", verified: false)
        sample(openSleep, lid: false, at: 20, active: 1, mode: "off", verified: false)
        assert(openSleep.history.current == nil && openSleep.history.summaries.isEmpty)
        near(openSleep.history.events.first { $0.kind == "sleep_observed" }!.durationSeconds!, 19)

        let stalled = tracker()
        sample(stalled, lid: true, at: 0)
        sample(stalled, lid: false, at: 60)
        near(stalled.history.summaries.last!.sleepingSeconds, 0)
        near(stalled.history.summaries.last!.unknownSeconds, 60)
        assert(stalled.history.summaries.last!.incomplete)
        assert(!stalled.history.events.contains { $0.kind == "sleep_observed" })

        let unknown = tracker()
        sample(unknown, lid: true, at: 0)
        sample(unknown, lid: nil, at: 1)
        sample(unknown, lid: nil, at: 5)
        assert(unknown.history.current != nil && unknown.latestSummaryID == nil && unknown.lidClosed == nil)
        sample(unknown, lid: false, at: 6)
        near(unknown.history.summaries.last!.unknownSeconds, 5)
        near(unknown.history.summaries.last!.protectedAwakeSeconds, 1)
        assert(unknown.history.summaries.last!.incomplete)

        let paused = tracker()
        sample(paused, lid: true, at: 0, mode: "paused", verified: false, reason: "Battery use disabled")
        sample(paused, lid: false, at: 3, mode: "paused", verified: false, reason: "Battery use disabled")
        near(paused.history.summaries.last!.unprotectedAwakeSeconds, 3)
        assert(paused.history.summaries.last!.lastStopReason == "Battery use disabled")

        let jumps = tracker()
        sample(jumps, lid: true, at: 0)
        sample(jumps, lid: true, at: 1, wall: 800)
        sample(jumps, lid: false, at: 2, wall: 2_000)
        near(jumps.history.summaries.last!.protectedAwakeSeconds, 2)
        near(jumps.history.summaries.last!.closedSeconds, 2)

        let pendingWrite = tracker()
        sample(pendingWrite, lid: true, at: 0)
        let capturedRevision = pendingWrite.revision
        sample(pendingWrite, lid: true, at: 1)
        assert(pendingWrite.revision == capturedRevision)
        sample(pendingWrite, lid: true, at: 2, mode: "paused", verified: false, reason: "Power adapter disabled")
        assert(pendingWrite.revision != capturedRevision)
        pendingWrite.didWrite(continuous: 100, revision: capturedRevision)
        assert(pendingWrite.needsWrite)
        pendingWrite.didWrite(continuous: 102, revision: pendingWrite.revision)
        assert(!pendingWrite.needsWrite)

        let original = tracker()
        sample(original, lid: true, at: 0)
        sample(original, lid: true, at: 1)
        let restarted = tracker(history: original.history, wall: 1_021)
        near(restarted.history.current!.unknownSeconds, 20)
        assert(restarted.history.current!.incomplete && restarted.needsWrite)
        sample(restarted, lid: false, at: 0, wall: 1_021, mode: "off", verified: false)
        near(restarted.history.summaries.last!.closedSeconds, 21)
        near(restarted.history.summaries.last!.protectedAwakeSeconds, 1)
        let backwardRestart = tracker(history: original.history, wall: 800)
        near(backwardRestart.history.current!.unknownSeconds, 0)
        assert(backwardRestart.history.current!.incomplete)
        let hugeRestart = tracker(history: original.history, wall: 1_001 + AuditFormat.retentionSeconds + 1)
        near(hugeRestart.history.current!.unknownSeconds, 0)

        let badClock = tracker()
        sample(badClock, lid: true, at: 0)
        sample(badClock, lid: true, at: 1, active: 10)
        sample(badClock, lid: false, at: 2, active: 11)
        assert(badClock.history.summaries.last!.incomplete)
        near(badClock.history.summaries.last!.protectedAwakeSeconds, 1)
        try AuditFormat.validate(badClock.history)

        let retained = tracker()
        for index in 0..<600 {
            retained.record(kind: "error", wallTime: 1_000 + Double(index), mode: "error",
                            reason: String(repeating: "🔥", count: 300), session: String(repeating: "x", count: 100),
                            verifiedAwake: false, lidClosed: false, power: power)
        }
        assert(retained.history.events.count <= 512)
        assert(retained.history.events.allSatisfy { $0.reason.utf8.count <= 256 && $0.session!.utf8.count <= 64 })
        let boundedData = try JSONEncoder().encode(retained.history)
        assert(boundedData.count <= AuditFormat.maximumBytes)
        retained.record(kind: "helper_start", wallTime: 1_600 + AuditFormat.retentionSeconds,
                        mode: "off", reason: "", session: nil, verifiedAwake: false, lidClosed: false, power: power)
        assert(retained.history.events.count == 1)
        try AuditFormat.validate(retained.history)
        let summaryLimit = tracker()
        for index in 0..<70 {
            sample(summaryLimit, lid: true, at: Double(index * 2))
            sample(summaryLimit, lid: false, at: Double(index * 2 + 1))
        }
        assert(summaryLimit.history.summaries.count == 64)

        var invalid = awake.history
        invalid.schema = 99
        rejects { try AuditFormat.validate(invalid) }
        assert(tracker(history: invalid).history.events.isEmpty)
        invalid = awake.history
        invalid.summaries[0].protectedAwakeSeconds = -1
        rejects { try AuditFormat.validate(invalid) }
        invalid = awake.history
        invalid.events[0].durationSeconds = .nan
        rejects { try AuditFormat.validate(invalid) }
        invalid = awake.history
        invalid.events.append(invalid.events[0])
        rejects { try AuditFormat.validate(invalid) }

        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("audit-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode(awake.history).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let roundTrip = try AuditClient.readHistory(path: file.path, owner: getuid())
        assert(roundTrip == awake.history)
        rejects { _ = try AuditClient.readHistory(path: file.path, owner: getuid() + 1) }
        let symlink = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        rejects { _ = try AuditClient.readHistory(path: symlink.path, owner: getuid()) }
        let fifo = directory.appendingPathComponent("fifo")
        assert(mkfifo(fifo.path, 0o600) == 0)
        rejects { _ = try AuditClient.readHistory(path: fifo.path, owner: getuid()) }
        let hardlink = directory.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: file, to: hardlink)
        rejects { _ = try AuditClient.readHistory(path: file.path, owner: getuid()) }
        try FileManager.default.removeItem(at: hardlink)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        rejects { _ = try AuditClient.readHistory(path: file.path, owner: getuid()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data(repeating: 0, count: AuditFormat.maximumBytes + 1).write(to: file)
        rejects { _ = try AuditClient.readHistory(path: file.path, owner: getuid()) }
        try Data("{bad".utf8).write(to: file)
        rejects { _ = try AuditClient.readHistory(path: file.path, owner: getuid()) }
        print("Audit timing, retention and IPC checks passed")
    }
}
