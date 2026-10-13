import Foundation
import Darwin

@main struct IPCChecks {
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Unsafe input accepted") }
        catch {}
    }

    static func main() throws {
        let now = Date().timeIntervalSince1970
        var status = HelperStatus(generation: UUID().uuidString, session: nil, mode: "off",
                                  reason: "", onAC: true, battery: 60, thermal: "nominal",
                                  owned: false, remainingSeconds: nil, updatedAt: now, installerUID: getuid())
        try LeaseClient.validate(status, uid: getuid(), now: now)
        assert(status.protocolVersion == WakePaths.helperProtocol)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Any]
        legacy["protocolVersion"] = 4
        let earlierStatus = try JSONDecoder().decode(HelperStatus.self, from: JSONSerialization.data(withJSONObject: legacy))
        assert(earlierStatus.protocolVersion == 4)
        try LeaseClient.validate(earlierStatus, uid: getuid(), now: now)
        for key in ["protocolVersion", "lidClosed", "latestSummaryID", "auditError"] { legacy.removeValue(forKey: key) }
        let oldStatus = try JSONDecoder().decode(HelperStatus.self, from: JSONSerialization.data(withJSONObject: legacy))
        assert(oldStatus.protocolVersion == nil && oldStatus.lidClosed == nil && oldStatus.latestSummaryID == nil)
        status.latestSummaryID = "invalid"
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.latestSummaryID = nil
        status.auditError = String(repeating: "x", count: 257)
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.auditError = nil
        status.updatedAt = now - 5.01
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.updatedAt = now + 2.01
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.updatedAt = now
        status.installerUID = getuid() + 1
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.installerUID = getuid()
        status.generation = "not-a-uuid"
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.generation = UUID().uuidString
        status.mode = "unknown"
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.mode = "off"
        status.thermal = "invalid"
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.thermal = "nominal"
        status.battery = 101
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        status.battery = 60
        status.updatedAt = .nan
        rejects { try LeaseClient.validate(status, uid: getuid(), now: now) }
        var metadata = stat()
        metadata.st_mode = S_IFREG | 0o600
        metadata.st_uid = getuid()
        metadata.st_nlink = 1
        try LeaseClient.validate(metadata, owner: getuid(), mode: 0o600)
        metadata.st_mode = S_IFLNK | 0o600
        rejects { try LeaseClient.validate(metadata, owner: getuid(), mode: 0o600) }
        metadata.st_mode = S_IFREG | 0o666
        rejects { try LeaseClient.validate(metadata, owner: getuid(), mode: 0o600) }
        metadata.st_mode = S_IFREG | 0o600
        metadata.st_nlink = 2
        rejects { try LeaseClient.validate(metadata, owner: getuid(), mode: 0o600) }
        metadata.st_nlink = 1
        metadata.st_uid = getuid() + 1
        rejects { try LeaseClient.validate(metadata, owner: getuid(), mode: 0o600) }
        print("IPC boundary checks passed")
    }
}
