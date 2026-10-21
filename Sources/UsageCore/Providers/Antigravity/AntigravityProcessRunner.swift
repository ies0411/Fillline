import Darwin
import Foundation
import os

/// Typed `agy` failures. Only these cases become `ProviderStatus` codes; no output text,
/// argument, or environment value is ever carried (AGENTS §4).
public enum AntigravityProcessError: Error, Sendable, Hashable {
    /// `agy` was not found at the configured path or on `PATH`.
    case notInstalled
    /// `Process.run()` failed (permissions, bad architecture, missing temp directory, …).
    case launchFailed
    /// Reading stdout/stderr or waiting for the child failed.
    case ioFailed
    /// The 95s wall clock expired; the child was SIGTERM'd, then SIGKILL'd.
    case timedOut
}

/// Coarse classification of the child's stderr.
///
/// The text itself never leaves the runner: stderr can contain the signed-in account e-mail or
/// fragments of a token, so only this hint (plus a byte count) crosses the boundary.
public enum AntigravityStderrHint: Sendable, Hashable {
    case none
    case authenticationRequired
    case other
}

/// One completed `agy` invocation.
public struct AntigravityProcessOutput: Sendable, Hashable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderrHint: AntigravityStderrHint
    public let stderrByteCount: Int

    public init(
        exitCode: Int32,
        stdout: Data,
        stderrHint: AntigravityStderrHint,
        stderrByteCount: Int
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderrHint = stderrHint
        self.stderrByteCount = stderrByteCount
    }
}

/// Transport seam for the Antigravity strategy. Tests inject a fake: **no test may spawn a real
/// `agy` process** (AGENTS §6). The real implementation is `AntigravityProcessRunner`.
public protocol AntigravityProcessRunning: Sendable {
    /// Runs one one-shot prompt. Implementations are responsible for the private working
    /// directory, the wall-clock deadline, and reaping the child.
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> AntigravityProcessOutput
}

/// Runs Google's official `agy` binary in a throwaway private directory.
///
/// Guarantees:
/// - cwd is a fresh `0700` temp directory (never `$HOME`, never the repo);
/// - the environment is exactly what the caller passes (no credentials added);
/// - stdin is `/dev/null`, so the CLI cannot block waiting for input;
/// - SIGTERM, then SIGKILL after `terminateGrace` seconds, then `waitUntilExit()` — always reaped;
/// - stdout ≤ a few KB for a usage report, stderr is drained but only its byte count is logged.
public struct AntigravityProcessRunner: AntigravityProcessRunning {
    private static let logger = Logger(subsystem: "dev.ies0411.fillline.usage-core", category: "antigravity")

    /// Cap on retained stderr. Enough to classify an auth failure, small enough to bound memory.
    private static let stderrRetentionLimit = 64 * 1024

    private let terminateGrace: TimeInterval

