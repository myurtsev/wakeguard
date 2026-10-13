import Foundation

struct AuditEvent: Codable, Equatable {
    var id: String
    var at: Double
    var kind: String
    var mode: String
    var reason: String
    var session: String?
    var verifiedAwake: Bool
    var lidClosed: Bool?
    var onAC: Bool?
    var battery: Int?
    var thermal: String
    var durationSeconds: Double?
}

struct LidSummary: Codable, Equatable {
    var id: String
    var closedAt: Double
    var openedAt: Double?
    var closedSeconds: Double
    var protectedAwakeSeconds: Double
    var sleepingSeconds: Double
    var unprotectedAwakeSeconds: Double
    var unknownSeconds: Double
    var lastStopReason: String?
    var incomplete: Bool
}

struct AuditHistory: Codable, Equatable {
    var schema: Int = 1
    var generation: String
    var updatedAt: Double
    var retentionAnchor: Double
    var events: [AuditEvent]
    var summaries: [LidSummary]
    var current: LidSummary?

    init(generation: String, updatedAt: Double, events: [AuditEvent] = [],
         summaries: [LidSummary] = [], current: LidSummary? = nil) {
        self.generation = generation
        self.updatedAt = updatedAt
        retentionAnchor = updatedAt
        self.events = events
        self.summaries = summaries
        self.current = current
    }

    func includesSummary(_ id: String?) -> Bool {
        guard let id else { return true }
        return summaries.contains { $0.id == id }
    }

    func shouldPresentSummary(_ summary: LidSummary) -> Bool {
        guard let openedAt = summary.openedAt else { return false }
        if summary.protectedAwakeSeconds > 0 { return true }
        return events.contains {
            $0.verifiedAwake && $0.mode == "awake" && $0.lidClosed == true &&
                $0.at >= summary.closedAt && $0.at <= openedAt
        }
    }
}

enum AuditError: LocalizedError {
    case invalid
    case unavailable
    case system

    var errorDescription: String? {
        switch self {
        case .invalid: return "Activity history is invalid or unsafe"
        case .unavailable: return "Activity history is not available yet"
        case .system: return "Could not read activity history"
        }
    }
}

enum AuditFormat {
    static let retentionSeconds = 7.0 * 24 * 60 * 60
    static let maximumEvents = 512
    static let maximumSummaries = 64
    static let maximumBytes = 256 * 1024
    static let kinds: Set<String> = ["helper_start", "helper_recovered", "recovery", "state_changed",
        "lid_closed", "lid_opened", "lid_unknown", "sleep_observed", "agent_sleep_requested",
        "error", "stop", "audit_reset"]
    static let modes: Set<String> = ["off", "awake", "paused", "error", "stopped"]

    static func validate(_ history: AuditHistory) throws {
        guard history.schema == 1, UUID(uuidString: history.generation) != nil,
              validTime(history.updatedAt), validTime(history.retentionAnchor),
              history.events.count <= maximumEvents, history.summaries.count <= maximumSummaries else {
            throw AuditError.invalid
        }
        for event in history.events {
            guard UUID(uuidString: event.id) != nil, validTime(event.at), kinds.contains(event.kind),
                  modes.contains(event.mode), event.reason.utf8.count <= 256,
                  event.session.map({ $0.utf8.count <= 64 }) ?? true,
                  event.battery.map({ (0...100).contains($0) }) ?? true,
                  ThermalLevel(rawValue: event.thermal) != nil,
                  event.durationSeconds.map(validDuration) ?? true else {
                throw AuditError.invalid
            }
        }
        for summary in history.summaries + (history.current.map { [$0] } ?? []) {
            let parts = [summary.protectedAwakeSeconds, summary.sleepingSeconds,
                         summary.unprotectedAwakeSeconds, summary.unknownSeconds]
            guard UUID(uuidString: summary.id) != nil, validTime(summary.closedAt),
                  summary.openedAt.map(validTime) ?? true,
                  validDuration(summary.closedSeconds), parts.allSatisfy(validDuration),
                  abs(parts.reduce(0, +) - summary.closedSeconds) <= 0.01,
                  summary.lastStopReason.map({ $0.utf8.count <= 256 }) ?? true else {
                throw AuditError.invalid
            }
        }
        guard history.summaries.allSatisfy({ $0.openedAt != nil }), history.current?.openedAt == nil else {
            throw AuditError.invalid
        }
        let summaryIDs = history.summaries.map(\.id) + (history.current.map { [$0.id] } ?? [])
        guard Set(history.events.map(\.id)).count == history.events.count,
              Set(summaryIDs).count == summaryIDs.count,
              let encoded = try? JSONEncoder().encode(history), encoded.count <= maximumBytes else {
            throw AuditError.invalid
        }
    }

