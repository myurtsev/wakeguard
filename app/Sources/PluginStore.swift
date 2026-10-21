import Foundation
import Darwin

enum PluginFiles {
    static func read(_ url: URL, limit: Int, requireOwner: Bool = false) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw PluginError.invalid("Cannot open plugin file.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit,
              !requireOwner || info.st_uid == getuid() else {
            throw PluginError.invalid("Plugin file is not a regular file or exceeds its size limit.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PluginError.invalid("Cannot read plugin file.") }
            if count == 0 { return data }
            guard data.count + count <= limit else { throw PluginError.invalid("Plugin file exceeds its size limit.") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func checkDirectory(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = Array(url.standardizedFileURL.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                let kind = info.st_mode & S_IFMT
                // macOS exposes system-owned ancestor aliases such as /var and /tmp.
                let systemAlias = kind == S_IFLNK && info.st_uid == 0 && index < components.count - 1
                guard kind == S_IFDIR || systemAlias else {
                    throw PluginError.invalid("Plugin storage must not contain symbolic links or non-directories.")
                }
            } else if errno != ENOENT {
                throw PluginError.invalid("Cannot inspect plugin storage.")
            }
        }
    }
}

final class PluginStore {
    let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WakeGuard/Plugins", isDirectory: true)) {
        self.directory = directory.standardizedFileURL
    }

    func load() throws -> (plugins: [InstalledPlugin], errors: [String]) {
        try prepareDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 32 else { throw PluginError.invalid("Too many installed plugin files (maximum 32).") }
        var plugins: [InstalledPlugin] = []
        var errors: [String] = []
        for file in files {
            do {
                let data = try PluginFiles.read(file, limit: 192 * 1024, requireOwner: true)
                var item = try JSONDecoder().decode(InstalledPlugin.self, from: data)
                try item.package.validate()
                guard file.lastPathComponent == item.id + ".json" else { throw PluginError.invalid("Plugin filename does not match its identity.") }
                item.values = try cleanValues(item.values, package: item.package)
                item.status = ""
                plugins.append(item)
            } catch { errors.append("Could not load \(file.lastPathComponent): \(error.localizedDescription)") }
        }
        return (plugins, errors)
    }

    func save(_ item: InstalledPlugin) throws {
        try item.package.validate()
        try prepareDirectory()
        let file = directory.appendingPathComponent(item.id + ".json")
        try rejectLink(file)
        var stored = item
        stored.values = try cleanValues(item.values, package: item.package)
        stored.status = ""
        let data = try JSONEncoder().encode(stored)
        guard data.count <= 192 * 1024 else { throw PluginError.invalid("Plugin configuration exceeds its size limit.") }
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw PluginError.invalid("Cannot protect plugin settings.") }
    }

    func remove(_ id: String) throws {
        guard PluginPackage.matches(id, "^[a-z][a-z0-9-]*(\\.[a-z][a-z0-9-]*)+$"), id.count <= 120 else {
            throw PluginError.invalid("Invalid plugin identity.")
        }
        try prepareDirectory()
        let file = directory.appendingPathComponent(id + ".json")
        try rejectLink(file)
        try FileManager.default.removeItem(at: file)
    }

    private func cleanValues(_ values: [String: String], package: PluginPackage) throws -> [String: String] {
        var result: [String: String] = [:]
        for setting in package.settings where setting.type != "secret" {
            if let value = values[setting.key] {
                guard value.utf8.count <= 2048, setting.type != "toggle" || ["true", "false"].contains(value) else {
                    throw PluginError.invalid("Invalid plugin setting value.")
                }
                result[setting.key] = value
            }
        }
        return result
    }

    private func prepareDirectory() throws {
        try PluginFiles.checkDirectory(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else {
            throw PluginError.invalid("Cannot protect plugin storage.")
        }
    }

    private func rejectLink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                throw PluginError.invalid("Plugin settings must be a regular file owned by your account.")
            }
        } else if errno != ENOENT { throw PluginError.invalid("Cannot inspect plugin settings.") }
    }
}
