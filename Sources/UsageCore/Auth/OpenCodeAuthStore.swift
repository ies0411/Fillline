import Foundation

/// Discovers the OpenCode Go API key, in priority order:
///
/// 1. `$OPENCODE_API_KEY`
/// 2. `$XDG_CONFIG_HOME/opencode/.secrets/opencode-key` (default `~/.config/...`), one line
/// 3. `$XDG_DATA_HOME/opencode/auth.json` (default `~/.local/share/...`), entry `opencode-go`
///    then `opencode`, field `.key`
///
/// Read-only. The key is never written anywhere.
public struct OpenCodeAuthStore: CredentialStore {
    public static let environmentKey = "OPENCODE_API_KEY"
    public static let authEntryNames = ["opencode-go", "opencode"]

    private let environment: CredentialEnvironment

    public init(environment: CredentialEnvironment = CredentialEnvironment()) {
        self.environment = environment
    }

    public var keyFileURL: URL {
        environment.xdgConfigHome
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent(".secrets", isDirectory: true)
            .appendingPathComponent("opencode-key", isDirectory: false)
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

        if let key = readTrimmedFile(at: keyFileURL) {
            return ProviderCredential(accessToken: Credential(key))
        }

        if let data = try? Data(contentsOf: authFileURL),
            let key = Self.key(fromAuthJSON: data, candidates: Self.authEntryNames)
        {
            return ProviderCredential(accessToken: Credential(key))
        }

        let configDirectory = environment.xdgConfigHome.appendingPathComponent("opencode", isDirectory: true)
        if !FileManager.default.fileExists(atPath: configDirectory.path),
            !FileManager.default.fileExists(atPath: authFileURL.path)
        {
            throw CredentialError.notInstalled
        }
        throw CredentialError.needsLogin
    }

    /// Tolerance here is deliberate: `auth.json` holds entries for several tools and the
    /// shape may grow. Unknown keys are ignored.
    static func key(fromAuthJSON data: Data, candidates: [String]) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for name in candidates {
            guard let entry = root[name] as? [String: Any],
                let key = entry["key"] as? String
            else {
                continue
            }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
