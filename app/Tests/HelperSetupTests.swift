import Foundation
import Darwin

@main struct HelperSetupTests {
    static func main() throws {
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); assertionFailure("Unsafe setup input accepted") } catch {}
        }
        try HelperSetup.requireInstalledLocation(URL(fileURLWithPath: WakePaths.installedApp))
        for path in ["/Volumes/WakeGuard/WakeGuard.app", "/Applications/Other.app", "/tmp/WakeGuard.app"] {
            rejects { try HelperSetup.requireInstalledLocation(URL(fileURLWithPath: path)) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wakeguard-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try HelperSetup.validateItem(root, directory: true)
        let package = root.appendingPathComponent("package.pkg")
        try Data([1]).write(to: package)
        try HelperSetup.validateItem(package, directory: false)
        rejects { try HelperSetup.validateItem(package, directory: true) }
        rejects { try HelperSetup.validateItem(root, directory: false) }
        rejects { try HelperSetup.validateItem(root.appendingPathComponent("missing"), directory: false) }
        let link = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        rejects { try HelperSetup.validateItem(link, directory: false) }
        let hardlink = root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: package, to: hardlink)
        rejects { try HelperSetup.validateItem(package, directory: false) }
        try FileManager.default.removeItem(at: hardlink)
        assert(chmod(package.path, 0o666) == 0)
        rejects { try HelperSetup.validateItem(package, directory: false) }
        assert(chmod(package.path, 0o644) == 0)
        try Data().write(to: package)
        rejects { try HelperSetup.validateItem(package, directory: false) }
        let oversized = try FileHandle(forWritingTo: package)
        try oversized.truncate(atOffset: 20 * 1024 * 1024 + 1)
        try oversized.close()
        rejects { try HelperSetup.validateItem(package, directory: false) }
        assert(HelperSetup.interpret(error: nil) == .installed)
        assert(HelperSetup.interpret(error: [NSAppleScript.errorNumber: -128]) == .cancelled)
        assert(HelperSetup.interpret(error: [NSAppleScript.errorNumber: 1, NSAppleScript.errorMessage: "fixture failure"]) == .failed("fixture failure"))
        var compileError: NSDictionary?
        assert(NSAppleScript(source: HelperSetup.scriptSource)?.compileAndReturnError(&compileError) == true)
        assert(compileError == nil)
        var callbacks: [HelperSetupResult] = []
        let setup = HelperSetup(timeout: 0.02) {
            Thread.sleep(forTimeInterval: 0.08)
            return .installed
        }
        assert(setup.install { assert(Thread.isMainThread); callbacks.append($0) })
        assert(!setup.install { _ in assertionFailure("Parallel setup accepted") })
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        assert(callbacks.count == 1 && setup.isInstalling)
        guard case .failed = callbacks[0] else { fatalError("Setup watchdog did not fire") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        assert(callbacks.count == 1 && !setup.isInstalling)
        assert(setup.install { callbacks.append($0) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        assert(callbacks.count == 2 && !setup.isInstalling)
        print("Helper setup checks passed; no authorization or installation executed")
    }
}
