import Foundation
import JavaScriptCore
import Darwin

enum PluginRuntime {
    private static let maximumInput = 256 * 1024
    private static let maximumOutput = 64 * 1024
    private static let maximumResidentBytes: UInt64 = 256 * 1024 * 1024

    static func run(_ invocation: PluginInvocation, executable: URL,
                    timeout: TimeInterval = 2) throws -> [PluginAction] {
        guard !Thread.isMainThread else { throw PluginError.invalid("Plugins must run off the main thread.") }
        guard timeout.isFinite, timeout > 0, timeout <= 10 else {
            throw PluginError.invalid("Invalid plugin execution timeout.")
        }
        try invocation.package.validate()
        let input = try JSONEncoder().encode(invocation)
        guard input.count <= maximumInput else { throw PluginError.invalid("Plugin input exceeds 256 KiB.") }
        let process = Process()
        let inputPipe = Pipe(), outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--run-plugin"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let writer = inputPipe.fileHandleForWriting, reader = outputPipe.fileHandleForReading
        defer {
            try? writer.close(); try? reader.close()
            try? inputPipe.fileHandleForReading.close(); try? outputPipe.fileHandleForWriting.close()
        }
        for descriptor in [writer.fileDescriptor, reader.fileDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw PluginError.invalid("Cannot configure plugin communication.")
            }
        }
        // A child exiting early must not deliver SIGPIPE to WakeGuard.
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw PluginError.invalid("Cannot configure plugin communication.")
        }
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try inputPipe.fileHandleForReading.close()
        try outputPipe.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var offset = 0, inputClosed = false, outputClosed = false
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !outputClosed || process.isRunning {
            guard ContinuousClock.now < deadline else { throw PluginError.invalid("Plugin execution timed out.") }
            if process.isRunning {
                var info = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                // Sample resident memory, not JSC's much larger virtual address reservations.
                if proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &info, size) == size,
                   info.pti_resident_size > maximumResidentBytes {
                    throw PluginError.invalid("Plugin exceeded its memory limit.")
                }
            }
            if !inputClosed {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(writer.fileDescriptor, bytes.baseAddress!.advanced(by: offset), input.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw PluginError.invalid("Plugin input could not be delivered.")
                }
                if offset == input.count {
                    try writer.close()
                    inputClosed = true
                }
            }
            if !outputClosed {
                while true {
                    let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
                    if count > 0 {
                        guard output.count + count <= maximumOutput else {
                            throw PluginError.invalid("Plugin output exceeds 64 KiB.")
                        }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 {
                        outputClosed = true
                        break
                    } else if errno == EAGAIN { break }
                    else if errno != EINTR { throw PluginError.invalid("Plugin output could not be read.") }
                }
            }
            if outputClosed && !process.isRunning { break }
            var descriptors = [pollfd(fd: outputClosed ? -1 : reader.fileDescriptor, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: inputClosed ? -1 : writer.fileDescriptor, events: Int16(POLLOUT), revents: 0)]
            if poll(&descriptors, nfds_t(descriptors.count), 10) < 0 && errno != EINTR {
                throw PluginError.invalid("Plugin communication failed.")
            }
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PluginError.invalid("Plugin execution failed.")
        }
        struct Response: Decodable { let actions: [PluginAction] }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: output) }
        catch { throw PluginError.invalid("Plugin returned invalid actions.") }
        guard response.actions.count <= 16 else { throw PluginError.invalid("Plugin returned too many actions.") }
        for action in response.actions { try action.validate(for: invocation.package, event: invocation.event) }
        return response.actions
    }

    static func runFromStandardInput() {
        do {
            var cpuLimit = rlimit(rlim_cur: 2, rlim_max: 3)
            var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
            guard setrlimit(RLIMIT_CPU, &cpuLimit) == 0, setrlimit(RLIMIT_CORE, &coreLimit) == 0 else {
                throw PluginError.invalid("Cannot set plugin resource limits.")
            }
            var input = Data()
            while true {
                let chunk = FileHandle.standardInput.readData(ofLength: 8192)
                if chunk.isEmpty { break }
                guard input.count + chunk.count <= maximumInput else { throw PluginError.invalid("Plugin input is too large.") }
                input.append(chunk)
            }
            let invocation = try JSONDecoder().decode(PluginInvocation.self, from: input)
            try invocation.package.validate()
            guard let context = JSContext() else { throw PluginError.invalid("Cannot create plugin context.") }
            context.evaluateScript(invocation.package.script)
            guard context.exception == nil else { throw PluginError.invalid("Plugin script failed.") }
            let event = String(decoding: try JSONEncoder().encode(invocation.event), as: UTF8.self)
            let settings = String(decoding: try JSONEncoder().encode(invocation.settings), as: UTF8.self)
            let bootstrap = """
            (function () {
                if (typeof onEvent !== 'function') throw new Error('Define onEvent(event, api).');
                const actions = [];
                const add = function (action) {
                    if (actions.length >= 16) throw new Error('Too many actions.');
                    actions.push(action);
                };
                const api = Object.freeze({
                    settings: Object.freeze(\(settings)),
                    setStatus: function (text) { add({type: 'status', text: text}); },
                    notify: function (title, body) { add({type: 'notify', title: title, body: body}); },
                    http: function (request) {
                        add({type: 'http', url: request.url, method: request.method,
                             headers: request.headers, body: request.body});
                    },
                    openURL: function (url) { add({type: 'openURL', url: url}); }
                });
                const result = onEvent(\(event), api);
                if (result !== undefined) throw new Error('onEvent must complete synchronously without returning a value.');
                return JSON.stringify({actions: actions});
            })()
            """
            let result = context.evaluateScript(bootstrap)
            guard context.exception == nil, let result, result.isString, let text = result.toString() else {
                throw PluginError.invalid("Plugin handler failed.")
            }
            let output = Data(text.utf8)
            guard output.count <= maximumOutput else { throw PluginError.invalid("Plugin output is too large.") }
            try FileHandle.standardOutput.write(contentsOf: output)
            exit(0)
        } catch {
            fputs("Plugin execution failed.\n", stderr)
            exit(1)
        }
    }
}
