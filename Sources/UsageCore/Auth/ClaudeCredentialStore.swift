import Foundation
import Security

/// Reads Claude Code's OAuth credentials from the login Keychain.
///
/// Security rules (AGENTS §2, §4):
/// - read-only; this app never refreshes or writes the item;
/// - refresh tokens are not even decoded, so they cannot leak through a model;
/// - the raw access token only lives inside a `Credential`.
///
/// The keychain item is a generic password with service `Claude Code-credentials` and a JSON
/// payload shaped like `{"claudeAiOauth":{"accessToken":"…","expiresAt":<epoch ms>, ...}}`.
public struct ClaudeCredentialStore: CredentialStore {
    public static let defaultKeychainService = "Claude Code-credentials"

    private let service: String

    public init(service: String = ClaudeCredentialStore.defaultKeychainService) {
        self.service = service
    }

    public func loadCredentials() throws -> ProviderCredential {
        guard let data = try readKeychainData() else {
            // No keychain item: the CLI is either not installed or not signed in.
            throw CredentialError.needsLogin
        }
        return try Self.parse(data)
    }

    // TODO: ad-hoc signed builds re-prompt for keychain access on every build. Distribution
    // must use a stable Developer ID signature (AGENTS §8 Phase 0 notes).
    private func readKeychainData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw CredentialError.accessDenied
        default:
            throw CredentialError.ioFailure(status)
        }
    }

    /// Parses the keychain JSON. Internal so fixtures can be added without touching Keychain.
    static func parse(_ data: Data) throws -> ProviderCredential {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw CredentialError.malformed("claude-keychain-json")
        }

        let token = (payload.claudeAiOauth?.accessToken ?? payload.accessToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else {
            throw CredentialError.needsLogin
        }

        let expiresAt = (payload.claudeAiOauth?.expiresAt ?? payload.expiresAt).map(date(fromEpoch:))
        return ProviderCredential(
            accessToken: Credential(token),
            expiresAt: expiresAt,
            planHint: payload.claudeAiOauth?.subscriptionType ?? payload.subscriptionType
        )
    }

    /// Claude Code stores `expiresAt` in epoch milliseconds. Accept seconds defensively.
    private static func date(fromEpoch value: Double) -> Date {
        let seconds = value > 100_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    // `refreshToken` is intentionally not decoded: unused secrets should not enter memory.
    private struct Payload: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
        }

        let claudeAiOauth: OAuth?
        let accessToken: String?
        let expiresAt: Double?
        let subscriptionType: String?
    }
}
