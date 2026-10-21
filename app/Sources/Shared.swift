enum WakePaths {
    static let helperProtocol = 6
    static let bundleID = "nl.local.WakeGuard"
    static let directory = "/var/db/nl.local.WakeGuard"
    static let config = directory + "/config.json"
    static let lease = directory + "/lease.json"
    static let status = directory + "/status.json"
    static let marker = directory + "/owns-sleep"
    static let audit = directory + "/audit.json"
    static let history = directory + "/history.json"
    static let helper = "/Library/PrivilegedHelperTools/nl.local.WakeGuard.helper"
    static let label = "nl.local.WakeGuard"
    static let plist = "/Library/LaunchDaemons/nl.local.WakeGuard.plist"
    static let installedApp = "/Applications/WakeGuard.app"
}

struct WakeSettings: Codable, Equatable {
    var onAC: Bool
    var onBattery: Bool
    var batteryFloor: Int
    // Older helpers require this key; never request display sleep during an update.
    private let darkenDisplays = false
    var sessionMinutes: Int

    init(onAC: Bool = true, onBattery: Bool = false, batteryFloor: Int = 20,
         sessionMinutes: Int = 60) {
        self.onAC = onAC
        self.onBattery = onBattery
        self.batteryFloor = batteryFloor
        self.sessionMinutes = sessionMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case onAC, onBattery, batteryFloor, darkenDisplays, sessionMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(onAC: try values.decode(Bool.self, forKey: .onAC),
                  onBattery: try values.decode(Bool.self, forKey: .onBattery),
                  batteryFloor: try values.decode(Int.self, forKey: .batteryFloor),
                  sessionMinutes: try values.decode(Int.self, forKey: .sessionMinutes))
    }
}

struct WakeRequest: Codable {
    var generation: String
    var session: String
    var sequence: UInt64
    var enabled: Bool
    var issuedAt: Double
    var settings: WakeSettings
    var uninstall: Bool
    var sleepAfterAgents: Bool?

    init(generation: String, session: String, sequence: UInt64, enabled: Bool,
         issuedAt: Double, settings: WakeSettings, uninstall: Bool = false,
         sleepAfterAgents: Bool? = nil) {
        self.generation = generation
        self.session = session
        self.sequence = sequence
        self.enabled = enabled
        self.issuedAt = issuedAt
        self.settings = settings
        self.uninstall = uninstall
        self.sleepAfterAgents = sleepAfterAgents
    }
}

struct HelperStatus: Codable {
    var generation: String
    var session: String?
    var mode: String
    var reason: String
    var onAC: Bool?
    var battery: Int?
    var thermal: String
    var owned: Bool
    var remainingSeconds: Int?
    var updatedAt: Double
    var installerUID: UInt32
    var protocolVersion: Int?
    var lidClosed: Bool?
    var latestSummaryID: String?
    var auditError: String?

    init(generation: String, session: String?, mode: String, reason: String,
         onAC: Bool?, battery: Int?, thermal: String, owned: Bool,
         remainingSeconds: Int?, updatedAt: Double, installerUID: UInt32,
         protocolVersion: Int? = WakePaths.helperProtocol, lidClosed: Bool? = nil,
         latestSummaryID: String? = nil, auditError: String? = nil) {
        self.generation = generation
        self.session = session
        self.mode = mode
        self.reason = reason
        self.onAC = onAC
        self.battery = battery
        self.thermal = thermal
        self.owned = owned
        self.remainingSeconds = remainingSeconds
        self.updatedAt = updatedAt
        self.installerUID = installerUID
        self.protocolVersion = protocolVersion
        self.lidClosed = lidClosed
        self.latestSummaryID = latestSummaryID
        self.auditError = auditError
    }
}

struct InstallConfig: Codable {
    var uid: UInt32
}

enum ThermalLevel: String, Codable {
    case nominal, fair, serious, critical, unknown
}

struct PowerSample {
    var onAC: Bool?
    var battery: Int?
    var thermal: ThermalLevel
}

enum PolicyDecision: Equatable {
    case hold
    case pause(String)
    case stop(String)
}

enum WakePolicy {
    static func evaluate(settings: WakeSettings, power: PowerSample) -> PolicyDecision {
        guard [20, 30, 40].contains(settings.batteryFloor),
              [0, 30, 60, 120].contains(settings.sessionMinutes) else {
            return .stop("Invalid settings")
        }
        guard let onAC = power.onAC else { return .stop("Power source unavailable") }
        switch power.thermal {
        case .serious, .critical: return .stop("Mac is too warm")
        case .unknown: return .stop("Thermal status unavailable")
        case .nominal, .fair: break
        }
        if onAC {
            return settings.onAC ? .hold : .pause("Power adapter disabled")
        }
        guard let battery = power.battery, (0...100).contains(battery) else {
            return .stop("Battery status unavailable")
        }
        guard battery > settings.batteryFloor else { return .stop("Battery below limit") }
        return settings.onBattery ? .hold : .pause("Battery use disabled")
    }

    static func isFresh(_ request: WakeRequest, generation: String, now: Double) -> Bool {
        guard request.generation == generation, !request.session.isEmpty,
              request.session.utf8.count <= 64, request.issuedAt.isFinite, now.isFinite else {
            return false
        }
        let age = now - request.issuedAt
        return age >= -2 && age < 10
    }
}
