import Foundation
import Darwin
import IOKit.ps
import IOKit

enum HelperError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func checkedData(_ path: String, owner: uid_t, mode: mode_t, locked: Bool = false,
                 maximumBytes: Int = 4096) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw HelperError.message("File unavailable") }
    defer { close(fd) }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_uid == owner, metadata.st_nlink == 1,
          metadata.st_mode & 0o7777 == mode, metadata.st_size > 0, metadata.st_size <= maximumBytes else {
        throw HelperError.message("Unsafe or invalid file")
    }
    if locked {
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw HelperError.message("Request is being written") }
    }
    defer { if locked { flock(fd, LOCK_UN) } }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw HelperError.message("Cannot read file") }
        if count == 0 { break }
        result.append(contentsOf: buffer.prefix(count))
        guard result.count <= maximumBytes else { throw HelperError.message("File exceeds size limit") }
    }
    return result
}

func checkDirectory() throws {
    var metadata = stat()
    guard lstat(WakePaths.directory, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
          metadata.st_uid == 0, metadata.st_mode & 0o7777 == 0o755 else {
        throw HelperError.message("Unsafe helper directory permissions")
    }
}

func syncDirectory() throws {
    let directory = open(WakePaths.directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw HelperError.message("Cannot read recovery directory") }
    defer { close(directory) }
    guard fsync(directory) == 0 else { throw HelperError.message("Cannot sync recovery directory") }
}

func rootWrite(_ path: String, data: Data, mode: mode_t, owner: uid_t = 0) throws {
    try checkDirectory()
    let temporary = WakePaths.directory + "/." + UUID().uuidString
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard fd >= 0 else { throw HelperError.message("Cannot write recovery data") }
    defer { close(fd); unlink(temporary) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < data.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw HelperError.message("Cannot save recovery data") }
            offset += count
        }
    }
    guard fchown(fd, owner, 0) == 0, fchmod(fd, mode) == 0, fsync(fd) == 0, rename(temporary, path) == 0 else {
        throw HelperError.message("Cannot sync recovery data")
    }
    try syncDirectory()
}

func command(_ executable: String, _ arguments: [String]) throws -> String {
    let allowed = executable == "/usr/bin/pmset" &&
        [["-a", "disablesleep", "0"], ["-a", "disablesleep", "1"], ["displaysleepnow"], ["sleepnow"]].contains(arguments)
    guard allowed else { throw HelperError.message("Command not allowed") }
    let process = Process()
    let output = Pipe(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    if finished.wait(timeout: .now() + 3) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 0.5)
        }
        throw HelperError.message("System command is not responding")
    }
    // Fixed pmset commands have small output; no caller supplies the program or arguments.
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationReason == .exit && process.terminationStatus == 0 else {
        throw HelperError.message(error.isEmpty ? "System command failed" : String(error.prefix(200)))
    }
    return text
}

func sleepValue(_ value: CFTypeRef?) throws -> Bool {
    guard let value, CFGetTypeID(value) == CFBooleanGetTypeID(), let disabled = value as? Bool else {
        throw HelperError.message("Sleep state unavailable")
    }
    return disabled
}

