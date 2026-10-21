import Foundation

enum PluginError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct PluginPermissions: Codable, Equatable {
    var notifications: Bool
    var network: [String]
    var openURLs: Bool

    var descriptions: [String] {
        var values: [String] = []
        if notifications { values.append("Show notifications") }
        values += network.map { "Connect to \($0) over HTTPS" }
        if openURLs { values.append("Open HTTPS links when you run a command") }
        return values.isEmpty ? ["Read WakeGuard status"] : ["Read WakeGuard status"] + values
    }
}

struct PluginSetting: Codable, Equatable, Identifiable {
    var key: String
    var label: String
    var type: String
    var required: Bool
    var defaultValue: String?
    var id: String { key }
}

struct PluginCommand: Codable, Equatable, Identifiable {
    var id: String
    var title: String
}

struct PluginPackage: Codable, Equatable, Identifiable {
    static let maximumBytes = 128 * 1024
    var apiVersion: Int
    var id: String
    var name: String
    var version: String
    var author: String
    var description: String
    var homepage: String?
    var permissions: PluginPermissions
    var settings: [PluginSetting]
    var commands: [PluginCommand]
    var script: String

    static func decode(_ data: Data) throws -> PluginPackage {
        guard data.count <= maximumBytes else { throw PluginError.invalid("Plugin exceeds 128 KiB.") }
        let package: PluginPackage
        do { package = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PluginError.invalid("Invalid plugin file. Check the package format.") }
        try package.validate()
        return package
    }

    func validate() throws {
        guard apiVersion == 1 else { throw PluginError.invalid("This plugin needs a different plugin API version.") }
        guard Self.matches(id, "^[a-z][a-z0-9-]*(\\.[a-z][a-z0-9-]*)+$"), id.count <= 120,
              Self.matches(version, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"), version.count <= 30,
              Self.validText(name, limit: 60), Self.validText(author, limit: 100),
              Self.validText(description, limit: 300), !script.isEmpty, script.utf8.count <= 96 * 1024 else {
            throw PluginError.invalid("Invalid plugin identity, description or script size.")
        }
        if let homepage { _ = try Self.httpsURL(homepage) }
        guard permissions.network.count <= 8, Set(permissions.network).count == permissions.network.count else {
            throw PluginError.invalid("A plugin can request up to eight distinct network hosts.")
        }
        for host in permissions.network {
            guard host == host.lowercased(), host.count <= 253,
                  Self.matches(host, "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"),
                  host.contains("."), !host.contains(".."), !host.contains("*") else {
                throw PluginError.invalid("Network permissions must name exact hosts.")
            }
            let url = try Self.httpsURL("https://" + host)
            guard url.host == host else { throw PluginError.invalid("Invalid network host.") }
        }
        guard settings.count <= 12, Set(settings.map(\.key)).count == settings.count,
              commands.count <= 8, Set(commands.map(\.id)).count == commands.count else {
            throw PluginError.invalid("Too many or duplicate plugin settings or commands.")
        }
        for setting in settings {
            guard Self.matches(setting.key, "^[a-z][a-zA-Z0-9_]{0,39}$"),
                  Self.validText(setting.label, limit: 60), ["text", "secret", "toggle"].contains(setting.type),
                  (setting.defaultValue?.utf8.count ?? 0) <= 2048,
                  setting.type != "secret" || setting.defaultValue == nil,
                  setting.type != "toggle" || setting.defaultValue == nil || ["true", "false"].contains(setting.defaultValue!) else {
                throw PluginError.invalid("Invalid plugin setting.")
            }
        }
        for command in commands {
            guard Self.matches(command.id, "^[a-z][a-zA-Z0-9_-]{0,39}$"), Self.validText(command.title, limit: 60) else {
                throw PluginError.invalid("Invalid plugin command.")
            }
        }
    }

    static func httpsURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 4096, let url = URL(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            throw PluginError.invalid("Use an HTTPS URL without credentials or a custom port.")
        }
        return url
    }

