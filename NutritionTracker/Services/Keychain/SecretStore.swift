import Foundation
import Security

enum SecretStore {
    private static let service = "com.felix.NutritionTracker.remoteAI"
    static func save(_ value: String) -> Bool {
        delete()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecValueData as String: Data(value.utf8)]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}
