import AppKit
import Combine
import CryptoKit
import UserNotifications

private final class PluginRunPermit {
    private let lock = NSLock()
    private var allowed = true
    func cancel() { lock.lock(); allowed = false; lock.unlock() }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
}

final class PluginManager: ObservableObject {
    @Published private(set) var installed: [InstalledPlugin] = []
    @Published private(set) var available: [PluginCatalogEntry] = []
    @Published private(set) var isBusy = true
    @Published private(set) var catalogError: String?
    @Published var error: String?
    @Published var review: PluginInstallReview?
    var onChange: (() -> Void)?

    private let store: PluginStore
    private let secrets = PluginSecrets()
    private let bundledDirectory: URL?
    private let worker = DispatchQueue(label: "nl.local.WakeGuard.plugins", qos: .utility)
    private let execute: (PluginInvocation) throws -> [PluginAction]
    private var latestEvent: PluginEvent?
    private var permits: [String: PluginRunPermit] = [:]
    private var running = Set<String>()
    private var pending: [String: [PluginEvent]] = [:]
    private var transfers: [String: [UUID: PluginTransfer]] = [:]
    private var rate: [String: [Double]] = [:]
    private var installerTransfer: PluginTransfer?
    private var stopped = false
    private var loaded = false
    private var deferredFile: URL?

    init(store: PluginStore = PluginStore(), bundledDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
         execute: ((PluginInvocation) throws -> [PluginAction])? = nil) {
        self.store = store
        self.bundledDirectory = bundledDirectory
        self.execute = execute ?? { invocation in
            guard let executable = Bundle.main.executableURL else { throw PluginError.invalid("Plugin runner is unavailable.") }
            return try PluginRuntime.run(invocation, executable: executable)
        }
        worker.async {
            let loaded = Result { try store.load() }
            let catalog = Result { try Self.readCatalog(bundledDirectory) }
            DispatchQueue.main.async {
                guard !self.stopped else { self.isBusy = false; return }
                switch loaded {
                case .success(let result):
                    self.installed = result.plugins
                    if !result.errors.isEmpty { self.error = result.errors.joined(separator: "\n") }
                case .failure(let failure): self.error = failure.localizedDescription
                }
                switch catalog {
                case .success(let value): self.available = value.plugins
                case .failure(let failure): self.catalogError = failure.localizedDescription
                }
                self.isBusy = false
                self.loaded = true
                for item in self.installed where item.enabled { self.start(id: item.id) }
                self.onChange?()
                if let file = self.deferredFile {
                    self.deferredFile = nil
                    self.prepareInstall(file: file)
                }
            }
        }
    }

    func publish(_ event: PluginEvent) {
        guard !stopped else { return }
        if let previous = latestEvent, previous.session == event.session, previous.agents == event.agents { return }
        var event = event
        event.type = latestEvent == nil ? "snapshot" : "stateChanged"
        event.previousSession = latestEvent?.session
        event.previousAgents = latestEvent?.agents
        latestEvent = event
        for item in installed where item.enabled { enqueue(id: item.id, event: event) }
    }

