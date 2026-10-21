import Foundation
import CryptoKit
import Darwin

private final class PluginExecutionProbe {
    private let lock = NSLock()
    private var recorded: [PluginInvocation] = []
    private var steps: [(DispatchSemaphore?, Result<[PluginAction], Error>)] = []

    var calls: [PluginInvocation] { lock.lock(); defer { lock.unlock() }; return recorded }

    func next(gate: DispatchSemaphore? = nil, result: Result<[PluginAction], Error>) {
        lock.lock(); steps.append((gate, result)); lock.unlock()
    }

    func execute(_ invocation: PluginInvocation) throws -> [PluginAction] {
        lock.lock()
        recorded.append(invocation)
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        if let step { step.0?.wait(); return try step.1.get() }
        return [PluginAction(type: "status", text: "\(invocation.event.type):\(invocation.event.agents.working)")]
    }
}

@main struct PluginManagerTests {
    static func waitUntil(_ label: String, _ condition: () -> Bool) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition() && ContinuousClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        assert(condition(), "Timed out: " + label)
    }

    static func rejects(line: UInt = #line, _ operation: () throws -> Void) {
        do { try operation(); assertionFailure("Unsafe plugin input accepted", line: line) } catch {}
    }

    static func package(id: String = "test.manager") -> PluginPackage {
        PluginPackage(apiVersion: 1, id: id, name: "Manager fixture", version: "1.0.0", author: "WakeGuard",
                      description: "Plugin manager fixture", homepage: nil,
                      permissions: PluginPermissions(notifications: false, network: [], openURLs: false),
                      settings: [PluginSetting(key: "label", label: "Label", type: "text", required: true, defaultValue: "Ready")],
                      commands: [PluginCommand(id: "inspect", title: "Inspect")], script: "function onEvent(event, api) {}")
    }

    static func event(working: Int = 1) -> PluginEvent {
        PluginEvent(type: "ignored", timestamp: 1,
                    session: PluginSessionState(active: true, mode: "awake", reason: "", onAC: true,
                                               battery: 80, thermal: "nominal", lidClosed: false),
                    agents: PluginAgentCounts(working: working, waiting: 0, unknown: 0), command: nil)
    }

    static func main() throws {
        assert(Thread.isMainThread)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("wakeguard-manager-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) :
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("public/plugins")
        try checkContracts(bundled: bundled)
        try checkStore(root: root)
        checkTransfers()
        try checkManager(root: root, bundled: bundled)
        print("Plugin manager checks passed; no Keychain, notification, browser or network actions executed")
    }

    static func checkContracts(bundled: URL) throws {
        let base = package()
        try base.validate()
        let decodedBase = try PluginPackage.decode(JSONEncoder().encode(base))
        assert(decodedBase == base)
        rejects { _ = try PluginPackage.decode(Data("{}".utf8)) }
        rejects { _ = try PluginPackage.decode(Data(repeating: 32, count: PluginPackage.maximumBytes + 1)) }
        for id in ["../escape", "test/escape", "test..escape", "Test.plugin", "single"] {
            var invalid = base; invalid.id = id; rejects { try invalid.validate() }
        }
        for version in ["1", "1.0", "01.0.0", "1.0.0/../../escape", "1.0.0-beta"] {
            var invalid = base; invalid.version = version; rejects { try invalid.validate() }
        }
        var invalid = base
        invalid.apiVersion = 2; rejects { try invalid.validate() }
        invalid = base; invalid.script = String(repeating: "x", count: 96 * 1024 + 1); rejects { try invalid.validate() }
        invalid = base; invalid.name = "Bad\nname"; rejects { try invalid.validate() }
        for hosts in [["*.example.com"], ["Example.com"], ["example.com", "example.com"], ["example..com"], ["https://example.com"]] {
            invalid = base; invalid.permissions.network = hosts; rejects { try invalid.validate() }
        }
        invalid = base; invalid.settings.append(invalid.settings[0]); rejects { try invalid.validate() }
        invalid = base; invalid.settings[0].type = "execute"; rejects { try invalid.validate() }
        invalid = base; invalid.settings[0].type = "secret"; rejects { try invalid.validate() }
        invalid = base; invalid.commands.append(invalid.commands[0]); rejects { try invalid.validate() }
        for url in ["http://example.com", "file:///tmp/test", "https://user:secret@example.com", "https://example.com:8443", "javascript:alert(1)"] {
            rejects { _ = try PluginPackage.httpsURL(url) }
        }
        _ = try PluginPackage.httpsURL("https://example.com/path?value=1")
        var permitted = base
        permitted.permissions.network = ["example.com"]
        permitted.permissions.openURLs = true
        let request = PluginAction(type: "http", body: "{}", url: "https://example.com/hook", method: "POST", headers: ["Authorization": "Bearer fixture"])
        try request.validate(for: permitted, event: event())
        rejects { try request.validate(for: base, event: event()) }
        for headers in [["Authorization": "Bearer x\r\nInjected: yes"], ["Host": "other.example.com"], ["Cookie": "secret"], ["Content-Length": "0"]] {
            var action = request; action.headers = headers; rejects { try action.validate(for: permitted, event: event()) }
        }
        var wrongHost = request; wrongHost.url = "https://sub.example.com/hook"
        rejects { try wrongHost.validate(for: permitted, event: event()) }
        let link = PluginAction(type: "openURL", url: "https://example.com")
        rejects { try link.validate(for: permitted, event: event()) }
        var commandEvent = event(); commandEvent.type = "command"; commandEvent.command = "inspect"
        try link.validate(for: permitted, event: commandEvent)
        rejects { try PluginAction(type: "execute").validate(for: permitted, event: commandEvent) }
        rejects { try PluginAction(type: "notify", title: "Hello", body: "World").validate(for: permitted, event: event()) }
        rejects { try PluginManager.validateValues(["label": ""], package: base, requireComplete: true) }
        rejects { try PluginManager.validateValues(["label": String(repeating: "x", count: 2049)], package: base, requireComplete: true) }
        var toggle = base; toggle.settings[0].type = "toggle"; toggle.settings[0].defaultValue = "true"
        rejects { try PluginManager.validateValues(["label": "yes"], package: toggle, requireComplete: true) }

        let catalog = try JSONDecoder().decode(PluginCatalog.self, from: PluginFiles.read(bundled.appendingPathComponent("catalog.json"), limit: 256 * 1024))
        try catalog.validate()
        assert(catalog.plugins.count >= 2)
        for entry in catalog.plugins {
            let file = bundled.appendingPathComponent(entry.id).appendingPathComponent(entry.version + ".wakeguardplugin")
            let data = try PluginFiles.read(file, limit: PluginPackage.maximumBytes)
            let decoded = try PluginManager.checkedPackage(data, entry: entry)
            assert(decoded.id == entry.id)
            var changed = entry; changed.sha256 = String(repeating: "0", count: 64)
            rejects { _ = try PluginManager.checkedPackage(data, entry: changed) }
            changed = entry; changed.name = "Different plugin"
            rejects { _ = try PluginManager.checkedPackage(data, entry: changed) }
        }
        var duplicate = catalog; duplicate.plugins.append(catalog.plugins[0]); rejects { try duplicate.validate() }
    }

    static func checkStore(root: URL) throws {
        let store = PluginStore(directory: root.appendingPathComponent("store"))
        let fixture = InstalledPlugin(package: package(), enabled: true,
                                      values: ["label": "Custom", "undeclared": "drop"], source: "Fixture", status: "Transient", error: "Transient")
        try store.save(fixture)
        let loaded = try store.load()
        assert(loaded.errors.isEmpty && loaded.plugins.count == 1)
        assert(loaded.plugins[0].enabled && loaded.plugins[0].values == ["label": "Custom"])
        assert(loaded.plugins[0].status.isEmpty && loaded.plugins[0].error == "Transient")
        var metadata = stat()
        assert(lstat(store.directory.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o700)
        let file = store.directory.appendingPathComponent(fixture.id + ".json")
        assert(lstat(file.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600)
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("linked.json"), withDestinationURL: file)
        try Data(repeating: 120, count: 192 * 1024 + 1).write(to: store.directory.appendingPathComponent("oversized.json"))
        try Data("{broken}".utf8).write(to: store.directory.appendingPathComponent("broken.json"))
        try JSONEncoder().encode(fixture).write(to: store.directory.appendingPathComponent("wrong-name.json"))
        let partial = try store.load()
        assert(partial.plugins.count == 1 && partial.errors.count == 4)
        let external = root.appendingPathComponent("untouched")
        try Data("untouched".utf8).write(to: external)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        rejects { try store.save(fixture) }
        rejects { try store.remove(fixture.id) }
        let untouched = try Data(contentsOf: external)
        assert(untouched == Data("untouched".utf8))
        let linkedDirectory = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: store.directory)
        rejects { _ = try PluginStore(directory: linkedDirectory).load() }
        rejects { try store.remove("../../escape") }
        let many = PluginStore(directory: root.appendingPathComponent("many"))
        for number in 0..<33 {
            try many.save(InstalledPlugin(package: package(id: "test.plugin-\(number)"), enabled: false, values: [:], source: "Fixture"))
        }
        rejects { _ = try many.load() }
    }

    static func checkTransfers() {
        let request = URLRequest(url: URL(string: "https://example.com/plugin")!)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        var received: Result<Data, Error>?
        let transfer = PluginTransfer(request: request, limit: 4) { received = $0 }
        let redirect = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.example.com"])!
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: request) { assert($0 == nil) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "4"])!
        transfer.urlSession(session, dataTask: task, didReceive: response) { assert($0 == .allow) }
        transfer.urlSession(session, dataTask: task, didReceive: Data("1234".utf8))
        transfer.urlSession(session, task: task, didCompleteWithError: nil)
        if case .success(let data) = received { assert(data == Data("1234".utf8)) }
        else { assertionFailure("Valid bounded transfer rejected") }
        let overflowing = PluginTransfer(request: request, limit: 4) { received = $0 }
        overflowing.urlSession(session, dataTask: task, didReceive: Data("12345".utf8))
        overflowing.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        if case .failure = received {} else { assertionFailure("Oversized streamed response accepted") }
        for headers in [["Content-Length": "5"]] {
            let declared = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            let rejecting = PluginTransfer(request: request, limit: 4) { _ in }
            rejecting.urlSession(session, dataTask: task, didReceive: declared) { assert($0 == .cancel) }
        }
        for url in ["http://example.com", "https://example.com"] {
            let bad = HTTPURLResponse(url: URL(string: url)!, statusCode: url.hasPrefix("http:") ? 200 : 302, httpVersion: nil, headerFields: nil)!
            transfer.urlSession(session, dataTask: task, didReceive: bad) { assert($0 == .cancel) }
        }
    }

    static func checkManager(root: URL, bundled: URL) throws {
        let probe = PluginExecutionProbe()
        let store = PluginStore(directory: root.appendingPathComponent("manager"))
        let manager = PluginManager(store: store, bundledDirectory: bundled, execute: probe.execute)
        defer { manager.shutdown() }
        waitUntil("initial load") { !manager.isBusy }
        assert(manager.installed.isEmpty && manager.available.count >= 2 && manager.catalogError == nil)
        var statuses: [String] = []
        manager.onChange = { statuses += manager.installed.map(\.status) }
        let fixture = package()
        let file = root.appendingPathComponent("fixture.wakeguardplugin")
        try JSONEncoder().encode(fixture).write(to: file)
        let firstOpen = PluginManager(store: PluginStore(directory: root.appendingPathComponent("first-open")),
                                      bundledDirectory: bundled, execute: probe.execute)
        firstOpen.prepareInstall(file: file)
        waitUntil("open file during initial load") { !firstOpen.isBusy && firstOpen.review?.id == fixture.id }
        assert(firstOpen.installed.isEmpty)
        firstOpen.cancelInstall()
        firstOpen.shutdown()
        manager.publish(event())
        manager.prepareInstall(file: file)
        waitUntil("install review") { !manager.isBusy && manager.review != nil }
        assert(manager.installed.isEmpty && probe.calls.isEmpty)
        manager.cancelInstall()
        assert(manager.review == nil && manager.installed.isEmpty)
        manager.prepareInstall(file: file)
        waitUntil("second review") { !manager.isBusy && manager.review != nil }
        manager.confirmInstall()
        waitUntil("confirmed disabled install") { !manager.isBusy && manager.installed.count == 1 }
        assert(!manager.installed[0].enabled && probe.calls.isEmpty)
        manager.setEnabled(id: fixture.id, enabled: true)
        waitUntil("explicit enable") { !manager.isBusy && manager.installed[0].status == "snapshot:1" }
        assert(probe.calls.count == 1 && probe.calls[0].settings["label"] == "Ready")
        var same = event(); same.timestamp = 999
        manager.publish(same)
        manager.runCommand(id: fixture.id, command: "missing")
        assert(probe.calls.count == 1)
        manager.publish(event(working: 2))
        waitUntil("state change") { manager.installed[0].status == "stateChanged:2" }
        assert(probe.calls.count == 2, "Unchanged snapshots should not enqueue plugin work")
        assert(probe.calls.last?.event.previousAgents?.working == 1)
        manager.runCommand(id: fixture.id, command: "inspect")
        waitUntil("declared command") { manager.installed[0].status == "command:2" }
        assert(probe.calls.last?.event.command == "inspect")

        var saved = false
        manager.saveSettings(id: fixture.id, values: ["label": "Custom"]) { saved = $0 }
        waitUntil("settings saved") { saved && !manager.isBusy && probe.calls.last?.settings["label"] == "Custom" }
        var settings: [String: String]?
        manager.settingsValues(id: fixture.id) { settings = $0 }
        waitUntil("settings read") { settings != nil }
        assert(settings?["label"] == "Custom")
        var invalidSaved: Bool?
        manager.saveSettings(id: fixture.id, values: ["label": ""]) { invalidSaved = $0 }
        waitUntil("invalid settings rejected") { invalidSaved != nil }
        assert(invalidSaved == false && manager.installed[0].enabled && manager.installed[0].values["label"] == "Custom")
        manager.shutdown()
        let reloadedProbe = PluginExecutionProbe()
        let reloaded = PluginManager(store: store, bundledDirectory: bundled, execute: reloadedProbe.execute)
        defer { reloaded.shutdown() }
        reloaded.publish(event(working: 3))
        waitUntil("enabled state after restart") { !reloaded.isBusy && reloaded.installed.first?.status == "snapshot:3" }
        assert(reloadedProbe.calls.last?.settings["label"] == "Custom")
        reloaded.onChange = { statuses += reloaded.installed.map(\.status) }

        var heartbeat = 0
        let timer = Timer(timeInterval: 0.005, repeats: true) { _ in heartbeat += 1 }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let held = DispatchSemaphore(value: 0)
        reloadedProbe.next(gate: held, result: .success([PluginAction(type: "status", text: "STALE")]))
        let count = reloadedProbe.calls.count
        reloaded.publish(event(working: 4))
        waitUntil("held invocation") { reloadedProbe.calls.count == count + 1 }
        waitUntil("main-loop heartbeat during held plugin") { heartbeat >= 3 }
        reloaded.setEnabled(id: fixture.id, enabled: false)
        held.signal()
        waitUntil("disabled state") { !reloaded.isBusy && reloaded.installed.first?.enabled == false }
        reloaded.setEnabled(id: fixture.id, enabled: true)
        waitUntil("reenabled after stale result") { !reloaded.isBusy && reloaded.installed.first?.status == "snapshot:4" }
        assert(!statuses.contains("STALE") && heartbeat > 0)

        let failedWriteGate = DispatchSemaphore(value: 0)
        reloadedProbe.next(gate: failedWriteGate, result: .success([PluginAction(type: "status", text: "STALE")]))
        let beforeFailedWrite = reloadedProbe.calls.count
        reloaded.publish(event(working: 42))
        waitUntil("failed disable held invocation") { reloadedProbe.calls.count == beforeFailedWrite + 1 }
        let configFile = store.directory.appendingPathComponent(fixture.id + ".json")
        let untouchedTarget = root.appendingPathComponent("disable-failure-target")
        try Data("untouched".utf8).write(to: untouchedTarget)
        try FileManager.default.removeItem(at: configFile)
        try FileManager.default.createSymbolicLink(at: configFile, withDestinationURL: untouchedTarget)
        reloaded.setEnabled(id: fixture.id, enabled: false)
        assert(reloaded.installed.first?.enabled == false && reloaded.error != nil)
        failedWriteGate.signal()
        try FileManager.default.removeItem(at: configFile)
        try store.save(reloaded.installed[0])
        reloaded.setEnabled(id: fixture.id, enabled: true)
        waitUntil("retry after failed disable persistence") { !reloaded.isBusy && reloaded.installed.first?.status == "snapshot:42" }
        assert(!statuses.contains("STALE"))
        let untouchedAfterDisable = try Data(contentsOf: untouchedTarget)
        assert(untouchedAfterDisable == Data("untouched".utf8))

        var update = fixture; update.version = "1.0.1"
        try JSONEncoder().encode(update).write(to: file)
        reloaded.prepareInstall(file: file)
        waitUntil("update review") { !reloaded.isBusy && reloaded.review?.package.version == "1.0.1" }
        let updateGate = DispatchSemaphore(value: 0)
        reloadedProbe.next(gate: updateGate, result: .success([PluginAction(type: "status", text: "STALE")]))
        let beforeUpdate = reloadedProbe.calls.count
        reloaded.publish(event(working: 5))
        waitUntil("update held invocation") { reloadedProbe.calls.count == beforeUpdate + 1 }
        reloaded.confirmInstall()
        updateGate.signal()
        waitUntil("update installed disabled") { !reloaded.isBusy && reloaded.installed.first?.package.version == "1.0.1" }
        assert(reloaded.installed.first?.enabled == false && !statuses.contains("STALE"))
        assert(reloaded.installed.first?.values["label"] == "Custom")

        reloaded.setEnabled(id: fixture.id, enabled: true)
        waitUntil("enable updated plugin") { !reloaded.isBusy && reloaded.installed.first?.status == "snapshot:5" }
        reloadedProbe.next(result: .failure(PluginError.invalid("Fixture failure")))
        reloaded.publish(event(working: 6))
        waitUntil("failure disables plugin") { reloaded.installed.first?.enabled == false && reloaded.installed.first?.error != nil }
        let failedStore = try store.load()
        assert(failedStore.plugins.first?.enabled == false && failedStore.plugins.first?.error == "Fixture failure")
        reloaded.setEnabled(id: fixture.id, enabled: true)
        waitUntil("retry after failure") { !reloaded.isBusy && reloaded.installed.first?.status == "snapshot:6" }
        reloadedProbe.next(result: .success([PluginAction(type: "status", text: "UNVALIDATED"), PluginAction(type: "notify", title: "Denied", body: "Denied")]))
        reloaded.publish(event(working: 7))
        waitUntil("invalid action disables plugin") { reloaded.installed.first?.enabled == false && reloaded.installed.first?.error != nil }
        assert(!statuses.contains("UNVALIDATED"))
        reloaded.setEnabled(id: fixture.id, enabled: true)
        waitUntil("retry after invalid action") { !reloaded.isBusy && reloaded.installed.first?.status == "snapshot:7" }
        let removeGate = DispatchSemaphore(value: 0)
        reloadedProbe.next(gate: removeGate, result: .success([PluginAction(type: "status", text: "STALE")]))
        let beforeRemove = reloadedProbe.calls.count
        reloaded.publish(event(working: 8))
        waitUntil("remove held invocation") { reloadedProbe.calls.count == beforeRemove + 1 }
        reloaded.remove(id: fixture.id)
        removeGate.signal()
        waitUntil("removed") { !reloaded.isBusy && reloaded.installed.isEmpty }
        assert(!statuses.contains("STALE"))
        let removedStore = try store.load()
        assert(removedStore.plugins.isEmpty)

        let catalogEntry = reloaded.available.first { $0.id == "io.github.myurtsev.agent-status" }!
        reloaded.prepareInstall(entry: catalogEntry)
        waitUntil("bundled catalog review") { !reloaded.isBusy && reloaded.review != nil }
        assert(reloaded.review?.id == catalogEntry.id)
        reloaded.cancelInstall()
        var mismatch = catalogEntry; mismatch.sha256 = String(repeating: "0", count: 64)
        reloaded.prepareInstall(entry: mismatch)
        waitUntil("catalog mismatch rejection") { !reloaded.isBusy && reloaded.error != nil }
        assert(reloaded.review == nil)
        reloaded.prepareInstall(url: "http://example.com/plugin")
        assert(reloaded.error != nil && !reloaded.isBusy)
        reloaded.shutdown()
        let afterShutdown = reloadedProbe.calls.count
        reloaded.publish(event(working: 9))
        reloaded.setEnabled(id: fixture.id, enabled: true)
        assert(reloadedProbe.calls.count == afterShutdown)
        let stoppedStore = PluginStore(directory: root.appendingPathComponent("stopped-load"))
        try stoppedStore.save(InstalledPlugin(package: fixture, enabled: true, values: ["label": "Ready"], source: "Fixture"))
        let stoppedProbe = PluginExecutionProbe()
        let stopped = PluginManager(store: stoppedStore, bundledDirectory: bundled, execute: stoppedProbe.execute)
        stopped.publish(event())
        stopped.shutdown()
        waitUntil("shutdown during initial load") { !stopped.isBusy }
        assert(stoppedProbe.calls.isEmpty)
    }
}
