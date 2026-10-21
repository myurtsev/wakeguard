import Foundation
import Security
import LocalAuthentication

final class PluginSecrets {
    private let service = "nl.local.WakeGuard.plugins"

    func read(id: String, key: String) throws -> String? {
        var query = attributes(id: id, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw PluginError.invalid("Cannot read this plugin's secret from Keychain.")
        }
        return value
    }

    func write(_ value: String?, id: String, key: String) throws {
        let query = attributes(id: id, key: key)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PluginError.invalid("Cannot remove this plugin's secret from Keychain.")
            }
            return
        }
        let update = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw PluginError.invalid("Cannot save this plugin's secret in Keychain.")
            }
        } else if status != errSecSuccess {
            throw PluginError.invalid("Cannot update this plugin's secret in Keychain.")
        }
    }

    func removeAll(id: String) throws {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw PluginError.invalid("Plugin removed, but its saved secrets could not be removed from Keychain.")
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(id + "#") else { continue }
            var match = query
            match.removeValue(forKey: kSecReturnAttributes as String)
            match.removeValue(forKey: kSecMatchLimit as String)
            match[kSecAttrAccount as String] = account
            let removed = SecItemDelete(match as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else {
                throw PluginError.invalid("Plugin removed, but its saved secrets could not be removed from Keychain.")
            }
        }
    }

    private func attributes(id: String, key: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        // Ad-hoc builds cannot use provisioned data-protection access groups.
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id + "#" + key,
         kSecUseAuthenticationContext as String: context]
    }
}