    static func validText(_ text: String, limit: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit &&
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

struct PluginCatalog: Codable {
    var schemaVersion: Int
    var plugins: [PluginCatalogEntry]

    func validate() throws {
        guard schemaVersion == 1, plugins.count <= 200, Set(plugins.map(\.id)).count == plugins.count else {
            throw PluginError.invalid("Invalid plugin catalog.")
        }
        for entry in plugins { try entry.validate() }
    }
}

struct PluginCatalogEntry: Codable, Identifiable {
    var id: String
    var name: String
    var version: String
    var author: String
    var description: String
    var url: String
    var sha256: String

    func validate() throws {
        guard PluginPackage.matches(id, "^[a-z][a-z0-9-]*(\\.[a-z][a-z0-9-]*)+$"), id.count <= 120,
              PluginPackage.validText(name, limit: 60), PluginPackage.validText(author, limit: 100),
              PluginPackage.validText(description, limit: 300),
              PluginPackage.matches(version, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"), version.count <= 30,
              PluginPackage.matches(sha256, "^[a-f0-9]{64}$") else {
            throw PluginError.invalid("Invalid plugin catalog entry.")
        }
        _ = try PluginPackage.httpsURL(url)
    }
}

struct PluginSessionState: Codable, Equatable {
    var active: Bool
    var mode: String
    var reason: String
    var onAC: Bool?
    var battery: Int?
    var thermal: String
    var lidClosed: Bool?
}

struct PluginAgentCounts: Codable, Equatable {
    var working: Int
    var waiting: Int
    var unknown: Int
}

struct PluginEvent: Codable, Equatable {
    var type: String
    var timestamp: Double
    var session: PluginSessionState
    var agents: PluginAgentCounts
    var command: String?
    var previousSession: PluginSessionState? = nil
    var previousAgents: PluginAgentCounts? = nil
}

struct InstalledPlugin: Codable, Identifiable {
    var package: PluginPackage
    var enabled: Bool
    var values: [String: String]
    var source: String
    var status: String = ""
    var error: String? = nil
    var hasSecretHistory: Bool? = nil
    var id: String { package.id }
}

struct PluginInstallReview: Identifiable {
    var package: PluginPackage
    var source: String
    var id: String { package.id }
}

struct PluginInvocation: Codable {
    var package: PluginPackage
    var event: PluginEvent
    var settings: [String: String]
}

struct PluginAction: Codable {
    var type: String
    var text: String?
    var title: String?
    var body: String?
    var url: String?
    var method: String?
    var headers: [String: String]?

    func validate(for package: PluginPackage, event: PluginEvent) throws {
        switch type {
        case "status":
            guard let text, text.isEmpty || PluginPackage.validText(text, limit: 120) else {
                throw PluginError.invalid("Plugin status must contain at most 120 characters.")
            }
        case "notify":
            guard package.permissions.notifications, let title, let body,
                  PluginPackage.validText(title, limit: 100), PluginPackage.validText(body, limit: 500) else {
                throw PluginError.invalid("Notification permission is missing or the message is invalid.")
            }
        case "http":
            guard let url else { throw PluginError.invalid("Missing request URL.") }
            let parsed = try PluginPackage.httpsURL(url)
            guard package.permissions.network.contains(parsed.host ?? ""),
                  ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method ?? "POST"),
                  (body?.utf8.count ?? 0) <= 16 * 1024, (headers?.count ?? 0) <= 12 else {
                throw PluginError.invalid("Request exceeds the plugin's network permissions or limits.")
            }
            for (key, value) in headers ?? [:] {
                guard PluginPackage.matches(key, "^[A-Za-z0-9-]{1,80}$"), value.utf8.count <= 2048,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      !["host", "cookie", "connection", "content-length", "proxy-authorization"].contains(key.lowercased()) else {
                    throw PluginError.invalid("Invalid request header.")
                }
            }
        case "openURL":
            guard package.permissions.openURLs, event.type == "command", let url else {
                throw PluginError.invalid("Links can only open from a plugin command you run.")
            }
            _ = try PluginPackage.httpsURL(url)
        default: throw PluginError.invalid("Unknown plugin action.")
        }
    }
}
