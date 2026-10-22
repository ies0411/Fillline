import Foundation
import Security

/// Reads an OpenRouter API key the user already owns. Discovery order (first hit wins):
///
/// 1. `$OPENROUTER_API_KEY`
/// 2. `$XDG_DATA_HOME/opencode/auth.json` → default `~/.local/share/opencode/auth.json`,
///    entry `openrouter`, field `.key` then `.access` then `.token`
/// 3. the app's own keychain item (`dev.ies0411.fillline` / `openrouter`), read-only
///
/// Read-only in every case: the key is never written, refreshed, or logged. There is no
/// browser-cookie path — scraping the web session is deliberately out of scope (issue #13).
public struct OpenRouterKeyStore: CredentialStore {
    public static let environmentKey = "OPENROUTER_API_KEY"
    public static let authEntryName = "openrouter"
    public static let defaultKeychainService = "dev.ies0411.fillline"
    public static let defaultKeychainAccount = "openrouter"

    private let environment: CredentialEnvironment
    private let keychain: any OpenRouterKeychainReading
    private let keychainService: String
    private let keychainAccount: String

    public init(
        environment: CredentialEnvironment = CredentialEnvironment(),
        keychain: any OpenRouterKeychainReading = SystemKeychainReader(),
        keychainService: String = OpenRouterKeyStore.defaultKeychainService,
        keychainAccount: String = OpenRouterKeyStore.defaultKeychainAccount
    ) {
        self.environment = environment
        self.keychain = keychain
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    public var authFileURL: URL {
        environment.xdgDataHome
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    public func loadCredentials() throws -> ProviderCredential {
        if let key = environment.value(Self.environmentKey) {
            return ProviderCredential(accessToken: Credential(key))
        }

        if let data = try? Data(contentsOf: authFileURL),
            let key = Self.key(fromAuthJSON: data, entry: Self.authEntryName)
        {
            return ProviderCredential(accessToken: Credential(key))
        }

        if let key = keychain.password(service: keychainService, account: keychainAccount) {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ProviderCredential(accessToken: Credential(trimmed))
            }
        }

        // OpenRouter has no CLI to install, so "no key" is a sign-in state, not an install state.
        throw CredentialError.needsLogin
    }

    /// `auth.json` holds one entry per tool and its shape may grow; unknown keys are ignored and
    /// the first non-empty of `key` / `access` / `token` wins (issue #13).
    static func key(fromAuthJSON data: Data, entry name: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entry = root[name] as? [String: Any]
        else {
            return nil
        }
        for field in ["key", "access", "token"] {
            guard let raw = entry[field] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

// MARK: - Keychain

/// One keychain lookup, injectable so tests never touch the real keychain.
public protocol OpenRouterKeychainReading: Sendable {
    func password(service: String, account: String) -> String?
}

/// Reads the app's own generic-password item. Never writes, never updates.
public struct SystemKeychainReader: OpenRouterKeychainReading {
    public init() {}

    public func password(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Accept either a bare token or a small JSON object written by a future paste UI.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = root["key"] as? String
        {
            return value
        }
        return text
    }
}
