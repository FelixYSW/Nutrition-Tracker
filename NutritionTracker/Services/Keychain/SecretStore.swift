import Foundation
import Security

/// Keychain-backed storage for runtime secrets (spec sections 26, 39).
///
/// API keys never go to SwiftData or UserDefaults, are never logged, and never
/// appear in an export. A runtime key always takes precedence over a build-time
/// key compiled into the binary.
enum SecretStore {

    enum Key: String, CaseIterable {
        /// Optional remote vision fallback for the photo pipeline.
        case remoteVisionAPIKey = "remote-vision-api-key"
        /// Assistant LLM key. A separate slot, because the assistant may use a
        /// different provider than the vision fallback.
        case assistantAPIKey = "assistant-api-key"
    }

    private static let service = "com.felix.NutritionTracker.secrets"

    // MARK: Read / write

    static func store(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(key) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        var query = baseQuery(for: key)
        // Device-only and unlocked-only: the key should not sync to another
        // device via iCloud Keychain, nor be readable while locked.
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        if exists(key) {
            let update: [CFString: Any] = [kSecValueData: data]
            let status = SecItemUpdate(query as CFDictionary,
                                       update as CFDictionary)
            return status == errSecSuccess
        } else {
            for (attribute, value) in attributes {
                query[attribute] = value
            }
            let status = SecItemAdd(query as CFDictionary, nil)
            return status == errSecSuccess
        }
    }

    static func read(_ key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func exists(_ key: Key) -> Bool {
        var query = baseQuery(for: key)
        query[kSecReturnData] = false
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAll() {
        for key in Key.allCases { delete(key) }
    }

    private static func baseQuery(for key: Key) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue
        ]
    }
}

/// Resolves an effective API key from the Keychain first, then the optional
/// build-time constant.
///
/// A build-time key compiled into an IPA **can be extracted from the binary**,
/// so it exists only for private personal builds (spec section 26).
enum APIKeyResolver {

    static func key(for key: SecretStore.Key) -> String? {
        if let runtime = SecretStore.read(key), !runtime.isEmpty {
            return runtime
        }
        return buildTimeKey
    }

    /// Present only when CI injected the optional `REMOTE_AI_API_KEY` secret.
    private static var buildTimeKey: String? {
        BuildSecretsBridge.remoteAIAPIKey
    }

    static func hasKey(for key: SecretStore.Key) -> Bool {
        guard let value = self.key(for: key) else { return false }
        return !value.isEmpty
    }
}

/// Reads the optional build-time key.
///
/// The CI workflow passes `INFOPLIST_KEY_RemoteAIAPIKey` to `xcodebuild`, which
/// lands it in the generated Info.plist. Using the Info.plist rather than a
/// generated Swift file means the app compiles identically whether or not the
/// secret is configured - there is no symbol to be missing.
///
/// This value is readable by anyone who unzips the IPA, which is exactly why it
/// is documented as private-builds-only.
enum BuildSecretsBridge {
    static var remoteAIAPIKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RemoteAIAPIKey") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