    private static func validTime(_ value: Double) -> Bool { value.isFinite && value >= 0 && value < 1e12 }
    fileprivate static func validDuration(_ value: Double) -> Bool { value.isFinite && value >= 0 && value < 1e12 }
}

private func auditText(_ text: String, maximum: Int = 256) -> String {
    var result = String(text.prefix(maximum))
    while result.utf8.count > maximum { result.removeLast() }
    return result
}

final class AuditTracker {
    private(set) var history: AuditHistory
    private(set) var lidClosed: Bool?
    private(set) var revision: UInt64 = 1
    var latestSummaryID: String? { history.summaries.last?.id }
    var needsWrite: Bool {
        dirty || (history.current != nil && currentContinuous.isFinite && lastWriteContinuous.isFinite &&
                  currentContinuous - lastWriteContinuous >= 30)
    }

    private struct Sample {
        var lid: Bool?
        var continuous: Double
        var absolute: Double
        var mode: String
        var reason: String
        var session: String?
        var verifiedAwake: Bool
        var onAC: Bool?
        var thermal: String

        func sameState(as other: Sample) -> Bool {
            lid == other.lid && mode == other.mode && reason == other.reason && session == other.session &&
                verifiedAwake == other.verifiedAwake && onAC == other.onAC &&
                thermal == other.thermal
        }
    }

    private var previous: Sample?
    private var dirty = true
    private var lastWriteContinuous: Double
    private var currentContinuous: Double

    init(history existing: AuditHistory? = nil, generation: String,
         continuous: Double, wallTime: Double) {
        let safeWall = wallTime.isFinite && wallTime >= 0 && wallTime < 1e12 ? wallTime : 0
        if let existing, (try? AuditFormat.validate(existing)) != nil {
            history = existing
            // A helper restart has no observations for the gap, even on the same boot.
            if history.current != nil {
                history.current!.incomplete = true
                let gap = safeWall - existing.updatedAt
                if gap >= 0 && gap <= AuditFormat.retentionSeconds {
                    // Wall time supplies only an unknown estimate; confirmed durations never use it.
                    history.current!.closedSeconds += gap
                    history.current!.unknownSeconds += gap
                }
            }
        } else {
            history = AuditHistory(generation: generation, updatedAt: safeWall)
        }
        history.generation = generation
        history.updatedAt = safeWall
        currentContinuous = continuous
        lastWriteContinuous = continuous
        prune(at: safeWall)
    }

    func sample(lidClosed: Bool?, continuous: Double, absolute: Double, wallTime: Double,
                mode: String, reason: String, session: String?, verifiedAwake: Bool, power: PowerSample) {
        let safeMode = AuditFormat.modes.contains(mode) ? mode : "error"
        let state = Sample(lid: lidClosed, continuous: continuous, absolute: absolute, mode: safeMode,
                           reason: auditText(reason), session: session.map { auditText($0, maximum: 64) },
                           verifiedAwake: verifiedAwake && mode == "awake", onAC: power.onAC,
                           thermal: power.thermal.rawValue)
        self.lidClosed = lidClosed
        currentContinuous = continuous
        let validClock = continuous.isFinite && absolute.isFinite && continuous >= 0 && absolute >= 0
        if let previous, history.current != nil {
            let elapsed = continuous - previous.continuous
            let active = absolute - previous.absolute
            if validClock && previous.continuous.isFinite && previous.absolute.isFinite &&
                elapsed >= 0 && active >= 0 && active <= elapsed + 0.01 {
                let awake = min(active, elapsed)
                let sleeping = max(0, elapsed - awake)
                history.current!.closedSeconds += elapsed
                if previous.lid == nil {
                    history.current!.unknownSeconds += elapsed
                    markIncomplete()
                } else {
                    history.current!.sleepingSeconds += sleeping
                    if awake > 5 {
                        history.current!.unknownSeconds += awake
                        markIncomplete()
                    } else if previous.verifiedAwake && previous.mode == "awake" {
                        history.current!.protectedAwakeSeconds += awake
                    } else {
                        history.current!.unprotectedAwakeSeconds += awake
                    }
                }
            } else {
                markIncomplete()
            }
        }
        if let previous, validClock, previous.continuous.isFinite, previous.absolute.isFinite {
            let elapsed = continuous - previous.continuous
            let active = absolute - previous.absolute
            if elapsed >= 0 && active >= 0 && active <= elapsed + 0.01 && elapsed - active >= 0.1 {
                record(kind: "sleep_observed", wallTime: wallTime, mode: mode, reason: reason,
                       session: session, verifiedAwake: verifiedAwake, lidClosed: lidClosed,
                       power: power, durationSeconds: elapsed - active)
            }
        }

        if lidClosed == true && history.current == nil {
            history.current = LidSummary(id: UUID().uuidString, closedAt: safeWall(wallTime), openedAt: nil,
                closedSeconds: 0, protectedAwakeSeconds: 0, sleepingSeconds: 0,
                unprotectedAwakeSeconds: 0, unknownSeconds: 0, lastStopReason: nil,
                incomplete: !validClock || previous?.lid != false)
        } else if lidClosed == false, var summary = history.current {
            summary.openedAt = safeWall(wallTime)
            history.summaries.append(summary)
            history.current = nil
        }
        if history.current != nil && lidClosed == nil { markIncomplete() }
        if history.current != nil && ["off", "stopped", "error", "paused"].contains(mode) && !reason.isEmpty {
            history.current!.lastStopReason = auditText(reason)
        }

        if previous == nil || !state.sameState(as: previous!) {
            let kind: String
            if previous != nil && previous?.lid != lidClosed {
                kind = lidClosed.map { $0 ? "lid_closed" : "lid_opened" } ?? "lid_unknown"
            } else if previous == nil && lidClosed == true {
                kind = "lid_closed"
            } else { kind = "state_changed" }
            record(kind: kind, wallTime: wallTime, mode: mode, reason: reason, session: session,
                   verifiedAwake: verifiedAwake, lidClosed: lidClosed, power: power)
        }
        previous = state
        history.updatedAt = safeWall(wallTime)
        prune(at: history.updatedAt)
    }

