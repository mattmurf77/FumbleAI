import Foundation
#if canImport(Security)
import Security
#endif

/// Hand-off from the share extension to the app: text shared from Notes, Messages or any app waits here until
/// the app next comes to the foreground, then opens in Quick add for review.
///
/// Stored as one keychain item in a keychain access group both targets carry (`HomeKeychainGroup` in their
/// Info.plist, `$(AppIdentifierPrefix)$(HOME_BUNDLE_ID).shared`). Keychain groups within one team need no App Group
/// or portal setup. Compiled into both the app and the extension.
enum SharedCaptureInbox {
    struct Entry: Codable, Hashable {
        var text: String
        var createdAt: Date
    }

    private static let service = "HomeBlueprint.CaptureInbox"
    private static let account = "pending"
    /// Keep the hand-off small; longer shares are trimmed.
    static let maxCharacters = 20_000

    private static var accessGroup: String? {
        let group = Bundle.main.object(forInfoDictionaryKey: "HomeKeychainGroup") as? String
        guard let group, !group.isEmpty, !group.contains("$(") else { return nil }
        return group
    }

    /// Adds shared text to the inbox. Returns false when the keychain refused it.
    @discardableResult
    static func append(_ text: String, now: Date = Date()) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var entries = read()
        entries.append(Entry(text: String(trimmed.prefix(maxCharacters)), createdAt: now))
        return write(entries)
    }

    /// Everything waiting, oldest first; the inbox is emptied.
    static func takeAll() -> [Entry] {
        let entries = read()
        if !entries.isEmpty { delete() }
        return entries
    }

    // MARK: Keychain

    #if canImport(Security)
    private static func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    private static func read() -> [Entry] {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func write(_ entries: [Entry]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        let status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
    #else
    private static func read() -> [Entry] { [] }
    private static func write(_ entries: [Entry]) -> Bool { false }
    private static func delete() {}
    #endif
}