func sleepDisabled() throws -> Bool {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else { throw HelperError.message("Sleep state unavailable") }
    defer { IOObjectRelease(entry) }
    // pmset -g omits the default setting; read the actual kernel flag instead.
    return try sleepValue(IORegistryEntryCreateCFProperty(entry, "SleepDisabled" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue())
}

func validateRemoval(_ path: String, owner: uid_t) throws {
    var metadata = stat()
    if lstat(path, &metadata) != 0 {
        if errno == ENOENT { return }
        throw HelperError.message("Cannot read file")
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == owner,
          metadata.st_nlink == 1, metadata.st_mode & 0o022 == 0 else {
        throw HelperError.message("Unsafe file; removal blocked")
    }
}

func removeRegular(_ path: String, owner: uid_t) throws {
    try validateRemoval(path, owner: owner)
    if unlink(path) != 0 && errno != ENOENT { throw HelperError.message("Cannot remove file") }
}

func temporaryFiles() throws -> [String] {
    let names = try FileManager.default.contentsOfDirectory(atPath: WakePaths.directory)
    return names.filter { $0.hasPrefix(".") && UUID(uuidString: String($0.dropFirst())) != nil }
        .map { WakePaths.directory + "/" + $0 }
}

func cleanTemporaryFiles(uid: uid_t) throws {
    let files = try temporaryFiles()
    for path in files { try validateTemporary(path, uid: uid) }
    for path in files {
        guard unlink(path) == 0 || errno == ENOENT else { throw HelperError.message("Cannot remove temporary file") }
    }
}

func validateTemporary(_ path: String, uid: uid_t) throws {
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_uid == 0 || metadata.st_uid == uid else {
        throw HelperError.message("Unsafe temporary file")
    }
    try validateRemoval(path, owner: metadata.st_uid)
}

func markerExists() throws -> Bool {
    var metadata = stat()
    if lstat(WakePaths.marker, &metadata) != 0 {
        if errno == ENOENT { return false }
        throw HelperError.message("Cannot read recovery marker")
    }
    let data = try checkedData(WakePaths.marker, owner: 0, mode: 0o600)
    guard data == Data([1]) else { throw HelperError.message("Invalid recovery marker") }
    return true
}

func restoreOwnedSleep() throws {
    guard try markerExists() else { return }
    _ = try command("/usr/bin/pmset", ["-a", "disablesleep", "0"])
    guard try !sleepDisabled() else {
        throw HelperError.message("Cannot restore normal sleep")
    }
    guard unlink(WakePaths.marker) == 0 else { throw HelperError.message("Cannot remove recovery marker") }
    try syncDirectory()
}

func continuousSeconds() -> Double {
    var base = mach_timebase_info_data_t()
    guard mach_timebase_info(&base) == KERN_SUCCESS, base.denom > 0 else { return .nan }
    // Include system sleep, so an old paused session cannot resume after its lease expired.
    return Double(mach_continuous_time()) * Double(base.numer) / Double(base.denom) / 1_000_000_000
}

func absoluteSeconds() -> Double {
    var base = mach_timebase_info_data_t()
    guard mach_timebase_info(&base) == KERN_SUCCESS, base.denom > 0 else { return .nan }
    return Double(mach_absolute_time()) * Double(base.numer) / Double(base.denom) / 1_000_000_000
}

func powerSample() -> PowerSample {
    let thermal: ThermalLevel
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = .nominal
    case .fair: thermal = .fair
    case .serious: thermal = .serious
    case .critical: thermal = .critical
    @unknown default: thermal = .unknown
    }
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else {
        return PowerSample(onAC: nil, battery: nil, thermal: thermal)
    }
    let onAC: Bool? = type == kIOPSACPowerValue ? true : type == kIOPSBatteryPowerValue ? false : nil
    var battery: Int?
    if let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = info[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else { continue }
            let percentage = 100 * current.doubleValue / maximum.doubleValue
            if percentage.isFinite && percentage >= 0 && percentage <= 100 { battery = Int(percentage.rounded(.down)) }
        }
    }
    return PowerSample(onAC: onAC, battery: battery, thermal: thermal)
}

func lidClosed() -> Bool? {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    return try? sleepValue(IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue())
}

final class Helper {
    let generation = UUID().uuidString
    let uid: UInt32
    let session: WakeSession
    private var lastDisplaySleep = 0.0
    private var lastStatusWrite = 0.0
    private var previousMode = ""
    private var previousReason = ""
    private var audit: AuditTracker
    private var auditError: String?
    private var verifiedAwake = false
    private var currentMode = "off"
    private var currentReason = ""
    private var currentSession: String?
    private var notificationPort: IONotificationPortRef?
    private var lidNotification: io_object_t = 0
    private let auditQueue = DispatchQueue(label: "nl.local.WakeGuard.audit-io")
    private var auditWritePending = false
    private var auditSuspended = false

