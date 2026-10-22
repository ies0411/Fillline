import Foundation
import os

// MARK: - Token discovery

/// Reads a GitHub token the user already has, in priority order:
///
/// 1. `$GH_TOKEN`, then `$GITHUB_TOKEN` (the environment overrides `gh` documents);
/// 2. `gh auth token` — the GitHub CLI prints the token it already stores;
/// 3. otherwise `.notInstalled` (no `gh` on `PATH`) or `.needsLogin` (installed, signed out).
///
/// Security rules (AGENTS §2, §4):
/// - read-only: this app never refreshes, rotates, or writes a GitHub credential. `gh` stays the
///   owner of the OAuth session, so a rotating refresh token is never consumed twice;
/// - the token only lives inside a `Credential` and is never logged;
/// - the subprocess is a direct `exec` (no shell), with a 5 s wall clock, a private working
///   directory, stdin closed, and `BROWSER` pointed at a binary that always fails so a silent
///   auth failure cannot open a window during a menu-bar refresh.
public protocol GitHubTokenProviding: Sendable {
    /// Only `CredentialError` may escape; providers map it onto a card status.
    func loadToken() async throws -> ProviderCredential
}

public struct GitHubTokenStore: GitHubTokenProviding {
    private static let logger = Logger(
        subsystem: "dev.ies0411.fillline.usage-core",
        category: "github-copilot"
    )

    /// `gh` itself prefers `GH_TOKEN`; both are documented overrides.
    public static let environmentKeys = ["GH_TOKEN", "GITHUB_TOKEN"]

    private let environment: CredentialEnvironment
    private let runner: any GitHubCLIRunning
    private let executable: String?
    private let timeout: TimeInterval

    public init(
        environment: CredentialEnvironment = CredentialEnvironment(),
        runner: any GitHubCLIRunning = GitHubCLIRunner(),
        executable: String? = nil,
        timeout: TimeInterval = GitHubCopilotEndpoints.tokenReadTimeout
    ) {
        self.environment = environment
        self.runner = runner
        self.executable = executable
        self.timeout = timeout
    }

    /// Whether `gh` can be executed at all. Used to distinguish `.notInstalled` from a
    /// signed-out CLI without spawning anything.
    public var isCLIInstalled: Bool {
        Self.resolveExecutable(configured: executable, environment: environment) != nil
    }

    public func loadToken() async throws -> ProviderCredential {
        for name in Self.environmentKeys {
            if let value = environment.value(name) {
                return ProviderCredential(accessToken: Credential(value))
            }
        }

        guard let path = Self.resolveExecutable(configured: executable, environment: environment) else {
            throw CredentialError.notInstalled
        }

        let output: GitHubCLIOutput
        do {
            output = try await runner.run(
                executable: path,
                arguments: GitHubCopilotEndpoints.cliTokenArguments,
                environment: GitHubCopilotEndpoints.cliEnvironment(from: environment.variables),
                timeout: timeout
            )
        } catch let error as GitHubCLIError {
            // Only the case name is logged: stderr can name the signed-in account.
            Self.logger.debug(
                "gh failed (\(String(describing: error), privacy: .public))"
            )
            throw Self.credentialError(for: error)
        } catch {
            throw CredentialError.malformed("gh-token-unknown")
        }

        // Diagnostics stay coarse on purpose: exit status and a byte count, nothing else.
        Self.logger.debug(
            "gh auth token exit=\(output.exitCode, privacy: .public) stderr=\(output.stderrByteCount, privacy: .public)B"
        )

        guard output.exitCode == 0 else {
            // Signed out, or the token was revoked. Retrying cannot fix that.
            throw CredentialError.needsLogin
        }
        guard let token = Self.token(from: output.stdout) else {
            throw CredentialError.needsLogin
        }
        return ProviderCredential(accessToken: Credential(token))
    }

    static func credentialError(for error: GitHubCLIError) -> CredentialError {
        switch error {
        case .notInstalled, .launchFailed:
            .notInstalled
        case .timedOut:
            .malformed("gh-token-timeout")
        case .ioFailed:
            .malformed("gh-token-io")
        }
    }

