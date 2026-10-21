import Foundation
import Darwin

@main struct PluginRuntimeTests {
    static func main() throws {
        if CommandLine.arguments.dropFirst() == ["--run-plugin"] {
            switch URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent {
            case "oversized-output":
                try FileHandle.standardOutput.write(contentsOf: Data(repeating: 120, count: 64 * 1024 + 1))
                return
            case "invalid-output":
                try FileHandle.standardOutput.write(contentsOf: Data("{invalid}".utf8))
                return
            case "unresponsive-input":
                sleep(10)
                return
            default: break
            }
            PluginRuntime.runFromStandardInput()
            return
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wakeguard-runtime-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        func invocation(_ script: String) -> PluginInvocation {
            PluginInvocation(package: PluginPackage(apiVersion: 1, id: "test.runtime", name: "Runtime test",
                version: "1.0.0", author: "WakeGuard", description: "Runtime fixture", homepage: nil,
                permissions: PluginPermissions(notifications: false, network: [], openURLs: false),
                settings: [], commands: [], script: script),
                event: PluginEvent(type: "statusChanged", timestamp: 1,
                    session: PluginSessionState(active: true, mode: "awake", reason: "", onAC: true,
                                               battery: 80, thermal: "nominal", lidClosed: false),
                    agents: PluginAgentCounts(working: 3, waiting: 1, unknown: 0), command: nil),
                settings: ["label": "working"])
        }
        func run(_ item: PluginInvocation, timeout: TimeInterval = 2, program: URL? = nil) throws -> [PluginAction] {
            let finished = DispatchSemaphore(value: 0)
            var result: Result<[PluginAction], Error>!
            DispatchQueue.global().async {
                result = Result { try PluginRuntime.run(item, executable: program ?? executable, timeout: timeout) }
                finished.signal()
            }
            assert(finished.wait(timeout: .now() + 8) == .success, "Runtime did not return")
            return try result.get()
        }
        func rejects(_ item: PluginInvocation, timeout: TimeInterval = 2, program: URL? = nil) {
            do { _ = try run(item, timeout: timeout, program: program); assertionFailure("Unsafe plugin accepted") }
            catch {}
        }
        let valid = invocation("function onEvent(event, api) { api.setStatus(event.agents.working + ' ' + api.settings.label); }")
        let actions = try run(valid)
        assert(actions.count == 1 && actions[0].type == "status" && actions[0].text == "3 working")
        let empty = try run(invocation("function onEvent() {} "))
        assert(empty.isEmpty)
        rejects(invocation("function onEvent(event, api) { api.notify('Hello', 'Not allowed'); }"))
        rejects(invocation("function onEvent(event, api) { api.http({url:'https://example.com'}); }"))
        rejects(invocation("function onEvent(event, api) { api.openURL('https://example.com'); }"))
        rejects(invocation("throw new Error('secret must not be surfaced');"))
        rejects(invocation("function onEvent() { throw new Error('handler error'); }"))
        rejects(invocation("function onEvent() { return {actions: []}; }"))
        rejects(invocation("async function onEvent(event, api) { api.setStatus('async'); }"))
        rejects(invocation("const onEvent = 42;"))
        rejects(invocation("function onEvent(event, api) { for (let n=0;n<17;n++) api.setStatus('x'); }"))
        rejects(invocation("function onEvent(event, api) { api.setStatus('x'.repeat(70000)); }"))
        rejects(invocation("function onEvent(event, api) { api.setStatus(123); }"))
        rejects(invocation("JSON.stringify = function () { return '{\"actions\":[{\"type\":\"execute\"}]}'; }; function onEvent() {}"))
        rejects(invocation("JSON.stringify = function () { return '{\"actions\":' + '[' + Array(17).fill('{\"type\":\"status\",\"text\":\"x\"}').join(',') + ']}'; }; function onEvent() {}"))
        for name in ["require", "ObjC", "process", "fetch", "XMLHttpRequest", "FileManager", "NSClassFromString"] {
            let unavailable = try run(invocation("function onEvent(event, api) { api.setStatus(typeof " + name + "); }"))
            assert(unavailable[0].text == "undefined", "Native capability exposed: " + name)
        }
        let timeoutStarted = ContinuousClock.now
        rejects(invocation("function onEvent() { while (true) {} }"), timeout: 0.2)
        assert(timeoutStarted.duration(to: .now) < .seconds(2), "Infinite loop did not time out promptly")
        rejects(invocation("while (true) {}"), timeout: 0.2)
        for name in ["oversized-output", "invalid-output", "unresponsive-input"] {
            let fixture = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: executable, to: fixture)
            var item = valid
            if name == "unresponsive-input" { item.settings["large"] = String(repeating: "x", count: 192 * 1024) }
            rejects(item, timeout: 0.2, program: fixture)
        }
        let cpuStarted = ContinuousClock.now
        rejects(invocation("function onEvent() { while (true) {} }"), timeout: 5)
        assert(cpuStarted.duration(to: .now) < .seconds(4), "Child CPU limit did not terminate execution")
        do {
            _ = try run(invocation("const held = []; function onEvent() { for (let n=0;n<40;n++) held.push(new Uint8Array(8*1024*1024).fill(1)); while(true) {} }"))
            assertionFailure("Resident memory limit was not enforced")
        } catch {
            assert(error.localizedDescription == "Plugin exceeded its memory limit.")
        }
        var permitted = invocation("function onEvent(event, api) { api.notify('Done', 'Agents finished'); api.http({url:'https://example.com/hook',method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}); }")
        permitted.package.permissions.notifications = true
        permitted.package.permissions.network = ["example.com"]
        let permittedActions = try run(permitted)
        assert(permittedActions.count == 2)
        var command = invocation("function onEvent(event, api) { api.openURL('https://example.com'); }")
        command.package.permissions.openURLs = true
        command.event.type = "command"
        let commandActions = try run(command)
        assert(commandActions.first?.type == "openURL")
        var excessiveInput = valid
        excessiveInput.settings = ["large": String(repeating: "x", count: 256 * 1024)]
        rejects(excessiveInput)
        do {
            _ = try PluginRuntime.run(valid, executable: executable)
            assertionFailure("Main-thread execution accepted")
        } catch {}
        let following = try run(valid)
        assert(following.first?.text == "3 working", "Failed plugin broke following execution")
        if CommandLine.arguments.count > 1 {
            try checkSamples(directory: URL(fileURLWithPath: CommandLine.arguments[1])) { try run($0) }
        }
        print("Plugin runtime checks passed; no host actions executed")
    }

