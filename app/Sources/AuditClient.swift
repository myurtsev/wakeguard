import Foundation
import Darwin

struct AuditClient {
    func history(uid: uid_t = getuid()) throws -> AuditHistory {
        var metadata = stat()
        guard lstat(WakePaths.directory, &metadata) == 0 else { throw AuditError.unavailable }
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == 0,
              metadata.st_mode & 0o7777 == 0o755 else { throw AuditError.invalid }
        return try Self.readHistory(path: WakePaths.history, owner: uid)
    }

    // Fixtures exercise the same bounded file reader without requiring a root-owned test directory.
    static func readHistory(path: String, owner: uid_t) throws -> AuditHistory {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw AuditError.unavailable }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw AuditError.system }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == owner,
              metadata.st_nlink == 1, metadata.st_mode & 0o7777 == 0o600,
              metadata.st_size > 0, metadata.st_size <= AuditFormat.maximumBytes else { throw AuditError.invalid }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AuditError.system }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= AuditFormat.maximumBytes else { throw AuditError.invalid }
        }
        let history: AuditHistory
        do { history = try JSONDecoder().decode(AuditHistory.self, from: data) }
        catch { throw AuditError.invalid }
        try AuditFormat.validate(history)
        return history
    }
}