    /// `gh auth token` prints one bare token. Be tolerant about surrounding whitespace and a
    /// trailing newline, and ignore any extra lines rather than glueing them together.
    static func token(from stdout: Data) -> String? {
        guard let text = String(data: stdout, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// `explicit path` → `FILLLINE_GH_PATH` → `gh` on `PATH`. `nil` means not installed.
    static func resolveExecutable(configured: String?, environment: CredentialEnvironment) -> String? {
        if let configured, !configured.isEmpty {
            return resolve(configured, environment: environment)
        }
        if let fromEnvironment = environment.value(GitHubCopilotEndpoints.cliPathEnvironmentKey) {
            return resolve(fromEnvironment, environment: environment)
        }
        return resolve(GitHubCopilotEndpoints.cliExecutableName, environment: environment)
    }

    private static func resolve(_ nameOrPath: String, environment: CredentialEnvironment) -> String? {
        let fileManager = FileManager.default
        if nameOrPath.contains("/") {
            return fileManager.isExecutableFile(atPath: nameOrPath) ? nameOrPath : nil
        }
        guard let path = environment.value("PATH") ?? ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        var seen = Set<String>()
        for component in path.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = String(component)
            guard seen.insert(directory).inserted else { continue }
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(nameOrPath, isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Subprocess seam

/// One completed `gh` invocation. stdout is the token; stderr is **not** carried at all, only
/// its size, because it can contain the signed-in account name (AGENTS §4).
public struct GitHubCLIOutput: Sendable, Hashable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderrByteCount: Int

    public init(exitCode: Int32, stdout: Data, stderrByteCount: Int) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderrByteCount = stderrByteCount
    }
}

public enum GitHubCLIError: Error, Sendable, Hashable {
    case notInstalled
    case launchFailed
    case ioFailed
    case timedOut
}

/// Transport seam so no test ever spawns a real `gh` (AGENTS §6).
public protocol GitHubCLIRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> GitHubCLIOutput
}

/// Runs `gh` directly — never through a shell — and reaps it on every path.
public struct GitHubCLIRunner: GitHubCLIRunning {
    private let terminateGrace: TimeInterval

    public init(terminateGrace: TimeInterval = GitHubCopilotEndpoints.terminationGrace) {
        self.terminateGrace = terminateGrace
    }

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> GitHubCLIOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A private, writable cwd: never the repo, never `$HOME`.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            Self.close(stdoutPipe.fileHandleForReading)
            Self.close(stdoutPipe.fileHandleForWriting)
            Self.close(stderrPipe.fileHandleForReading)
            Self.close(stderrPipe.fileHandleForWriting)
            throw GitHubCLIError.launchFailed
        }

        // The child owns the write ends; the parent must drop its copies or `read` never sees EOF.
        Self.close(stdoutPipe.fileHandleForWriting)
        Self.close(stderrPipe.fileHandleForWriting)

        let stdoutTask = Task.detached(priority: .utility) {
            Self.readAll(stdoutPipe.fileHandleForReading)
        }
        let stderrTask = Task.detached(priority: .utility) {
            Self.drain(stderrPipe.fileHandleForReading)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if process.isRunning {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(terminateGrace)
            while process.isRunning, Date() < graceDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            stdoutTask.cancel()
            stderrTask.cancel()
            throw GitHubCLIError.timedOut
        }

        // The child is gone, so the readers only need a moment to observe EOF. A grandchild can
        // hold the pipe open, so they get a bounded wait rather than an unbounded `await`.
        let readerDeadline = Date().addingTimeInterval(1)
        guard let stdout = await join(stdoutTask, until: readerDeadline) else {
            stdoutTask.cancel()
            stderrTask.cancel()
            throw GitHubCLIError.timedOut
        }
        let stderrBytes = await join(stderrTask, until: readerDeadline) ?? 0

        return GitHubCLIOutput(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderrByteCount: stderrBytes
        )
    }

    // MARK: Pipes

    private static func readAll(_ handle: FileHandle) -> Data {
        var data = Data()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                return data
            }
            guard let chunk, !chunk.isEmpty else { return data }
            data.append(chunk)
        }
    }

    /// Drains stderr so the child never blocks on a full pipe, but keeps **no content**.
    private static func drain(_ handle: FileHandle) -> Int {
        var total = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                return total
            }
            guard let chunk, !chunk.isEmpty else { return total }
            total += chunk.count
        }
    }

    private static func close(_ handle: FileHandle) {
        try? handle.close()
    }
}

// MARK: - Bounded join

/// Waits for `task` at most until `deadline`; `nil` means the deadline won and the task was left
/// to finish on its own (it holds a pipe, not a credential).
private func join<T: Sendable>(_ task: Task<T, Never>, until deadline: Date) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let box = ResumeOnceBox(continuation)
        Task.detached(priority: .utility) {
            let value = await task.value
            box.resume(value)
        }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            box.resume(nil)
        }
    }
}

/// Resumes exactly once, whichever racer wins; the loser's call is a no-op.
private final class ResumeOnceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var didResume = false

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