    static func checkSamples(directory: URL, run: (PluginInvocation) throws -> [PluginAction]) throws {
        func sample(_ id: String) throws -> PluginInvocation {
            let file = directory.appendingPathComponent("io.github.myurtsev." + id).appendingPathComponent("1.0.0.wakeguardplugin")
            let package = try PluginPackage.decode(Data(contentsOf: file))
            return PluginInvocation(package: package,
                event: PluginEvent(type: "snapshot", timestamp: 1,
                    session: PluginSessionState(active: false, mode: "off", reason: "", onAC: true,
                                               battery: 80, thermal: "nominal", lidClosed: false),
                    agents: PluginAgentCounts(working: 0, waiting: 0, unknown: 0), command: nil),
                settings: Dictionary(uniqueKeysWithValues: package.settings.map { ($0.key, $0.defaultValue ?? "") }))
        }
        var session = try sample("session-notifications")
        var actions = try run(session)
        assert(actions.count == 1 && actions[0].text == "Off", "Startup must not announce a session transition")
        session.event.session.active = true
        actions = try run(session)
        assert(actions.count == 1 && actions[0].text == "Session active")
        session.event.type = "stateChanged"
        session.event.previousSession = session.event.session
        session.event.previousSession?.active = false
        actions = try run(session)
        assert(actions.count == 2 && actions[1].type == "notify" && actions[1].title == "WakeGuard started")
        session.settings["notifyOnStart"] = "false"
        actions = try run(session)
        assert(actions.count == 1)
        session.settings["notifyOnStart"] = "true"
        session.event.previousSession = session.event.session
        session.event.session.battery = 79
        actions = try run(session)
        assert(actions.count == 1, "A battery update must not send a session notification")
        session.event.session.active = false
        actions = try run(session)
        assert(actions.count == 2 && actions[1].title == "WakeGuard stopped")
        session.settings["notifyOnStop"] = "false"
        actions = try run(session)
        assert(actions.count == 1)
        session.event.previousSession = nil
        actions = try run(session)
        assert(actions.count == 1)

        var agents = try sample("agent-status")
        actions = try run(agents)
        assert(actions.count == 1 && actions[0].text == "No active agents")
        agents.event.agents = PluginAgentCounts(working: 3, waiting: 1, unknown: 2)
        actions = try run(agents)
        assert(actions[0].text == "3 working · 1 waiting · 2 unavailable")
        agents.event.agents = PluginAgentCounts(working: 0, waiting: 0, unknown: 2)
        actions = try run(agents)
        assert(actions[0].text == "2 unavailable")
        agents.event.command = "detectionHelp"
        actions = try run(agents)
        assert(actions.count == 1, "A command identifier alone must not open a link")
        agents.event.type = "command"
        actions = try run(agents)
        assert(actions.count == 2 && actions[1].type == "openURL" && actions[1].url?.hasSuffix("#agent-detection") == true)
        print("Bundled plugin behavior checks passed")
    }
}