    public init(terminateGrace: TimeInterval = AntigravityEndpoints.terminationGrace) {
        self.terminateGrace = terminateGrace
    }

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> AntigravityProcessOutput {
        let workingDirectory = try Self.makeWorkingDirectory()
        // Removed on every path: normal exit, launch failure, and timeout alike.
        defer { Self.remove(workingDirectory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let started = Date()
        do {
            try process.run()
        } catch {
            Self.close(stdoutPipe.fileHandleForReading)
            Self.close(stdoutPipe.fileHandleForWriting)
            Self.close(stderrPipe.fileHandleForReading)
            Self.close(stderrPipe.fileHandleForWriting)
            throw AntigravityProcessError.launchFailed
        }

        // The child owns the write ends now; the parent's copies must be closed or the readers
        // below never observe EOF.
        Self.close(stdoutPipe.fileHandleForWriting)
        Self.close(stderrPipe.fileHandleForWriting)

        let session = ProcessSession(process: process)
        let stdoutTask = Task.detached(priority: .utility) {
            Self.readAll(stdoutPipe.fileHandleForReading)
        }
        let stderrTask = Task.detached(priority: .utility) {
            Self.readStderr(stderrPipe.fileHandleForReading)
        }

        // Poll rather than racing a task group: a group scope waits for every child, and a
        // `waitUntilExit` child would keep the scope alive while the timeout wants to kill it.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }

        if process.isRunning {
            // SIGTERM, SIGKILL after the grace period, then reap before returning.
            await session.shutdown(grace: terminateGrace)
            // The readers are deliberately not awaited: a grandchild can inherit the pipe and
            // keep it open long after the CLI is dead. The wall clock wins; the tasks end on
            // their own when the last writer closes.
            stdoutTask.cancel()
            stderrTask.cancel()
            Self.log(exitCode: nil, duration: Date().timeIntervalSince(started), stderrBytes: nil)
            throw AntigravityProcessError.timedOut
        }

        let exitCode = await session.waitUntilExit()
        // A stubborn child could also hold the pipe open after a normal exit, so the readers get
        // only the remaining slice of the same wall clock.
        let readerDeadline = deadline.addingTimeInterval(1)
        guard
            let stdout = await Self.join(stdoutTask, until: readerDeadline),
            let stderr = await Self.join(stderrTask, until: readerDeadline)
        else {
            stdoutTask.cancel()
            stderrTask.cancel()
            Self.log(exitCode: exitCode, duration: Date().timeIntervalSince(started), stderrBytes: nil)
            throw AntigravityProcessError.timedOut
        }

        Self.log(
            exitCode: exitCode,
            duration: Date().timeIntervalSince(started),
            stderrBytes: stderr.count
        )

        return AntigravityProcessOutput(
            exitCode: exitCode,
            stdout: stdout,
            stderrHint: Self.hint(for: stderr),
            stderrByteCount: stderr.count
        )
    }

    // MARK: - Executable lookup

    /// `PATH` lookup without spawning anything, so a missing CLI is cheap to detect.
    /// Accepts an explicit path (anything containing `/`) as well as a bare executable name.
    public static func resolveExecutable(_ nameOrPath: String, environment: CredentialEnvironment) -> String?
    {
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

    // MARK: - Working directory

    /// A fresh private directory per invocation. `$TMPDIR` is already per-user on macOS, and the
    /// `0700` mode keeps other local users out. There is deliberately **no fallback to `$HOME` or
    /// the repo**: if the directory cannot be created, the run fails honestly.
    private static func makeWorkingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fillline-antigravity-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AntigravityProcessError.launchFailed
        }
        return directory
    }

    private static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Pipes

    /// Waits for a reader at most until `deadline`. `nil` means the deadline won and the reader
    /// was left to finish on its own (it holds a pipe, not a credential).
    private static func join<T: Sendable>(_ task: Task<T, Never>, until deadline: Date) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let box = ResumeOnce(continuation)
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

    private static func readAll(_ handle: FileHandle) -> Data {
        var data = Data()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 256 * 1024)
            } catch {
                return data
            }
            guard let chunk, !chunk.isEmpty else { return data }
            data.append(chunk)
        }
    }

    /// Drains stderr completely but retains only the first 64 KB, for classification only.
    private static func readStderr(_ handle: FileHandle) -> Data {
        var retained = Data()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                return retained
            }
            guard let chunk, !chunk.isEmpty else { return retained }
            guard retained.count < stderrRetentionLimit else { continue }
            retained.append(chunk.prefix(stderrRetentionLimit - retained.count))
        }
    }

    private static func hint(for stderr: Data) -> AntigravityStderrHint {
        guard !stderr.isEmpty, let text = String(data: stderr, encoding: .utf8) else { return .none }
        let lowered = text.lowercased()
        let markers = [
            "not logged in", "log in", "login", "sign in", "signin",
            "authenticat", "unauthorized", "unauthenticated", "401", "oauth", "credentials",
        ]
        return markers.contains(where: lowered.contains) ? .authenticationRequired : .other
    }

    private static func close(_ handle: FileHandle) {
        try? handle.close()
    }

    /// Only exit status, duration, and byte counts — never output text (AGENTS §4).
    private static func log(exitCode: Int32?, duration: TimeInterval, stderrBytes: Int?) {
        logger.debug(
            "agy exit=\(exitCode.map(String.init) ?? "none", privacy: .public) duration=\(duration, privacy: .public)s stderr=\(stderrBytes ?? 0, privacy: .public)B"
        )
    }
}

// MARK: - Process lifecycle

/// Resumes a continuation exactly once, whichever of the two racing tasks finishes first.
/// The loser's `resume` is a no-op, so no continuation is ever double-resumed.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
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

/// Serializes access to a non-`Sendable` `Process` across tasks. `@unchecked Sendable` is safe
/// because every mutation is lock-guarded and `terminate`/`kill`/`waitUntilExit` are themselves
/// thread-safe.
private final class ProcessSession: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var exitStatus: Int32?
    private var didShutdown = false

    init(process: Process) {
        self.process = process
    }

    /// Suspends until the child exits, then returns its status. Safe to call more than once.
    func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
                return
            }
            waiters.append(continuation)
            lock.unlock()

            DispatchQueue.global(qos: .utility).async { [self] in
                process.waitUntilExit()
                let status = process.terminationStatus
                lock.lock()
                exitStatus = status
                let pending = waiters
                waiters.removeAll()
                lock.unlock()
                for waiter in pending {
                    waiter.resume(returning: status)
                }
            }
        }
    }

    /// Idempotent: SIGTERM, escalate to SIGKILL after `grace`, then reap.
    func shutdown(grace: TimeInterval) async {
        guard beginShutdown() else { return }

        if process.isRunning {
            process.terminate()
        }

        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        // Reaps the child: no zombie is left behind even if it ignored SIGTERM.
        _ = await waitUntilExit()
    }

    /// Synchronous so `NSLock` is never touched from an async context (Swift 6 rule).
    private func beginShutdown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didShutdown { return false }
        didShutdown = true
        return true
    }
}
