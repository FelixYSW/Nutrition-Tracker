import Foundation
import Security

/// The assistant's build-time configuration (spec section 26, as amended).
///
/// The assistant uses one app-wide key: users cannot enter, view or change it.
/// `Config/AppConfig-Info.plist` maps the `ASSISTANT_*` build settings into the
/// app's Info.plist, and CI sets those build settings from GitHub secrets and
/// variables through a temporary xcconfig file. When nothing is set, the values
/// are empty and the app compiles and runs identically, with the assistant
/// reported as unavailable.
///
/// WARNING: anyone who has the IPA can read these values by unzipping it. See
/// the README for how to limit the damage if the key leaks.
enum BundledAPIKey {

    /// Required. Without it the assistant is unavailable.
    static var assistant: String? { value(for: "AssistantAPIKey") }

    /// Optional overrides; the service falls back to Gemini defaults.
    static var assistantModel: String? { value(for: "AssistantModel") }
    static var assistantBaseURL: String? { value(for: "AssistantBaseURL") }

    static var hasAssistantKey: Bool { assistant != nil }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty, or an unexpanded build setting, means it was not provided.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

/// Removes API keys that earlier builds let the user store in the Keychain.
///
/// Those builds had user-entered key fields; this build has none. "Delete all
/// data" calls this so no stale secret is left on the device.
enum LegacySecretCleanup {
    private static let service = "com.felix.NutritionTracker.secrets"
    private static let accounts = ["remote-vision-api-key", "assistant-api-key"]

    static func deleteStoredKeys() {
        for account in accounts {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
