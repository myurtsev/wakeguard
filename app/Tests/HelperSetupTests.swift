import Foundation
import Darwin

@main struct HelperSetupTests {
    static func main() throws {
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); assertionFailure("Unsafe setup input accepted") } catch {}
        }
        func waitUntil(_ condition: () -> Bool) {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            assert(condition(), "Helper setup condition timed out")
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
        let executorGate = DispatchSemaphore(value: 0)
        let setup = HelperSetup(timeout: 0.02) {
            executorGate.wait()
            return .installed
        }
        assert(setup.install { assert(Thread.isMainThread); callbacks.append($0) })
        assert(!setup.install { _ in assertionFailure("Parallel setup accepted") })
        waitUntil { callbacks.count == 1 }
        assert(callbacks.count == 1 && setup.isInstalling)
        guard case .failed = callbacks[0] else { fatalError("Setup watchdog did not fire") }
        assert(!setup.install { _ in assertionFailure("Timed-out setup accepted parallel installation") })
        executorGate.signal()
        waitUntil { !setup.isInstalling }
        assert(callbacks.count == 1 && !setup.isInstalling)
        assert(setup.install { assert(Thread.isMainThread); callbacks.append($0) })
        waitUntil { callbacks.count == 2 }
        executorGate.signal()
        waitUntil { !setup.isInstalling }
        assert(callbacks.count == 2 && !setup.isInstalling)
        print("Helper setup checks passed; no authorization or installation executed")
    }
}
