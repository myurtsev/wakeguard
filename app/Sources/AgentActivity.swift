import Foundation

public enum AgentState: String, Codable {
    case working, waiting, idle, ended, unknown

    public var isActive: Bool { self == .working || self == .waiting }
}

public struct AgentObservation: Codable {
    public var id: String
    public var provider: String
    public var state: AgentState
    public var updatedAt: Double

    public init(id: String, provider: String, state: AgentState, updatedAt: Double) {
        self.id = id
        self.provider = provider
        self.state = state
        self.updatedAt = updatedAt
    }
}

public struct AgentSnapshot: Codable {
    public var observations: [AgentObservation]
    public var unknownSources: Int

    public init(observations: [AgentObservation] = [], unknownSources: Int = 0) {
        self.observations = observations
        self.unknownSources = unknownSources
    }

    public var activeCount: Int { observations.filter { $0.state.isActive }.count }
    public var waitingCount: Int { observations.filter { $0.state == .waiting }.count }
    public var unknownCount: Int {
        observations.filter { $0.state == .unknown }.count + max(0, unknownSources)
    }
}

public struct AgentWaiter {
    public private(set) var isArmed = false
    private var trackedIDs = Set<String>()
    private var idleSince: Double?
    private var lastNow: Double?

    public init() {}

    @discardableResult
    public mutating func arm(_ snapshot: AgentSnapshot, now: Double) -> Bool {
        disarm()
        guard now.isFinite, now >= 0, snapshot.activeCount > 0, snapshot.unknownCount == 0 else {
            return false
        }
        trackedIDs = Set(snapshot.observations.filter { $0.state.isActive }.map { $0.id })
        lastNow = now
        isArmed = true
        return true
    }

    public mutating func step(_ snapshot: AgentSnapshot, now: Double) -> Bool {
        guard isArmed else { return false }
        let activeIDs = Set(snapshot.observations.filter { $0.state.isActive }.map { $0.id })
        trackedIDs.formUnion(activeIDs)
        guard now.isFinite, now >= 0 else {
            idleSince = nil
            lastNow = nil
            return false
        }
        if let lastNow, now < lastNow {
            idleSince = nil
            self.lastNow = now
            return false
        }
        lastNow = now
        let finishedIDs = Set(snapshot.observations.filter { $0.state == .idle || $0.state == .ended }.map { $0.id })
        guard snapshot.unknownCount == 0, activeIDs.isEmpty, trackedIDs.isSubset(of: finishedIDs) else {
            idleSince = nil
            return false
        }
        guard let idleSince else {
            self.idleSince = now
            return false
        }
        guard now - idleSince >= 30 else { return false }
        disarm()
        return true
    }

    public mutating func disarm() {
        isArmed = false
        trackedIDs.removeAll()
        idleSince = nil
        lastNow = nil
    }
}
