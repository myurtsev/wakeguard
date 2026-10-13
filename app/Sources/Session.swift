import Foundation

public struct SessionResult {
    public var mode: String
    public var reason: String
    public var session: String?
    public var remainingSeconds: Int?
    public var shouldHold: Bool
    public var shouldUninstall: Bool
    public var shouldSleep: Bool

    public init(mode: String, reason: String, session: String?, remainingSeconds: Int?,
                shouldHold: Bool, shouldUninstall: Bool = false, shouldSleep: Bool = false) {
        self.mode = mode
        self.reason = reason
        self.session = session
        self.remainingSeconds = remainingSeconds
        self.shouldHold = shouldHold
        self.shouldUninstall = shouldUninstall
        self.shouldSleep = shouldSleep
    }
}

public final class WakeSession {
    private let generation: String
    private var session: String?
    private var sequence: UInt64 = 0
    private var enabled = false
    private var settings = WakeSettings()
    private var startedAt: Double?
    private var leaseUntil: Double?
    private var stoppedReason: String?

    public init(generation: String) {
        self.generation = generation
    }

    public func block(_ reason: String) {
        if enabled { stoppedReason = reason }
    }

    public func step(request: WakeRequest?, power: PowerSample, wallTime: Double,
                     uptime: Double) -> SessionResult {
        guard uptime.isFinite, uptime >= 0 else {
            block("Clock unavailable")
            return result(mode: enabled ? "stopped" : "off", reason: stoppedReason ?? "", uptime: uptime)
        }
        if enabled, stoppedReason == nil {
            if let startedAt, uptime < startedAt {
                block("Clock unavailable")
            } else if let leaseUntil, uptime >= leaseUntil {
                block("App is not responding")
            } else if let remaining = remainingSeconds(at: uptime), remaining == 0 {
                block("Time limit reached")
            }
        }

        if let request, WakePolicy.isFresh(request, generation: generation, now: wallTime) {
            if !request.enabled {
                let shouldSleep = request.sleepAfterAgents == true && !request.uninstall && enabled &&
                    session == request.session && request.sequence > sequence && stoppedReason == nil &&
                    leaseUntil.map { $0.isFinite && uptime < $0 } == true &&
                    WakePolicy.evaluate(settings: settings, power: power) == .hold
                if session != request.session {
                    session = request.session
                    sequence = request.sequence
                } else {
                    sequence = max(sequence, request.sequence)
                }
                enabled = false
                startedAt = nil
                leaseUntil = nil
                stoppedReason = nil
                return result(mode: "off", reason: "", uptime: uptime,
                              uninstall: request.uninstall, sleep: shouldSleep)
            }
            if session != request.session {
                session = request.session
                sequence = request.sequence
                settings = request.settings
                enabled = true
                startedAt = uptime
                leaseUntil = uptime + 10
                stoppedReason = nil
            } else if request.sequence > sequence {
                sequence = request.sequence
                settings = request.settings
                if !enabled {
                    enabled = true
                    startedAt = uptime
                }
                if stoppedReason == nil { leaseUntil = uptime + 10 }
            }
        }
        guard enabled else { return result(mode: "off", reason: "", uptime: uptime) }
        guard let leaseUntil, leaseUntil.isFinite else {
            block("Clock unavailable")
            return result(mode: "stopped", reason: stoppedReason ?? "Clock unavailable", uptime: uptime)
        }
        if let stoppedReason {
            return result(mode: "stopped", reason: stoppedReason, uptime: uptime)
        }
        if let remaining = remainingSeconds(at: uptime), remaining == 0 {
            block("Time limit reached")
            return result(mode: "stopped", reason: "Time limit reached", uptime: uptime)
        }
        switch WakePolicy.evaluate(settings: settings, power: power) {
        case .hold:
            return result(mode: "awake", reason: "", uptime: uptime)
        case .pause(let reason):
            return result(mode: "paused", reason: reason, uptime: uptime)
        case .stop(let reason):
            block(reason)
            return result(mode: "stopped", reason: reason, uptime: uptime)
        }
    }

    private func remainingSeconds(at uptime: Double) -> Int? {
        guard enabled, let startedAt, settings.sessionMinutes > 0,
              [30, 60, 120].contains(settings.sessionMinutes), uptime.isFinite,
              uptime >= startedAt else { return nil }
        return Int(exactly: ceil(max(0, startedAt + Double(settings.sessionMinutes) * 60 - uptime)))
    }

    private func result(mode: String, reason: String, uptime: Double,
                        uninstall: Bool = false, sleep: Bool = false) -> SessionResult {
        SessionResult(mode: mode, reason: reason, session: session,
                      remainingSeconds: remainingSeconds(at: uptime),
                      shouldHold: mode == "awake", shouldUninstall: uninstall, shouldSleep: sleep)
    }
}
