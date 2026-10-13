import Foundation
import Darwin

@main
enum HelperTests {
    static func main() throws {
        let awake = try sleepValue(kCFBooleanTrue)
        let asleep = try sleepValue(kCFBooleanFalse)
        assert(awake && !asleep)
        for value: CFTypeRef? in [nil, "0" as CFString, NSNumber(value: 0), NSNumber(value: 2)] {
            do { _ = try sleepValue(value); assertionFailure("Invalid power state accepted") } catch {}
        }
        do { _ = try command("/bin/sh", ["-c", "false"]); assertionFailure("Unlisted command accepted") } catch {}
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("helper-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("lease")
        try Data([1]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fixture = try checkedData(file.path, owner: getuid(), mode: 0o600)
        assert(fixture == Data([1]))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try checkedData(link.path, owner: getuid(), mode: 0o600); assertionFailure("Symlink accepted") } catch {}
        let fd = open(file.path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { throw HelperError.message("Cannot read test file") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw HelperError.message("Cannot lock test file") }
        do { _ = try checkedData(file.path, owner: getuid(), mode: 0o600, locked: true); assertionFailure("Busy lease accepted") } catch {}
        flock(fd, LOCK_UN)
        do { try removeRegular(link.path, owner: getuid()); assertionFailure("Symlink removal accepted") } catch {}
        let hardLink = directory.appendingPathComponent("hard-link")
        try FileManager.default.linkItem(at: file, to: hardLink)
        do { try removeRegular(file.path, owner: getuid()); assertionFailure("Hard-link removal accepted") } catch {}
        try FileManager.default.removeItem(at: hardLink)
        try removeRegular(file.path, owner: getuid())
        try removeRegular(file.path, owner: getuid())
        let sample = powerSample()
        let clock = continuousSeconds()
        assert(clock.isFinite && clock >= 0 && continuousSeconds() >= clock)
        print("Helper boundary checks passed; read-only kernel SleepDisabled=\(try sleepDisabled()), AC=\(String(describing: sample.onAC)), battery=\(String(describing: sample.battery)), thermal=\(sample.thermal.rawValue)")
    }
}
