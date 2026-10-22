import Foundation

/// GitHub Copilot quota endpoint and the exact headers GitHub expects.
///
/// The path lives under `api.github.com`'s `copilot_internal` namespace, i.e. it is the
/// endpoint the Copilot editor extensions call — **undocumented**, not a public API contract.
/// It is called with the token the user's own GitHub CLI already holds; this app never
/// refreshes it and never writes it back (AGENTS §2).
///
/// Everything describing the request lives in this one file (AGENTS §2). Tests assert against
/// these constants, so a header change is a visible diff, not a string buried in provider code.
public enum GitHubCopilotEndpoints {
    // MARK: - Usage request

    public static let usage = URL(string: "https://api.github.com/copilot_internal/user")!

    public static var host: String { usage.host() ?? "" }

    /// GitHub requires a `User-Agent`; the `Editor-*` headers identify the caller as a Copilot
    /// client. Without them the endpoint answers 401/403 for otherwise valid tokens.
    public static let acceptHeader = "application/json"
    public static let userAgent = "GitHubCopilotChat/0.23.2"
    public static let editorVersion = "vscode/1.96.2"
    public static let editorPluginVersion = "copilot-chat/0.23.2"
    public static let apiVersion = "2022-11-28"

    public static func usageRequest(token: Credential) -> URLRequest {
        var request = URLRequest(url: usage)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token.reveal())", forHTTPHeaderField: "Authorization")
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(editorVersion, forHTTPHeaderField: "Editor-Version")
        request.setValue(editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    // MARK: - Token discovery (`gh auth token`)

    /// `gh` is the only credential source: it owns the OAuth app, the refresh cycle and the
    /// keychain entry. Reading its output keeps this app out of GitHub's token store entirely.
    public static let cliExecutableName = "gh"

    /// Override honoured before the `PATH` lookup (non-standard installs, tests).
    public static let cliPathEnvironmentKey = "FILLLINE_GH_PATH"

    /// `gh auth token` prints the current token and exits. It never prompts when the token
    /// already exists; `GH_PROMPT_DISABLED` covers the not-signed-in case.
    public static let cliTokenArguments = ["auth", "token"]

    /// Wall clock for the child. A hung `gh` must not stall a poll pass.
    public static let tokenReadTimeout: TimeInterval = 5

    /// SIGTERM grace before escalating to SIGKILL once the timeout expires.
    public static let terminationGrace: TimeInterval = 0.5

    /// A silent-auth failure must never open a browser during a menu-bar refresh.
    public static let browserVariable = "BROWSER"
    public static let disabledBrowserPath = "/usr/bin/false"

    /// Variables kept from the user's environment. `gh` needs `HOME` for its config, `PATH` for
    /// git, and the XDG overrides when the user relocated the config directory. Everything else
    /// is dropped: no `GH_TOKEN`/`GITHUB_TOKEN` is injected here, and no display variable is
    /// forwarded.
    public static let inheritedEnvironmentVariables = [
        "HOME", "PATH", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "TMPDIR",
    ]

    /// Extra variables that make `gh` non-interactive and quiet.
    public static let nonInteractiveEnvironment = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_PAGER": "cat",
        "NO_COLOR": "1",
    ]

    /// Child environment for `gh auth token`: a minimal allowlist plus the browser guard.
    public static func cliEnvironment(from base: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for name in inheritedEnvironmentVariables {
            if let value = base[name], !value.isEmpty {
                environment[name] = value
            }
        }
        for (name, value) in nonInteractiveEnvironment {
            environment[name] = value
        }
        environment[browserVariable] = disabledBrowserPath
        return environment
    }
}
