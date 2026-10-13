import Foundation
import Darwin

enum ClaudeHooks {
    static let command = "\"/Applications/WakeGuard.app/Contents/MacOS/WakeGuard\" --claude-event"
    private static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                 "PostToolUseFailure", "PermissionRequest", "Elicitation", "ElicitationResult", "SubagentStart", "SubagentStop",
                                 "Stop", "StopFailure", "SessionEnd", "Notification"]

    static func isEnabled(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Bool {
        let directory = home.appendingPathComponent(".claude")
        var info = stat()
        if lstat(directory.path, &info) != 0, errno == ENOENT { return false }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw failure("Unsafe Claude directory permissions")
        }
        guard let data = try readSettings(directory.appendingPathComponent("settings.json")),
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = document["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
    }

    static func merged(_ data: Data?, enabled: Bool) throws -> Data {
        var document: [String: Any] = [:]
        if let data {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw failure("Claude settings must be a JSON object")
            }
            document = object
        }
        var hooks: [String: Any]
        if let existing = document["hooks"] {
            guard let valid = existing as? [String: Any] else { throw failure("Unsupported Claude hooks format") }
            hooks = valid
        } else { hooks = [:] }
        for event in events {
            var groups: [[String: Any]] = []
            if let existing = hooks[event] {
                guard let valid = existing as? [[String: Any]] else { throw failure("Unsupported Claude event format") }
                groups = valid
            }
            var preserved: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw failure("Unsupported Claude hook format") }
                let remaining = handlers.filter { ($0["command"] as? String) != command }
                if !remaining.isEmpty || remaining.count == handlers.count {
                    group["hooks"] = remaining; preserved.append(group)
                }
            }
            if enabled {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 3]]]
                if event == "Notification" {
                    group["matcher"] = "idle_prompt|permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled"
                }
                preserved.append(group)
            }
            if preserved.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = preserved }
        }
        document["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    static func setEnabled(_ enabled: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
            throw failure("Cannot create Claude settings directory")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw failure("Unsafe Claude directory permissions")
        }
        let path = directory.appendingPathComponent("settings.json")
        let original = try readSettings(path)
        let updated = try merged(original, enabled: enabled)
        let temporary = directory.appendingPathComponent(".wakeguard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writePrivate(updated, to: temporary)
        guard try readSettings(path) == original else { throw failure("Claude settings changed; try again") }
        if original != nil {
            let backupName = "wakeguard-backup-\(UUID().uuidString).json"
            _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary, backupItemName: backupName,
                                                      options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
            let backup = directory.appendingPathComponent(backupName)
            guard try readSettings(backup, makePrivate: true) == original else {
                throw failure("Concurrent Claude settings change saved to \(backup.path); check settings.json before continuing")
            }
        } else {
            try FileManager.default.moveItem(at: temporary, to: path)
        }
    }

    private static func readSettings(_ url: URL, makePrivate: Bool = false) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("Cannot safely read Claude settings") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o022 == 0,
              info.st_size >= 0, info.st_size <= 1_048_576 else {
            throw failure("Unsafe Claude settings permissions or size")
        }
        if makePrivate && fchmod(fd, 0o600) != 0 { throw failure("Cannot protect Claude settings backup") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 1_048_576 else { throw failure("Claude settings exceed size limit") }
        return data
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("Cannot create Claude settings file") }
        defer { close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw failure("Cannot save Claude settings file") }
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: WakePaths.bundleID, code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