    func refreshCatalog() {
        guard !isBusy, !stopped else { return }
        isBusy = true
        catalogError = nil
        let url = URL(string: "https://myurtsev.github.io/wakeguard/plugins/catalog.json")!
        let transfer = PluginTransfer(request: URLRequest(url: url), limit: 256 * 1024) { result in
            let catalog = result.flatMap { data -> Result<PluginCatalog, Error> in
                Result {
                    let catalog = try JSONDecoder().decode(PluginCatalog.self, from: data)
                    try catalog.validate()
                    return catalog
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.installerTransfer = nil
                switch catalog {
                case .success(let value): self.available = value.plugins
                case .failure(let failure): self.catalogError = "Could not refresh the catalog. \(failure.localizedDescription)"
                }
            }
        }
        installerTransfer = transfer
        transfer.start()
    }

    func prepareInstall(file: URL) {
        if !loaded { deferredFile = file; return }
        prepare(source: file.lastPathComponent) {
            try PluginPackage.decode(PluginFiles.read(file, limit: PluginPackage.maximumBytes))
        }
    }

    func prepareInstall(url: String) {
        guard !isBusy, review == nil, !stopped else { return }
        do { download(try PluginPackage.httpsURL(url), entry: nil) }
        catch { self.error = error.localizedDescription }
    }

    func prepareInstall(entry: PluginCatalogEntry) {
        guard !isBusy, review == nil, !stopped else { return }
        do {
            try entry.validate()
            let local = bundledDirectory?.appendingPathComponent(entry.id).appendingPathComponent(entry.version + ".wakeguardplugin")
            if let local, FileManager.default.fileExists(atPath: local.path) {
                prepare(source: "WakeGuard catalog") {
                    try Self.checkedPackage(PluginFiles.read(local, limit: PluginPackage.maximumBytes), entry: entry)
                }
            } else { download(try PluginPackage.httpsURL(entry.url), entry: entry) }
        } catch { self.error = error.localizedDescription }
    }

    private func prepare(source: String, operation: @escaping () throws -> PluginPackage) {
        guard !isBusy, review == nil, !stopped else { return }
        isBusy = true
        error = nil
        worker.async {
            let result = Result { try operation() }
            DispatchQueue.main.async { self.finishPreparing(result, source: source) }
        }
    }

    private func download(_ url: URL, entry: PluginCatalogEntry?) {
        isBusy = true
        error = nil
        let transfer = PluginTransfer(request: URLRequest(url: url), limit: PluginPackage.maximumBytes) { result in
            let package = result.flatMap { data in Result { try Self.checkedPackage(data, entry: entry) } }
            DispatchQueue.main.async {
                self.installerTransfer = nil
                self.finishPreparing(package, source: url.absoluteString)
            }
        }
        installerTransfer = transfer
        transfer.start()
    }

    private func finishPreparing(_ result: Result<PluginPackage, Error>, source: String) {
        isBusy = false
        guard !stopped else { return }
        switch result {
        case .success(let package): review = PluginInstallReview(package: package, source: source)
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    func confirmInstall() {
        guard let review, !isBusy, !stopped else { return }
        guard installed.count < 32 || installed.contains(where: { $0.id == review.id }) else {
            error = "Remove a plugin before installing another (maximum 32)."
            return
        }
        let previous = installed.first { $0.id == review.id }
        var values: [String: String] = [:]
        for setting in review.package.settings where setting.type != "secret" {
            let unchanged = previous?.package.settings.contains { $0.key == setting.key && $0.type == setting.type } == true
            if let value = unchanged ? previous?.values[setting.key] : nil { values[setting.key] = value }
            else if let value = setting.defaultValue { values[setting.key] = value }
        }
        var item = InstalledPlugin(package: review.package, enabled: false, values: values, source: review.source)
        item.hasSecretHistory = previous?.hasSecretHistory == true || review.package.settings.contains { $0.type == "secret" }
        invalidate(id: item.id)
        if let index = installed.firstIndex(where: { $0.id == item.id }) {
            installed[index].enabled = false
            installed[index].status = ""
        }
        isBusy = true
        error = nil
        worker.async {
            var written = false
            let result = Result {
                try self.store.save(item)
                written = true
                for setting in previous?.package.settings ?? [] where setting.type == "secret" {
                    if !item.package.settings.contains(where: { $0.key == setting.key && $0.type == "secret" }) {
                        try self.secrets.write(nil, id: item.id, key: setting.key)
                    }
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                guard !self.stopped else { return }
                // A successful package write must remain visible even if obsolete credential cleanup fails.
                if written {
                    self.installed.removeAll { $0.id == item.id }
                    self.installed.append(item)
                    self.installed.sort { $0.package.name.localizedCaseInsensitiveCompare($1.package.name) == .orderedAscending }
                    self.review = nil
                }
                if case .failure(let failure) = result { self.error = failure.localizedDescription }
                self.onChange?()
            }
        }
    }

    func cancelInstall() { review = nil }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }), !stopped else { return }
        error = nil
        if !enabled {
            invalidate(id: id)
            installed[index].enabled = false
            installed[index].status = ""
            onChange?()
            do {
                try store.save(installed[index])
            } catch { self.error = "Plugin stopped, but its disabled state could not be saved. \(error.localizedDescription)" }
            return
        }
        guard !isBusy else { return }
        isBusy = true
        let item = installed[index]
        let permit = PluginRunPermit()
        invalidate(id: id)
        permits[id] = permit
        worker.async {
            let valid = Result { _ = try self.values(for: item, requireComplete: true) }
            DispatchQueue.main.async {
                guard permit.isValid, !self.stopped else { self.isBusy = false; return }
                switch valid {
                case .failure(let failure): self.isBusy = false; self.error = failure.localizedDescription
                case .success:
                    if item.package.permissions.notifications {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                            DispatchQueue.main.async {
                                self.isBusy = false
                                guard permit.isValid, !self.stopped else { return }
                                if granted { self.enable(id: id) }
                                else { self.error = "Allow WakeGuard notifications in System Settings before enabling this plugin." }
                            }
                        }
                    } else { self.isBusy = false; self.enable(id: id) }
                }
            }
        }
    }

    private func enable(id: String) {
        guard !stopped, let index = installed.firstIndex(where: { $0.id == id }) else { return }
        do {
            var item = installed[index]
            item.enabled = true
            item.error = nil
            try store.save(item)
            installed[index] = item
            start(id: id)
            onChange?()
        } catch { self.error = error.localizedDescription }
    }

