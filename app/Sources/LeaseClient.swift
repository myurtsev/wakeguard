import Foundation
import Darwin

enum LeaseError: LocalizedError {
    case unavailable
    case invalid(String)
    case system(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "System helper unavailable"
        case .invalid(let detail): return detail
        case .system(let detail): return detail
        }
    }
}

struct LeaseClient {
    static let maximumBytes = 4096

    func status(now: Double = Date().timeIntervalSince1970) throws -> HelperStatus {
        try validateDirectory()
        let config: InstallConfig = try read(WakePaths.config)
        guard config.uid == getuid() else {
            throw LeaseError.invalid("System helper belongs to another account")
        }
        let status: HelperStatus = try read(WakePaths.status)
        try Self.validate(status, uid: config.uid, now: now)
        return status
    }

    static func validate(_ status: HelperStatus, uid: UInt32, now: Double) throws {
        guard status.installerUID == uid, UUID(uuidString: status.generation) != nil,
              status.session == nil || UUID(uuidString: status.session!) != nil,
              ["off", "awake", "paused", "error", "stopped"].contains(status.mode),
              ThermalLevel(rawValue: status.thermal) != nil,
              status.battery == nil || (0...100).contains(status.battery!),
              status.remainingSeconds == nil || (0...7200).contains(status.remainingSeconds!),
              status.latestSummaryID == nil || UUID(uuidString: status.latestSummaryID!) != nil,
              status.auditError == nil || status.auditError!.utf8.count <= 256,
              status.reason.utf8.count <= 512, status.updatedAt.isFinite, now.isFinite else {
            throw LeaseError.invalid("Invalid helper status; cannot start")
        }
        let age = now - status.updatedAt
        guard age >= -2, age <= 5 else {
            throw LeaseError.invalid("System helper is not responding; cannot start")
        }
    }

    func send(_ request: WakeRequest) throws {
        try validateDirectory()
        let data = try JSONEncoder().encode(request)
        guard data.count <= Self.maximumBytes else {
            throw LeaseError.invalid("Request exceeds size limit")
        }
        let fd = open(WakePaths.lease, O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw systemError() }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw systemError() }
        try Self.validate(metadata, owner: getuid(), mode: 0o600)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw systemError() }
        defer { flock(fd, LOCK_UN) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = pwrite(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw systemError() }
                offset += count
            }
        }
        guard ftruncate(fd, off_t(data.count)) == 0, fsync(fd) == 0 else { throw systemError() }
    }

    private func validateDirectory() throws {
        var metadata = stat()
        guard lstat(WakePaths.directory, &metadata) == 0 else { throw LeaseError.unavailable }
        guard metadata.st_uid == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o7777 == 0o755 else {
            throw LeaseError.invalid("Unsafe helper directory; cannot start")
        }
    }

    private func read<T: Decodable>(_ path: String) throws -> T {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw LeaseError.unavailable }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw systemError() }
        try Self.validate(metadata, owner: 0, mode: 0o644)
        guard metadata.st_size > 0, metadata.st_size <= Self.maximumBytes else {
            throw LeaseError.invalid("Invalid helper file; cannot start")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw systemError() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumBytes else {
                throw LeaseError.invalid("Helper file exceeds size limit; cannot start")
            }
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LeaseError.invalid("Cannot read helper file; cannot start") }
    }

    static func validate(_ metadata: stat, owner: uid_t, mode: mode_t) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == owner,
              metadata.st_nlink == 1, metadata.st_mode & 0o7777 == mode else {
            throw LeaseError.invalid("Unsafe helper file; cannot start")
        }
    }

    private func systemError() -> LeaseError {
        .system("Cannot connect to system helper: " + String(cString: strerror(errno)))
    }
}
