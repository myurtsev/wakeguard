import Foundation
import Darwin
import Security

enum HelperSetupResult: Equatable {
    case installed
    case cancelled
    case failed(String)
}

enum HelperSetupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

final class HelperSetup {
    static let packagePath = WakePaths.installedApp + "/Contents/Resources/WakeGuard-helper.pkg"
    static let scriptSource = "do shell script \"/usr/sbin/installer -pkg '/Applications/WakeGuard.app/Contents/Resources/WakeGuard-helper.pkg' -target /\" with administrator privileges"
    private let queue = DispatchQueue(label: "nl.local.WakeGuard.helper-setup")
    private let executor: () -> HelperSetupResult
    private let timeout: TimeInterval
    private var completion: ((HelperSetupResult) -> Void)?
    private var watchdog: DispatchWorkItem?
    private(set) var isInstalling = false

    init(timeout: TimeInterval = 120, executor: @escaping () -> HelperSetupResult = HelperSetup.execute) {
        self.timeout = timeout
        self.executor = executor
    }

    @discardableResult func install(completion: @escaping (HelperSetupResult) -> Void) -> Bool {
        precondition(Thread.isMainThread)
        guard !isInstalling else { return false }
        isInstalling = true
        self.completion = completion
        let watchdog = DispatchWorkItem { [weak self] in
            self?.deliver(.failed("Setup is taking longer than expected. macOS may still be installing the helper. Please wait."))
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        queue.async {
            let result = self.executor()
            DispatchQueue.main.async {
                self.isInstalling = false
                self.watchdog?.cancel()
                self.watchdog = nil
                self.deliver(result)
            }
        }
        return true
    }

    private func deliver(_ result: HelperSetupResult) {
        let callback = completion
        completion = nil
        callback?(result)
    }

    static func requireInstalledLocation(_ bundleURL: URL) throws {
        guard bundleURL.path == WakePaths.installedApp else {
            throw HelperSetupError.invalid("Drag WakeGuard to Applications, then open it from there.")
        }
    }

    static func validateItem(_ url: URL, directory: Bool) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              metadata.st_uid == 0 || metadata.st_uid == getuid(),
              metadata.st_mode & 0o022 == 0,
              directory || (metadata.st_nlink == 1 && metadata.st_size > 0 && metadata.st_size <= 20 * 1024 * 1024) else {
            throw HelperSetupError.invalid("An app file is missing or has unsafe permissions. Copy the original WakeGuard app to Applications again.")
        }
    }

    static func validateInstalledBundle() throws {
        let bundleURL = Bundle.main.bundleURL
        try requireInstalledLocation(bundleURL)
        var applications = stat()
        guard lstat("/Applications", &applications) == 0,
              applications.st_mode & S_IFMT == S_IFDIR, applications.st_uid == 0,
              applications.st_mode & 0o002 == 0 else {
            throw HelperSetupError.invalid("Applications has unsafe permissions. Helper setup stopped.")
        }
        for relative in ["", "Contents", "Contents/Resources"] {
            try validateItem(bundleURL.appendingPathComponent(relative), directory: true)
        }
        try validateItem(URL(fileURLWithPath: packagePath), directory: false)
        guard Bundle.main.bundleIdentifier == WakePaths.bundleID else {
            throw HelperSetupError.invalid("The WakeGuard app identity could not be verified.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw HelperSetupError.invalid("WakeGuard has been modified or damaged. Copy the original app to Applications again.")
        }
    }

    static func interpret(error: NSDictionary?) -> HelperSetupResult {
        guard let error else { return .installed }
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        if number == -128 { return .cancelled }
        let message = error[NSAppleScript.errorMessage] as? String ?? "macOS could not confirm helper installation."
        return .failed(String(message.prefix(512)))
    }

    private static func execute() -> HelperSetupResult {
        do { try validateInstalledBundle() }
        catch { return .failed(error.localizedDescription) }
        guard let script = NSAppleScript(source: scriptSource) else {
            return .failed("macOS could not start helper setup.")
        }
        var error: NSDictionary?
        let reply = script.executeAndReturnError(&error) as NSAppleEventDescriptor?
        if reply == nil && error == nil { return .failed("macOS could not confirm helper installation.") }
        return interpret(error: error)
    }
}
