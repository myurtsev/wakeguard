enum AgentState: String, Codable {
    case working, waiting, idle, ended, unknown

    var isActive: Bool { self == .working || self == .waiting }
}

struct AgentObservation: Codable {
    let id: String
    let provider: String
    let state: AgentState
    let updatedAt: Double
}

struct AgentSnapshot: Codable {
    var observations: [AgentObservation]
    var unknownSources: Int

    init(observations: [AgentObservation] = [], unknownSources: Int = 0) {
        self.observations = observations
        self.unknownSources = unknownSources
    }

    var activeCount: Int { observations.filter { $0.state.isActive }.count }
    var waitingCount: Int { observations.filter { $0.state == .waiting }.count }
    var unknownCount: Int {
        observations.filter { $0.state == .unknown }.count + max(0, unknownSources)
    }
}

struct AgentWaiter {
    private(set) var isArmed = false
    private var trackedIDs = Set<String>()
    private var idleSince: Double?
    private var lastNow: Double?

    @discardableResult
    mutating func arm(_ snapshot: AgentSnapshot, now: Double) -> Bool {
        disarm()
        guard now.isFinite, now >= 0, snapshot.activeCount > 0, snapshot.unknownCount == 0 else {
            return false
        }
        trackedIDs = Set(snapshot.observations.filter { $0.state.isActive }.map { $0.id })
        lastNow = now
        isArmed = true
        return true
    }

    mutating func step(_ snapshot: AgentSnapshot, now: Double) -> Bool {
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

    mutating func disarm() {
        isArmed = false
        trackedIDs.removeAll()
        idleSince = nil
        lastNow = nil
    }
}
