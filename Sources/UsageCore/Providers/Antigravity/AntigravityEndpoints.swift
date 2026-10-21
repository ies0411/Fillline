import Foundation

/// Antigravity usage source — the official `agy` CLI, nothing else.
///
/// We deliberately **never read Google credentials and never call Google endpoints**.
/// Antigravity's Additional Terms of Service §6 prohibits accessing the Service through
/// third-party software ("using third party software, tools, or services to access the
/// Service … is a breach"), and Google has banned accounts for doing exactly that. The only
/// supported path is to run Google's own binary and read the `/usage` report it prints, which
/// is the same shape as the Codex `app-server` strategy (`docs/providers/codex.md`).
///
/// Everything that describes the invocation lives in this one file (AGENTS §2).
public enum AntigravityEndpoints {
    // MARK: - Executable

    /// Override honoured before `PATH` lookup. Useful for non-standard installs and tests.
    public static let executableEnvironmentKey = "ANTIGRAVITY_CLI_PATH"

    /// Resolved through `PATH` when no absolute path is configured.
    public static let executableName = "agy"

    // MARK: - Arguments

    /// Exactly what we execute: one-shot prompt (`-p`) asking for the usage panel as JSON.
    ///
    /// `--print-timeout 90s` is the CLI's own deadline; `timeout` below is the outer wall clock
    /// that also covers process start-up and shutdown.
    public static let arguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "90s"]

    /// Hard wall clock for the whole child process (CLI deadline + 5s of headroom).
    public static let timeout: TimeInterval = 95

    /// SIGTERM grace before escalating to SIGKILL. The child is always reaped.
    public static let terminationGrace: TimeInterval = 2

    // MARK: - Environment

    /// A silent-auth failure inside the CLI must never pop a browser during a menu-bar refresh.
    /// `BROWSER` is pointed at a binary that always fails, so an OAuth flow aborts instead.
    public static let browserVariable = "BROWSER"
    public static let disabledBrowserPath = "/usr/bin/false"

    /// Display variables are removed for the same reason: no GUI session, no browser.
    public static let removedEnvironmentVariables = ["DISPLAY"]

    /// Child environment: inherit everything, then neuter browser launch paths.
    /// No credential is added, copied, or logged here.
    public static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        environment[browserVariable] = disabledBrowserPath
        for name in removedEnvironmentVariables {
            environment.removeValue(forKey: name)
        }
        return environment
    }
}
