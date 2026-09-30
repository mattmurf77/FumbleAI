import Foundation
import HomeCore
#if canImport(Security)
import Security
#endif

/// This install's owner-device identity (LLD §9.5 "Owner device"): a UUID stored in the Keychain with
/// `kSecAttrSynchronizable = false` so it survives reinstalls but never syncs, plus the user-editable nickname
/// (kept in UserDefaults; Settings writes it with `setNickname`). On platforms without Security the id lives in
/// UserDefaults.
public final class KeychainDeviceIdentity: DeviceIdentity, @unchecked Sendable {
    public static let service = "app.fumble.home.device"
    public static let account = "device_id"
    public static let nicknameKey = "app.fumble.home.deviceNickname"

    private let defaults: UserDefaults
    public let deviceId: String

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        deviceId = KeychainDeviceIdentity.loadOrCreateId(defaults: defaults)
    }

    public var nickname: String {
        let s = defaults.string(forKey: KeychainDeviceIdentity.nicknameKey) ?? ""
        return s.isEmpty ? "iPhone" : s
    }

    public func setNickname(_ name: String) {
        defaults.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: KeychainDeviceIdentity.nicknameKey)
    }

    private static func loadOrCreateId(defaults: UserDefaults) -> String {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
           let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        let id = UUID().uuidString.lowercased()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: account,
                                  kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  kSecValueData as String: Data(id.utf8)]
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return id }
        // Keychain unavailable (e.g. simulator quirks): fall back to defaults so the id is at least stable.
        #endif
        let key = "app.fumble.home.deviceId"
        if let s = defaults.string(forKey: key), !s.isEmpty { return s }
        let fallback = UUID().uuidString.lowercased()
        defaults.set(fallback, forKey: key)
        return fallback
    }
}