    init(recovered: Bool = false) throws {
        try checkDirectory()
        let config = try JSONDecoder().decode(InstallConfig.self, from: checkedData(WakePaths.config, owner: 0, mode: 0o644))
        guard config.uid >= 501 else { throw HelperError.message("Invalid installation account") }
        uid = config.uid
        session = WakeSession(generation: generation)
        var history: AuditHistory?
        if FileManager.default.fileExists(atPath: WakePaths.audit) {
            do {
                history = try JSONDecoder().decode(AuditHistory.self, from:
                    checkedData(WakePaths.audit, owner: 0, mode: 0o600, maximumBytes: AuditFormat.maximumBytes))
                if let history { try AuditFormat.validate(history) }
            } catch { auditError = "Activity history unreadable; history reset" }
        }
        audit = AuditTracker(history: history, generation: generation, continuous: continuousSeconds(),
                             wallTime: Date().timeIntervalSince1970)
        if auditError != nil {
            audit.record(kind: "audit_reset", wallTime: Date().timeIntervalSince1970, mode: "off",
                         reason: "Previous activity history could not be read", session: nil,
                         verifiedAwake: false, lidClosed: lidClosed(), power: powerSample())
        }
        audit.record(kind: "helper_start", wallTime: Date().timeIntervalSince1970, mode: "off",
                     reason: recovered ? "System helper restarted; normal sleep restored" : "System helper started",
                     session: nil, verifiedAwake: false, lidClosed: lidClosed(), power: powerSample())
    }

    func stop() throws {
        try restoreOwnedSleep()
        verifiedAwake = false
        currentMode = "off"
        currentReason = "System helper stopped"
        observeLid(lidClosed())
    }