    func record(kind: String, wallTime: Double, mode: String, reason: String,
                session: String?, verifiedAwake: Bool, lidClosed: Bool?, power: PowerSample,
                durationSeconds: Double? = nil) {
        guard AuditFormat.kinds.contains(kind),
              durationSeconds.map(AuditFormat.validDuration) ?? true else {
            return
        }
        let event = AuditEvent(id: UUID().uuidString, at: safeWall(wallTime), kind: kind, mode: mode,
            reason: auditText(reason), session: session.map { auditText($0, maximum: 64) }, verifiedAwake: verifiedAwake && mode == "awake",
            lidClosed: lidClosed, onAC: power.onAC,
            battery: power.battery.flatMap { (0...100).contains($0) ? $0 : nil }, thermal: power.thermal.rawValue,
            durationSeconds: durationSeconds)
        var checkedEvent = event
        if !AuditFormat.modes.contains(mode) { checkedEvent.mode = "error" }
        history.events.append(checkedEvent)
        history.updatedAt = event.at
        markDirty()
        prune(at: event.at)
    }

    func didWrite(continuous: Double, revision writtenRevision: UInt64? = nil) {
        guard continuous.isFinite && continuous >= 0 else { return }
        lastWriteContinuous = continuous
        if writtenRevision == nil || writtenRevision == revision { dirty = false }
    }

    private func markDirty() {
        dirty = true
        revision &+= 1
    }

    private func markIncomplete() {
        guard history.current != nil, !history.current!.incomplete else { return }
        history.current!.incomplete = true
        markDirty()
    }

    private func safeWall(_ wall: Double) -> Double {
        wall.isFinite && wall >= 0 && wall < 1e12 ? wall : history.updatedAt
    }

    private func prune(at wall: Double) {
        history.retentionAnchor = max(history.retentionAnchor, wall)
        let cutoff = history.retentionAnchor - AuditFormat.retentionSeconds
        let oldEvents = history.events.count, oldSummaries = history.summaries.count
        history.events.removeAll { $0.at < cutoff }
        history.summaries.removeAll { ($0.openedAt ?? $0.closedAt) < cutoff }
        if history.events.count > AuditFormat.maximumEvents {
            history.events.removeFirst(history.events.count - AuditFormat.maximumEvents)
        }
        if history.summaries.count > AuditFormat.maximumSummaries {
            history.summaries.removeFirst(history.summaries.count - AuditFormat.maximumSummaries)
        }
        while let encoded = try? JSONEncoder().encode(history), encoded.count > AuditFormat.maximumBytes {
            if let event = history.events.first,
               history.summaries.first.map({ event.at <= ($0.openedAt ?? $0.closedAt) }) ?? true {
                history.events.removeFirst(max(1, history.events.count / 8))
            } else if !history.summaries.isEmpty {
                history.summaries.removeFirst(max(1, history.summaries.count / 8))
            } else { break }
        }
        if history.events.count != oldEvents || history.summaries.count != oldSummaries { markDirty() }
    }
}
