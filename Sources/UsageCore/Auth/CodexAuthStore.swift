import Foundation

/// Reads Codex CLI credentials from `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`).
///
/// Read-only. Refresh tokens are never decoded or refreshed; an expired session surfaces as
/// `.needsLogin` and the user re-runs the CLI (AGENTS §2).
///
/// The Codex CLI also supports storing auth in the macOS Keychain under service `Codex Auth`.
/// That variant is not implemented yet:
/// TODO: read service `Codex Auth` (kSecClassGenericPassword, read-only) when `auth.json` is absent.
public struct CodexAuthStore: CredentialStore {
    private let environment: CredentialEnvironment

    public init(environment: CredentialEnvironment = CredentialEnvironment()) {
        self.environment = environment
    }

    public var authFileURL: URL {
        environment.codexHome.appendingPathComponent("auth.json", isDirectory: false)
    }

    public func loadCredentials() throws -> ProviderCredential {
        let url = authFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CredentialError.notInstalled
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CredentialError.malformed("codex-auth-read")
        }

        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> ProviderCredential {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            throw CredentialError.malformed("codex-auth-json")
        }

        // API-key auth cannot call the ChatGPT usage endpoint; a ChatGPT login is required.
        guard
            let token = payload.tokens?.accessToken?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            throw CredentialError.needsLogin
        }

        let accountID = payload.tokens?.accountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ProviderCredential(
            accessToken: Credential(token),
            accountID: accountID.flatMap { $0.isEmpty ? nil : Credential($0) }
        )
    }

    // `refresh_token` / `id_token` are intentionally not decoded.
    private struct Payload: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountID: String?
        }

        let tokens: Tokens?
    }
}