    func watchLid() {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return }
        defer { IOObjectRelease(entry) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        let result = IOServiceAddInterestNotification(port, entry, kIOGeneralInterest, { context, _, message, argument in
            // IOPM.h defines this function-like macro; Swift does not import it.
            guard message == 0xe0034100, let context else { return }
            let helper = Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue()
            helper.observeLid(UInt(bitPattern: argument) & 1 != 0)
        }, Unmanaged.passUnretained(self).toOpaque(), &lidNotification)
        guard result == KERN_SUCCESS else { IONotificationPortDestroy(port); return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
    }

    deinit {
        if lidNotification != 0 { IOObjectRelease(lidNotification) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    private func observeLid(_ closed: Bool?) {
        audit.sample(lidClosed: closed, continuous: continuousSeconds(), absolute: absoluteSeconds(),
                     wallTime: Date().timeIntervalSince1970, mode: currentMode, reason: currentReason,
                     session: currentSession, verifiedAwake: verifiedAwake, power: powerSample())
        writeAudit()
    }

    private func writeAudit() {
        guard audit.needsWrite, !auditWritePending, !auditSuspended else { return }
        do {
            let data = try JSONEncoder().encode(audit.history)
            guard data.count <= AuditFormat.maximumBytes else { throw HelperError.message("Activity history exceeds size limit") }
            let revision = audit.revision
            let capturedAt = continuousSeconds()
            auditWritePending = true
            auditQueue.async {
                let success: Bool
                do {
                    try rootWrite(WakePaths.audit, data: data, mode: 0o600)
                    try rootWrite(WakePaths.history, data: data, mode: 0o600, owner: self.uid)
                    success = true
                } catch { success = false }
                DispatchQueue.main.async {
                    self.auditWritePending = false
                    if success {
                        self.audit.didWrite(continuous: capturedAt, revision: revision)
                        self.auditError = nil
                    } else { self.auditError = "Cannot save activity history" }
                }
            }
        } catch { auditError = "Cannot save activity history" }
    }

    func tick() {
        let uptime = continuousSeconds()
        let wallTime = Date().timeIntervalSince1970
        let power = powerSample()
        observeLid(lidClosed())
        var request: WakeRequest?
        if let data = try? checkedData(WakePaths.lease, owner: uid, mode: 0o600, locked: true) {
            request = try? JSONDecoder().decode(WakeRequest.self, from: data)
        }
        var result = session.step(request: request, power: power, wallTime: wallTime, uptime: uptime)
        var error: String?
        do {
            if result.shouldUninstall {
                auditSuspended = true
                try restoreOwnedSleep()
                verifiedAwake = false
                if !auditWritePending { try uninstall(); return }
            } else { auditSuspended = false }
            let owned = try markerExists()
            if result.shouldHold {
                let disabled = try sleepDisabled()
                if !owned {
                    guard !disabled else { throw HelperError.message("Another app has disabled system sleep") }
                    try rootWrite(WakePaths.marker, data: Data([1]), mode: 0o600)
                    _ = try command("/usr/bin/pmset", ["-a", "disablesleep", "1"])
                    guard try sleepDisabled() else {
                        throw HelperError.message("Cannot confirm sleep prevention")
                    }
                } else if !disabled {
                    throw HelperError.message("Sleep state changed; start again")
                }
                if request?.settings.darkenDisplays == true && lidClosed() == true && uptime - lastDisplaySleep >= 5 {
                    _ = try command("/usr/bin/pmset", ["displaysleepnow"])
                    lastDisplaySleep = uptime
                }
            } else if owned {
                try restoreOwnedSleep()
                if result.shouldSleep && lidClosed() == true {
                    audit.record(kind: "agent_sleep_requested", wallTime: wallTime, mode: "off",
                                 reason: "Agents finished; sleep requested", session: result.session,
                                 verifiedAwake: false, lidClosed: true, power: power)
                    verifiedAwake = false
                    currentMode = result.mode
                    currentReason = "Agents finished"
                    observeLid(true)
                    _ = try command("/usr/bin/pmset", ["sleepnow"])
                }
            }
        } catch let failure {
            error = failure.localizedDescription
            session.block(error!)
            do { try restoreOwnedSleep() } catch let recoveryError { error = "Cannot restore normal sleep: " + recoveryError.localizedDescription }
            result = session.step(request: nil, power: power, wallTime: wallTime, uptime: uptime)
        }
        let owned = (try? markerExists()) ?? true
        let mode = error == nil ? result.mode : "error"
        let manuallyStopped = result.mode == "off" && ["awake", "paused"].contains(currentMode)
        let reason = error ?? (result.shouldSleep ? "Agents finished" : manuallyStopped ? "Stopped" : result.reason)
        currentMode = mode
        currentReason = reason
        currentSession = result.session
        verifiedAwake = mode == "awake" && owned && (try? sleepDisabled()) == true
        observeLid(lidClosed())
        if uptime - lastStatusWrite >= 2 || mode != previousMode || reason != previousReason {
            let status = HelperStatus(generation: generation, session: result.session, mode: mode, reason: reason,
                                      onAC: power.onAC, battery: power.battery, thermal: power.thermal.rawValue,
                                      owned: owned, remainingSeconds: result.remainingSeconds,
                                      updatedAt: wallTime, installerUID: uid, lidClosed: audit.lidClosed,
                                      latestSummaryID: audit.latestSummaryID, auditError: auditError)
            do {
                try rootWrite(WakePaths.status, data: JSONEncoder().encode(status), mode: 0o644)
                lastStatusWrite = uptime
                previousMode = mode
                previousReason = reason
            } catch {
                session.block("Cannot save helper status")
                try? restoreOwnedSleep()
            }
        }
    }

    private func uninstall() throws {
        try restoreOwnedSleep()
        for path in [WakePaths.plist, WakePaths.helper] { try validateRemoval(path, owner: 0) }
        let temporary = try temporaryFiles()
        for path in temporary { try validateTemporary(path, uid: uid) }
        try validateRemoval(WakePaths.audit, owner: 0)
        try validateRemoval(WakePaths.history, owner: uid)
        let allowed = Set(["config.json", "lease.json", "status.json", "owns-sleep", "audit.json", "history.json"])
        let contents = try FileManager.default.contentsOfDirectory(atPath: WakePaths.directory)
        guard Set(contents).subtracting(temporary.map { URL(fileURLWithPath: $0).lastPathComponent }).isSubset(of: allowed) else {
            throw HelperError.message("Helper directory contains unrecognized files")
        }
        for path in [WakePaths.plist, WakePaths.helper] {
            try removeRegular(path, owner: 0)
        }
        for path in temporary {
            guard unlink(path) == 0 || errno == ENOENT else { throw HelperError.message("Cannot remove temporary file") }
        }
        for path in [WakePaths.lease, WakePaths.config, WakePaths.status, WakePaths.audit, WakePaths.history] {
            if unlink(path) != 0 && errno != ENOENT { throw HelperError.message("Cannot remove helper data") }
        }
        guard rmdir(WakePaths.directory) == 0 else { throw HelperError.message("Cannot remove helper directory") }
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "system/" + WakePaths.label]
        bootout.standardOutput = FileHandle.nullDevice
        bootout.standardError = FileHandle.nullDevice
        try bootout.run()
        // Keep the run loop free to handle launchd's SIGTERM from our own bootout.
    }
}
