import Foundation

@main
enum PolicyTests {
    static func main() throws {
        let defaults = WakeSettings()
        assert(defaults == WakeSettings(onAC: true, onBattery: false, batteryFloor: 20, sessionMinutes: 60))
        let storedSettings = WakeSettings(onAC: false, onBattery: true, batteryFloor: 40, sessionMinutes: 120)
        let storedData = try JSONEncoder().encode(storedSettings)
        var legacySettings = try JSONSerialization.jsonObject(with: storedData) as! [String: Any]
        let oldHelperSettings = try JSONDecoder().decode(LegacyWakeSettings.self, from: storedData)
        assert(!oldHelperSettings.darkenDisplays)
        assert(!oldHelperSettings.onAC && oldHelperSettings.onBattery)
        assert(oldHelperSettings.batteryFloor == 40 && oldHelperSettings.sessionMinutes == 120)
        for displaySleep: Bool? in [true, false, nil] {
            legacySettings["darkenDisplays"] = displaySleep
            let data = try JSONSerialization.data(withJSONObject: legacySettings)
            let migrated = try JSONDecoder().decode(WakeSettings.self, from: data)
            assert(migrated == storedSettings)
            let encoded = try JSONDecoder().decode(LegacyWakeSettings.self, from: JSONEncoder().encode(migrated))
            assert(!encoded.darkenDisplays)
        }
        let ac = PowerSample(onAC: true, battery: nil, thermal: .nominal)
        assert(WakePolicy.evaluate(settings: defaults, power: ac) == .hold)
        for battery in [-1, 0, 20, 101] {
            assert(WakePolicy.evaluate(settings: defaults,
                power: PowerSample(onAC: true, battery: battery, thermal: .fair)) == .hold)
        }
        assert(WakePolicy.evaluate(settings: WakeSettings(onAC: false), power: ac)
               == .pause("Power adapter disabled"))

        let batterySettings = WakeSettings(onBattery: true)
        for floor in [20, 30, 40] {
            let settings = WakeSettings(onBattery: true, batteryFloor: floor)
            for battery in [0, floor - 1, floor] {
                assert(WakePolicy.evaluate(settings: settings,
                    power: PowerSample(onAC: false, battery: battery, thermal: .nominal))
                       == .stop("Battery below limit"))
            }
            for battery in [floor + 1, 100] {
                assert(WakePolicy.evaluate(settings: settings,
                    power: PowerSample(onAC: false, battery: battery, thermal: .fair)) == .hold)
            }
        }
        assert(WakePolicy.evaluate(settings: defaults,
            power: PowerSample(onAC: false, battery: 80, thermal: .nominal))
               == .pause("Battery use disabled"))
        for battery: Int? in [nil, -1, 101] {
            assert(WakePolicy.evaluate(settings: batterySettings,
                power: PowerSample(onAC: false, battery: battery, thermal: .nominal))
                   == .stop("Battery status unavailable"))
        }
        assert(WakePolicy.evaluate(settings: defaults,
            power: PowerSample(onAC: nil, battery: 80, thermal: .nominal))
               == .stop("Power source unavailable"))
        for onAC in [true, false] {
            for thermal in [ThermalLevel.serious, .critical] {
                assert(WakePolicy.evaluate(settings: batterySettings,
                    power: PowerSample(onAC: onAC, battery: 80, thermal: thermal))
                       == .stop("Mac is too warm"))
            }
            assert(WakePolicy.evaluate(settings: batterySettings,
                power: PowerSample(onAC: onAC, battery: 80, thermal: .unknown))
                   == .stop("Thermal status unavailable"))
        }
        for minutes in [0, 30, 60, 120] {
            assert(WakePolicy.evaluate(settings: WakeSettings(sessionMinutes: minutes), power: ac) == .hold)
        }
        for minutes in [-1, 1, 29, 31, 59, 61, 119, 121, Int.max] {
            assert(WakePolicy.evaluate(settings: WakeSettings(sessionMinutes: minutes), power: ac)
                   == .stop("Invalid settings"))
        }
        for floor in [-1, 0, 19, 21, 29, 31, 39, 41, 100, Int.max] {
            assert(WakePolicy.evaluate(settings: WakeSettings(batteryFloor: floor), power: ac)
                   == .stop("Invalid settings"))
        }

        let now = 1_000.0
        func request(at: Double = 1_000, generation: String = "generation", session: String = "session") -> WakeRequest {
            WakeRequest(generation: generation, session: session, sequence: 1, enabled: true,
                        issuedAt: at, settings: defaults)
        }
        for issuedAt in [now, now + 2, now - 9.999] {
            assert(WakePolicy.isFresh(request(at: issuedAt), generation: "generation", now: now))
        }
        for issuedAt in [now + 2.001, now - 10, now - 11, Double.nan, .infinity, -.infinity] {
            assert(!WakePolicy.isFresh(request(at: issuedAt), generation: "generation", now: now))
        }
        for invalidNow in [Double.nan, .infinity, -.infinity] {
            assert(!WakePolicy.isFresh(request(), generation: "generation", now: invalidNow))
        }
        assert(!WakePolicy.isFresh(request(generation: "old-generation"), generation: "generation", now: now))
        assert(!WakePolicy.isFresh(request(session: ""), generation: "generation", now: now))
        assert(WakePolicy.isFresh(request(session: String(repeating: "a", count: 64)), generation: "generation", now: now))
        assert(!WakePolicy.isFresh(request(session: String(repeating: "a", count: 65)), generation: "generation", now: now))
        assert(WakePolicy.isFresh(request(session: String(repeating: "é", count: 32)), generation: "generation", now: now))
        assert(!WakePolicy.isFresh(request(session: String(repeating: "é", count: 33)), generation: "generation", now: now))

        let encodedRequest = try JSONEncoder().encode(request())
        let decodedRequest = try JSONDecoder().decode(WakeRequest.self, from: encodedRequest)
        assert(decodedRequest.generation == "generation" && decodedRequest.session == "session")
        assert(decodedRequest.sequence == 1 && decodedRequest.enabled && !decodedRequest.uninstall)
        assert(decodedRequest.settings == defaults && decodedRequest.issuedAt == now)
        let oldHelperRequest = try JSONDecoder().decode(LegacySettingsRequest.self, from: encodedRequest)
        assert(!oldHelperRequest.settings.darkenDisplays)
        let removal = WakeRequest(generation: "generation", session: "session", sequence: 2,
                                  enabled: false, issuedAt: now, settings: storedSettings, uninstall: true)
        let oldHelperRemoval = try JSONDecoder().decode(LegacySettingsRequest.self, from: JSONEncoder().encode(removal))
        assert(!oldHelperRemoval.enabled && oldHelperRemoval.uninstall && !oldHelperRemoval.settings.darkenDisplays)
        var legacyRequest = try JSONSerialization.jsonObject(with: encodedRequest) as! [String: Any]
        legacySettings["darkenDisplays"] = true
        legacyRequest["settings"] = legacySettings
        let oldAppRequest = try JSONDecoder().decode(WakeRequest.self, from: JSONSerialization.data(withJSONObject: legacyRequest))
        assert(oldAppRequest.settings == storedSettings)
        assert(oldAppRequest.generation == decodedRequest.generation && oldAppRequest.enabled == decodedRequest.enabled)
        let status = HelperStatus(generation: "generation", session: nil, mode: "idle", reason: "",
                                  onAC: nil, battery: nil, thermal: "unknown", owned: false,
                                  remainingSeconds: nil, updatedAt: now, installerUID: 501)
        let decodedStatus = try JSONDecoder().decode(HelperStatus.self, from: JSONEncoder().encode(status))
        assert(decodedStatus.installerUID == 501 && decodedStatus.session == nil && !decodedStatus.owned)
        assert(decodedStatus.remainingSeconds == nil && decodedStatus.updatedAt == now)
        let install = try JSONDecoder().decode(InstallConfig.self, from: JSONEncoder().encode(InstallConfig(uid: 501)))
        assert(install.uid == 501)
        assert(WakePaths.lease == "/var/db/nl.local.WakeGuard/lease.json")
        print("Policy tests passed")
    }
}

private struct LegacyWakeSettings: Decodable {
    let onAC: Bool
    let onBattery: Bool
    let batteryFloor: Int
    let darkenDisplays: Bool
    let sessionMinutes: Int
}

private struct LegacySettingsRequest: Decodable {
    let enabled: Bool
    let uninstall: Bool
    let settings: LegacyWakeSettings
}
