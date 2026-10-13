import Foundation
import Darwin

@main struct ClaudeHooksTests {
    static func main() throws {
        let original = Data("{\"env\":{\"EXAMPLE\":\"preserve\"},\"hooks\":{\"SessionStart\":[{\"matcher\":\"startup\",\"hooks\":[{\"type\":\"command\",\"command\":\"existing-notifier\"}]}],\"OtherEvent\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"another\"}]}]}}".utf8)
        let merged = try ClaudeHooks.merged(original, enabled: true)
        let again = try ClaudeHooks.merged(merged, enabled: true)
        assert(merged == again)
        let object = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        assert((object["env"] as! [String: String])["EXAMPLE"] == "preserve")
        let hooks = object["hooks"] as! [String: [[String: Any]]]
        assert(hooks["SessionStart"]!.count == 2)
        assert((hooks["SessionStart"]![0]["hooks"] as! [[String: String]])[0]["command"] == "existing-notifier")
        assert(hooks["OtherEvent"]!.count == 1)
        let removed = try ClaudeHooks.merged(merged, enabled: false)
        let decoded = try JSONSerialization.jsonObject(with: removed) as! NSDictionary
        let initial = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        assert(decoded == initial)
        for invalid in ["[]", "{\"hooks\":[]}", "{\"hooks\":{\"Stop\":{}}}", "{\"hooks\":{\"Stop\":[{}]}}"] {
            do { _ = try ClaudeHooks.merged(Data(invalid.utf8), enabled: true); assertionFailure("Invalid hooks accepted") } catch {}
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wakeguard-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        try ClaudeHooks.setEnabled(true, home: home)
        let connected = try ClaudeHooks.isEnabled(home: home)
        assert(connected)
        let directory = home.appendingPathComponent(".claude")
        let settings = directory.appendingPathComponent("settings.json")
        var info = stat()
        assert(lstat(settings.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let beforeRemoval = try Data(contentsOf: settings)
        try ClaudeHooks.setEnabled(false, home: home)
        let disconnected = try ClaudeHooks.isEnabled(home: home)
        assert(!disconnected)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("wakeguard-backup-") }
        assert(backups.count == 1)
        let backupBytes = try Data(contentsOf: backups[0])
        assert(backupBytes == beforeRemoval)
        assert(lstat(backups[0].path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let disabled = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        assert((disabled["hooks"] as! [String: Any]).isEmpty)
        try FileManager.default.removeItem(at: settings)
        let target = home.appendingPathComponent("target")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        do { try ClaudeHooks.setEnabled(true, home: home); assertionFailure("Symlink accepted") } catch {}
        do { _ = try ClaudeHooks.isEnabled(home: home); assertionFailure("Symlink read accepted") } catch {}
        let preservedTarget = try Data(contentsOf: target)
        assert(preservedTarget == original)
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.linkItem(at: target, to: settings)
        do { try ClaudeHooks.setEnabled(true, home: home); assertionFailure("Hardlink accepted") } catch {}
        assert(lstat(target.path, &info) == 0 && info.st_nlink == 2)
        print("Claude hook configuration checks passed")
    }
}