    func remove(id: String) {
        guard !isBusy, let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let hadSecrets = installed[index].hasSecretHistory == true || installed[index].package.settings.contains { $0.type == "secret" }
        invalidate(id: id)
        installed[index].enabled = false
        installed[index].status = ""
        isBusy = true
        error = nil
        worker.async {
            var removed = false
            let result = Result {
                try self.store.remove(id)
                removed = true
                if hadSecrets { try self.secrets.removeAll(id: id) }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                if removed { self.installed.removeAll { $0.id == id } }
                if case .failure(let failure) = result { self.error = failure.localizedDescription }
                self.onChange?()
            }
        }
    }

    func settingsValues(id: String, completion: @escaping ([String: String]) -> Void) {
        guard let item = installed.first(where: { $0.id == id }), !stopped else { completion([:]); return }
        worker.async {
            let result = Result { try self.values(for: item, requireComplete: false) }
            DispatchQueue.main.async {
                switch result {
                case .success(let values): completion(values)
                case .failure(let failure): self.error = failure.localizedDescription; completion(item.values)
                }
            }
        }
    }

    func saveSettings(id: String, values: [String: String], completion: @escaping (Bool) -> Void) {
        guard !isBusy, !stopped, let index = installed.firstIndex(where: { $0.id == id }) else { completion(false); return }
        error = nil
        let item = installed[index]
        do {
            try Self.validateValues(values, package: item.package, requireComplete: true)
            invalidate(id: id)
            var updated = item
            updated.enabled = false
            updated.status = ""
            updated.values = values.filter { key, _ in item.package.settings.contains { $0.key == key && $0.type != "secret" } }
            installed[index].enabled = false
            installed[index].status = ""
            isBusy = true
            worker.async {
                let result = Result {
                    let oldValues = try self.values(for: item, requireComplete: false)
                    do {
                        for setting in item.package.settings where setting.type == "secret" {
                            try self.secrets.write(values[setting.key], id: id, key: setting.key)
                        }
                        try self.store.save(updated)
                    } catch {
                        for setting in item.package.settings where setting.type == "secret" {
                            try? self.secrets.write(oldValues[setting.key], id: id, key: setting.key)
                        }
                        throw error
                    }
                }
                DispatchQueue.main.async {
                    self.isBusy = false
                    guard let current = self.installed.firstIndex(where: { $0.id == id }), !self.stopped else { completion(false); return }
                    switch result {
                    case .success:
                        self.installed[current] = updated
                        if item.enabled { self.enable(id: id) }
                        self.onChange?()
                        completion(true)
                    case .failure(let failure): self.error = failure.localizedDescription; completion(false)
                    }
                }
            }
        } catch { self.error = error.localizedDescription; completion(false) }
    }

    private func values(for item: InstalledPlugin, requireComplete: Bool) throws -> [String: String] {
        var values = item.values
        for setting in item.package.settings {
            if setting.type == "secret" { values[setting.key] = try secrets.read(id: item.id, key: setting.key) }
            if values[setting.key] == nil { values[setting.key] = setting.defaultValue ?? (setting.type == "toggle" ? "false" : "") }
        }
        try Self.validateValues(values, package: item.package, requireComplete: requireComplete)
        return values
    }

