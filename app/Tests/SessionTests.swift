import Foundation

@main
enum SessionTests {
    static func main() {
        let ac = PowerSample(onAC: true, battery: nil, thermal: .nominal)
        let battery = PowerSample(onAC: false, battery: 80, thermal: .nominal)
        let hot = PowerSample(onAC: true, battery: nil, thermal: .serious)
        func request(_ sequence: UInt64 = 1, session: String = "session", enabled: Bool = true,
                     settings: WakeSettings = WakeSettings(), at: Double = 1_000,
                     generation: String = "generation", uninstall: Bool = false,
                     sleepAfterAgents: Bool? = nil) -> WakeRequest {
            WakeRequest(generation: generation, session: session, sequence: sequence, enabled: enabled,
                        issuedAt: at, settings: settings, uninstall: uninstall,
                        sleepAfterAgents: sleepAfterAgents)
        }
        func step(_ machine: WakeSession, _ request: WakeRequest? = nil,
                  power: PowerSample? = nil, time: Double = 1_000, uptime: Double = 100) -> SessionResult {
            machine.step(request: request, power: power ?? ac, wallTime: time, uptime: uptime)
        }

        let initial = WakeSession(generation: "generation")
        assert(step(initial).mode == "off")
        assert(step(initial).session == nil)
        assert(!step(initial).shouldHold)
        assert(step(initial, request(generation: "old")).mode == "off")
        assert(step(initial, request(at: .nan)).mode == "off")
        assert(step(initial, request(), time: .nan).mode == "off")
        assert(step(initial, request(), uptime: .nan).mode == "off")

        let lease = WakeSession(generation: "generation")
        let started = step(lease, request())
        assert(started.mode == "awake" && started.shouldHold && started.session == "session")
        assert(started.remainingSeconds == 3_600)
        assert(step(lease, request(2, at: 1_005), time: 1_005, uptime: 105).mode == "awake")
        assert(step(lease, request(2, at: 1_014), time: 1_014, uptime: 114).mode == "awake")
        let expired = step(lease, request(3, at: 1_015), time: 1_015, uptime: 115)
        assert(expired.mode == "stopped" && expired.reason == "App is not responding" && !expired.shouldHold)
        assert(step(lease, request(4, at: 1_016), time: 1_016, uptime: 116).mode == "stopped")
        assert(step(lease, request(1, session: "restart", at: 1_017), time: 1_017, uptime: 117).mode == "awake")
        let disabled = step(lease, request(2, session: "restart", enabled: false, at: 1_018), time: 1_018, uptime: 118)
        assert(disabled.mode == "off" && disabled.remainingSeconds == nil && !disabled.shouldHold)
        assert(step(lease, request(1, session: "restart", at: 1_019), time: 1_019, uptime: 119).mode == "off")
        assert(step(lease, request(3, session: "restart", at: 1_020), time: 1_020, uptime: 120).mode == "awake")

        for invalid in [request(2, at: 980), request(2, generation: "old"), request(2, at: .infinity)] {
            let machine = WakeSession(generation: "generation")
            assert(step(machine, request()).mode == "awake")
            assert(step(machine, invalid, uptime: 109).mode == "awake")
            assert(step(machine, nil, uptime: 110).mode == "stopped")
        }
        let missing = WakeSession(generation: "generation")
        assert(step(missing, request()).mode == "awake")
        assert(step(missing, nil, uptime: 109).mode == "awake")
        assert(step(missing, nil, uptime: 110).mode == "stopped")

        let thermal = WakeSession(generation: "generation")
        assert(step(thermal, request(), power: hot).reason == "Mac is too warm")
        assert(step(thermal, request(2), uptime: 101).mode == "stopped")
        assert(step(thermal, request(3, enabled: false), uptime: 102).mode == "off")
        assert(step(thermal, request(4), uptime: 103).mode == "awake")
        let lowBattery = WakeSession(generation: "generation")
        let batterySettings = WakeSettings(onBattery: true, batteryFloor: 30)
        assert(step(lowBattery, request(settings: batterySettings),
                    power: PowerSample(onAC: false, battery: 30, thermal: .nominal)).reason == "Battery below limit")
        assert(step(lowBattery, request(2, settings: batterySettings), power: battery, uptime: 101).mode == "stopped")
        let paused = WakeSession(generation: "generation")
        assert(step(paused, request(), power: battery).mode == "paused")
        assert(step(paused, request(settings: WakeSettings(onBattery: true)), power: battery, uptime: 101).mode == "paused")
        assert(step(paused, request(2), power: battery, uptime: 105).mode == "paused")
        assert(step(paused, nil, uptime: 106).mode == "awake")

        let staleGuard = WakeSession(generation: "generation")
        assert(step(staleGuard, request()).mode == "awake")
        assert(step(staleGuard, request(2, generation: "old"), power: hot, uptime: 101).reason == "Mac is too warm")
        assert(step(staleGuard, request(3), uptime: 102).mode == "stopped")

        let timed = WakeSession(generation: "generation")
        let halfHour = WakeSettings(sessionMinutes: 30)
        assert(step(timed, request(settings: halfHour)).remainingSeconds == 1_800)
        for sequence in 2...200 {
            let elapsed = Double(sequence - 1) * 9
            assert(step(timed, request(UInt64(sequence), settings: halfHour, at: 1_000 + elapsed),
                        time: 1_000 + elapsed, uptime: 100 + elapsed).mode == "awake")
        }
        assert(step(timed, nil, time: 2_791, uptime: 1_891).remainingSeconds == 9)
        assert(step(timed, request(201, settings: halfHour, at: 2_799.25), time: 2_799.25, uptime: 1_899.25).remainingSeconds == 1)
        let finished = step(timed, request(202, settings: WakeSettings(sessionMinutes: 120), at: 2_800), time: 2_800, uptime: 1_900)
        assert(finished.mode == "stopped" && finished.reason == "Time limit reached")
        assert(step(timed, request(203, at: 2_801), time: 2_801, uptime: 1_901).mode == "stopped")
        let indefinite = WakeSession(generation: "generation")
        assert(step(indefinite, request(settings: WakeSettings(sessionMinutes: 0))).remainingSeconds == nil)
        assert(step(indefinite, request(2, settings: WakeSettings(sessionMinutes: 0), at: 101_000),
                    time: 101_000, uptime: 100_100).reason == "App is not responding")
        let shortened = WakeSession(generation: "generation")
        assert(step(shortened, request()).mode == "awake")
        // Renew without resetting the original session start.
        for sequence in 2...201 {
            let elapsed = Double(sequence - 1) * 9
            assert(step(shortened, request(UInt64(sequence), at: 1_000 + elapsed),
                        time: 1_000 + elapsed, uptime: 100 + elapsed).mode == "awake")
        }
        assert(step(shortened, request(202, settings: halfHour, at: 2_801), time: 2_801, uptime: 1_901).mode == "stopped")

        let conflict = WakeSession(generation: "generation")
        assert(step(conflict, request()).mode == "awake")
        conflict.block("Andere app houdt Mac wakker")
        assert(step(conflict, request(2), uptime: 101).reason == "Andere app houdt Mac wakker")
        assert(step(conflict, request(1, session: "new"), uptime: 102).mode == "awake")
        let corrupted = WakeSession(generation: "generation")
        assert(step(corrupted, request()).mode == "awake")
        assert(step(corrupted, request(2, settings: WakeSettings(batteryFloor: 5)), uptime: 101).reason == "Invalid settings")
        assert(step(corrupted, request(3), uptime: 102).mode == "stopped")
        let invalidClock = WakeSession(generation: "generation")
        assert(step(invalidClock, request()).mode == "awake")
        assert(step(invalidClock, nil, uptime: .infinity).mode == "stopped")
        assert(step(invalidClock, request(2), uptime: 101).mode == "stopped")

        for candidate in [request(uninstall: true), request(enabled: false, at: 980, uninstall: true),
                          request(enabled: false, generation: "old", uninstall: true)] {
            let machine = WakeSession(generation: "generation")
            assert(!step(machine, candidate).shouldUninstall)
        }
        let uninstall = WakeSession(generation: "generation")
        assert(step(uninstall, request()).mode == "awake")
        let removed = step(uninstall, request(enabled: false, uninstall: true))
        assert(removed.mode == "off" && removed.shouldUninstall && !removed.shouldHold)

        let completedAgents = WakeSession(generation: "generation")
        assert(step(completedAgents, request()).shouldHold)
        let finishRequest = request(2, enabled: false, sleepAfterAgents: true)
        let completed = step(completedAgents, finishRequest, uptime: 101)
        assert(completed.mode == "off" && completed.shouldSleep && !completed.shouldHold && !completed.shouldUninstall)
        assert(!step(completedAgents, finishRequest, uptime: 102).shouldSleep)
        assert(!step(completedAgents, request(3, enabled: false, sleepAfterAgents: true), uptime: 103).shouldSleep)
        assert(!step(completedAgents, nil, uptime: 104).shouldSleep)

        for candidate in [request(1, enabled: false, sleepAfterAgents: true),
                          request(0, enabled: false, sleepAfterAgents: true),
                          request(2, session: "other", enabled: false, sleepAfterAgents: true),
                          request(2, enabled: false, at: 980, sleepAfterAgents: true),
                          request(2, enabled: false, generation: "old", sleepAfterAgents: true),
                          request(2, enabled: false, uninstall: true, sleepAfterAgents: true),
                          request(2, enabled: false), request(2, enabled: false, sleepAfterAgents: false),
                          request(2, sleepAfterAgents: true)] {
            let machine = WakeSession(generation: "generation")
            assert(step(machine, request()).shouldHold)
            assert(!step(machine, candidate, uptime: 101).shouldSleep)
        }
        assert(!step(WakeSession(generation: "generation"), finishRequest).shouldSleep)
        let expiredAgents = WakeSession(generation: "generation")
        assert(step(expiredAgents, request()).shouldHold)
        assert(!step(expiredAgents, request(2, enabled: false, at: 1_010, sleepAfterAgents: true),
                     time: 1_010, uptime: 110).shouldSleep)
        let blockedAgents = WakeSession(generation: "generation")
        assert(step(blockedAgents, request()).shouldHold)
        blockedAgents.block("Cannot save helper status")
        assert(!step(blockedAgents, finishRequest, uptime: 101).shouldSleep)
        for power in [hot, battery, PowerSample(onAC: nil, battery: nil, thermal: .nominal),
                      PowerSample(onAC: true, battery: nil, thermal: .unknown)] {
            let machine = WakeSession(generation: "generation")
            assert(step(machine, request()).shouldHold)
            assert(!step(machine, finishRequest, power: power, uptime: 101).shouldSleep)
        }

        // Missing optional fields retain compatibility with an older app/helper.
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        do {
            var oldRequest = try JSONSerialization.jsonObject(with: encoder.encode(finishRequest)) as! [String: Any]
            oldRequest.removeValue(forKey: "sleepAfterAgents")
            let decodedRequest = try decoder.decode(WakeRequest.self, from: JSONSerialization.data(withJSONObject: oldRequest))
            assert(decodedRequest.sleepAfterAgents == nil)
            let newStatus = HelperStatus(generation: "generation", session: nil, mode: "off", reason: "",
                                         onAC: true, battery: nil, thermal: "nominal", owned: false,
                                         remainingSeconds: nil, updatedAt: 1_000, installerUID: 501)
            assert(newStatus.protocolVersion == WakePaths.helperProtocol)
            var oldStatus = try JSONSerialization.jsonObject(with: encoder.encode(newStatus)) as! [String: Any]
            oldStatus.removeValue(forKey: "protocolVersion")
            let decodedStatus = try decoder.decode(HelperStatus.self, from: JSONSerialization.data(withJSONObject: oldStatus))
            assert(decodedStatus.protocolVersion == nil)
        } catch { fatalError("Protocol compatibility failed: \(error)") }
        print("Session tests passed")
    }
}
