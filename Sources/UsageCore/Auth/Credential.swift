import Foundation

/// A secret string whose textual representations are always redacted.
///
/// Use `reveal()` only to build an `Authorization` header. Never log, persist, encode,
/// or embed a `Credential` in an error message (AGENTS §4).
public struct Credential: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: String

    public init(_ secret: String) {
        self.storage = secret
    }

    /// Raw secret. Only for constructing an allowlisted auth header. Treat as radioactive.
    public func reveal() -> String { storage }

    public var isEmpty: Bool { storage.isEmpty }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}

/// Credentials already stored locally by a vendor CLI. Read-only: this app never writes
/// or refreshes tokens (refresh rotates one-time tokens and would break the owning CLI).
public struct ProviderCredential: Sendable {
    public let accessToken: Credential
    /// Account/org identifier sent as a header by some providers. Treated as private data.
    public let accountID: Credential?
    public let expiresAt: Date?
    /// e.g. Claude's `subscriptionType` ("max"), Codex's `plan_type`.
    public let planHint: String?

    public init(
        accessToken: Credential,
        accountID: Credential? = nil,
        expiresAt: Date? = nil,
        planHint: String? = nil
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.expiresAt = expiresAt
        self.planHint = planHint
    }

    /// Expiry check with a small leeway so a token that dies mid-request is treated as expired.
    public func isExpired(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return date.addingTimeInterval(leeway) >= expiresAt
    }
}

/// Failures from local credential discovery. Reasons are static codes, never values.
public enum CredentialError: Error, Sendable, Hashable {
    /// CLI/config directory not present on this machine.
    case notInstalled
    /// Files exist but no usable token; user must sign in with the CLI.
    case needsLogin
    /// Keychain access was denied (locked keychain, ACL mismatch).
    case accessDenied
    /// Static reason code, e.g. `"codex-auth-json"`.
    case malformed(String)
    /// Filesystem failure with an errno value.
    case ioFailure(Int32)
}

extension ProviderStatus {
    /// Maps credential discovery failures onto the per-card status model.
    public static func from(_ error: CredentialError) -> ProviderStatus {
        switch error {
        case .notInstalled:
            .notInstalled
        case .needsLogin:
            .needsLogin
        case .accessDenied:
            .error("keychain-access-denied")
        case .malformed(let reason):
            .error("credential-malformed-\(reason)")
        case .ioFailure(let code):
            .error("credential-io-\(code)")
        }
    }
}

/// Reads existing CLI credentials. Implementations must never write to vendor stores.
public protocol CredentialStore: Sendable {
    func loadCredentials() throws -> ProviderCredential
}

/// Environment and home directory used for credential discovery. Injected so tests can
/// point at a temporary directory instead of the real home folder.
public struct CredentialEnvironment: Sendable, Hashable {
    public var variables: [String: String]
    public var homeDirectory: URL

    public init(
        variables: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil
    ) {
        self.variables = variables
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }

    public func value(_ name: String) -> String? {
        guard let value = variables[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    public var xdgConfigHome: URL {
        directory(for: value("XDG_CONFIG_HOME"))
            ?? homeDirectory.appendingPathComponent(".config", isDirectory: true)
    }

    public var xdgDataHome: URL {
        directory(for: value("XDG_DATA_HOME"))
            ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
    }

    public var codexHome: URL {
        directory(for: value("CODEX_HOME"))
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Normalizes an environment path, expanding a leading `~`.
    private func directory(for path: String?) -> URL? {
        guard let path else { return nil }
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// Reads a UTF-8 text file and trims surrounding whitespace. Returns `nil` when missing.
func readTrimmedFile(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
        let text = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