    static func validateValues(_ values: [String: String], package: PluginPackage, requireComplete: Bool) throws {
        for setting in package.settings {
            let value = values[setting.key] ?? ""
            guard value.utf8.count <= 2048, setting.type != "toggle" || ["true", "false"].contains(value),
                  !requireComplete || !setting.required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginError.invalid("Check the value for \(setting.label).")
            }
        }
    }

    func runCommand(id: String, command: String) {
        guard let item = installed.first(where: { $0.id == id && $0.enabled }),
              item.package.commands.contains(where: { $0.id == command }), var event = latestEvent else { return }
        event.type = "command"
        event.timestamp = Date().timeIntervalSince1970
        event.command = command
        enqueue(id: id, event: event)
    }

    private func start(id: String) {
        guard !stopped else { return }
        invalidate(id: id)
        permits[id] = PluginRunPermit()
        if var event = latestEvent {
            event.type = "snapshot"
            event.timestamp = Date().timeIntervalSince1970
            event.previousSession = nil
            event.previousAgents = nil
            enqueue(id: id, event: event)
        }
    }

    private func invalidate(id: String) {
        permits.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)
        for transfer in transfers.removeValue(forKey: id)?.values ?? Dictionary<UUID, PluginTransfer>().values { transfer.cancel() }
        rate.removeValue(forKey: id)
    }

    private func enqueue(id: String, event: PluginEvent) {
        guard let permit = permits[id], permit.isValid else { return }
        guard (pending[id]?.count ?? 0) < 8 else { fail(id: id, message: "Plugin could not keep up with status changes. Enable it to retry."); return }
        pending[id, default: []].append(event)
        executeNext(id: id)
    }

    private func executeNext(id: String) {
        guard !running.contains(id), let permit = permits[id], permit.isValid,
              let item = installed.first(where: { $0.id == id && $0.enabled }),
              var events = pending[id], !events.isEmpty else { return }
        let event = events.removeFirst()
        pending[id] = events
        running.insert(id)
        worker.async {
            let result: Result<[PluginAction], Error> = Result {
                guard permit.isValid else { return [] }
                let invocation = PluginInvocation(package: item.package, event: event,
                                                  settings: try self.values(for: item, requireComplete: true))
                guard permit.isValid else { return [] }
                return try self.execute(invocation)
            }
            DispatchQueue.main.async {
                self.running.remove(id)
                if permit.isValid, !self.stopped {
                    switch result {
                    case .success(let actions):
                        do {
                            guard actions.count <= 16 else { throw PluginError.invalid("Plugin returned too many actions.") }
                            for action in actions { try action.validate(for: item.package, event: event) }
                            for action in actions where permit.isValid { try self.perform(action, id: id, permit: permit) }
                        } catch { self.fail(id: id, message: error.localizedDescription) }
                    case .failure(let failure): self.fail(id: id, message: failure.localizedDescription)
                    }
                }
                self.executeNext(id: id)
            }
        }
    }

    private func perform(_ action: PluginAction, id: String, permit: PluginRunPermit) throws {
        guard permit.isValid, let index = installed.firstIndex(where: { $0.id == id && $0.enabled }) else { return }
        if action.type == "status" {
            installed[index].status = action.text ?? ""
            onChange?()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        rate[id] = (rate[id] ?? []).filter { now - $0 < 60 }
        guard rate[id, default: []].count < 30 else { throw PluginError.invalid("Plugin exceeded 30 actions per minute. Enable it to retry.") }
        rate[id, default: []].append(now)
        switch action.type {
        case "notify":
            let content = UNMutableNotificationContent()
            content.title = action.title ?? ""
            content.body = action.body ?? ""
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "plugin-" + UUID().uuidString,
                                                                        content: content, trigger: nil)) { failure in
                if failure != nil {
                    DispatchQueue.main.async { if permit.isValid { self.fail(id: id, message: "Could not deliver the plugin notification.") } }
                }
            }
        case "openURL":
            if let url = URL(string: action.url ?? ""), !NSWorkspace.shared.open(url) {
                throw PluginError.invalid("Could not open the plugin link.")
            }
        case "http":
            guard (transfers[id]?.count ?? 0) < 4 else { throw PluginError.invalid("Plugin has too many pending network requests.") }
            var request = URLRequest(url: try PluginPackage.httpsURL(action.url ?? ""))
            request.httpMethod = action.method ?? "POST"
            request.httpBody = action.body.map { Data($0.utf8) }
            for (key, value) in action.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            let requestID = UUID()
            let transfer = PluginTransfer(request: request, limit: 64 * 1024) { result in
                DispatchQueue.main.async {
                    self.transfers[id]?[requestID] = nil
                    if case .failure(let failure) = result, permit.isValid { self.fail(id: id, message: failure.localizedDescription) }
                }
            }
            transfers[id, default: [:]][requestID] = transfer
            transfer.start()
        default: throw PluginError.invalid("Unknown plugin action.")
        }
    }

    private func fail(id: String, message: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        invalidate(id: id)
        installed[index].enabled = false
        installed[index].status = ""
        installed[index].error = message
        do { try store.save(installed[index]) }
        catch { self.error = "Plugin stopped, but its disabled state could not be saved." }
        onChange?()
    }

    func shutdown() {
        stopped = true
        for id in Array(permits.keys) { invalidate(id: id) }
        installerTransfer?.cancel()
    }

    static func checkedPackage(_ data: Data, entry: PluginCatalogEntry?) throws -> PluginPackage {
        let package = try PluginPackage.decode(data)
        if let entry {
            try entry.validate()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.sha256, package.id == entry.id, package.version == entry.version,
                  package.name == entry.name, package.author == entry.author, package.description == entry.description else {
                throw PluginError.invalid("Plugin does not match its catalog entry or checksum.")
            }
        }
        return package
    }

    private static func readCatalog(_ directory: URL?) throws -> PluginCatalog {
        guard let directory else { throw PluginError.invalid("Bundled plugin catalog is unavailable.") }
        let data = try PluginFiles.read(directory.appendingPathComponent("catalog.json"), limit: 256 * 1024)
        let catalog = try JSONDecoder().decode(PluginCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }
}
