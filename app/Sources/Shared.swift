import Foundation

public enum WakePaths {
    public static let appName = "WakeGuard"
    public static let helperProtocol = 5
    public static let bundleID = "nl.local.WakeGuard"
    public static let directory = "/var/db/nl.local.WakeGuard"
    public static let config = directory + "/config.json"
    public static let lease = directory + "/lease.json"
    public static let status = directory + "/status.json"
    public static let marker = directory + "/owns-sleep"
    public static let audit = directory + "/audit.json"
    public static let history = directory + "/history.json"
    public static let helper = "/Library/PrivilegedHelperTools/nl.local.WakeGuard.helper"
    public static let label = "nl.local.WakeGuard"
    public static let plist = "/Library/LaunchDaemons/nl.local.WakeGuard.plist"
    public static let installedApp = "/Applications/WakeGuard.app"
}

public struct WakeSettings: Codable, Equatable {
    public var onAC: Bool
    public var onBattery: Bool
    public var batteryFloor: Int
    public var darkenDisplays: Bool
    public var sessionMinutes: Int

    public init(onAC: Bool = true, onBattery: Bool = false, batteryFloor: Int = 20,
                darkenDisplays: Bool = true, sessionMinutes: Int = 60) {
        self.onAC = onAC
        self.onBattery = onBattery
        self.batteryFloor = batteryFloor
        self.darkenDisplays = darkenDisplays
        self.sessionMinutes = sessionMinutes
    }
}

public struct WakeRequest: Codable {
    public var generation: String
    public var session: String
    public var sequence: UInt64
    public var enabled: Bool
    public var issuedAt: Double
    public var settings: WakeSettings
    public var uninstall: Bool
    public var sleepAfterAgents: Bool?

    public init(generation: String, session: String, sequence: UInt64, enabled: Bool,
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

public struct HelperStatus: Codable {
    public var generation: String
    public var session: String?
    public var mode: String
    public var reason: String
    public var onAC: Bool?
    public var battery: Int?
    public var thermal: String
    public var owned: Bool
    public var remainingSeconds: Int?
    public var updatedAt: Double
    public var installerUID: UInt32
    public var protocolVersion: Int?
    public var lidClosed: Bool?
    public var latestSummaryID: String?
    public var auditError: String?

    public init(generation: String, session: String?, mode: String, reason: String,
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

public struct InstallConfig: Codable {
    public var uid: UInt32

    public init(uid: UInt32) {
        self.uid = uid
    }
}

public enum ThermalLevel: String, Codable {
    case nominal, fair, serious, critical, unknown
}

public struct PowerSample {
    public var onAC: Bool?
    public var battery: Int?
    public var thermal: ThermalLevel

    public init(onAC: Bool?, battery: Int?, thermal: ThermalLevel) {
        self.onAC = onAC
        self.battery = battery
        self.thermal = thermal
    }
}

public enum PolicyDecision: Equatable {
    case hold
    case pause(String)
    case stop(String)
}

public enum WakePolicy {
    public static func evaluate(settings: WakeSettings, power: PowerSample) -> PolicyDecision {
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

    public static func isFresh(_ request: WakeRequest, generation: String, now: Double) -> Bool {
        guard request.generation == generation, !request.session.isEmpty,
              request.session.utf8.count <= 64, request.issuedAt.isFinite, now.isFinite else {
            return false
        }
        let age = now - request.issuedAt
        return age >= -2 && age < 10
    }
}
