import Darwin
import Foundation
import os

/// Low-level transport seam for the `codex app-server` strategy.
///
/// Tests inject a fake: **no test may spawn a real `codex` process** (AGENTS §6). The real
/// implementation is `CodexProcessRunner`.
public protocol CodexProcessRunning: Sendable {
    /// Spawns the executable, performs the request/response exchange, and returns every
    /// newline-delimited message received before the terminal response or EOF.
    ///
    /// `requestLines` are written in order, 1-based: line *n* is only sent after the previous
    /// request was acknowledged, and the exchange ends when the response with id equal to
    /// `requestLines.count` arrives. `timeout` is a hard deadline for the whole exchange.
    func run(
        executable: String,
        arguments: [String],
        requestLines: [String],
        timeout: TimeInterval
    ) async throws -> [String]
}

/// Typed app-server failures. Only these codes reach `ProviderStatus`; no response body,
/// token, or stderr text is ever carried (AGENTS §4).
public enum CodexAppServerError: Error, Sendable, Hashable {
    /// `codex` was not found on `PATH` (or at the configured path).
    case notInstalled
    /// `Process.run()` failed (permissions, bad architecture, ...).
    case launchFailed
    /// Writing a request or reading stdout failed.
    case ioFailed
    /// The 10s handshake + read deadline expired.
    case timedOut
    /// The process exited without answering the rate-limits request.
    case incompleteResponse
    /// The reply was not the documented shape.
    case malformedResponse
    /// JSON-RPC error reply. `code` is numeric only.
    case rpcError(code: Int)
}

/// Documented strategy: `codex app-server --listen stdio://` → `account/rateLimits/read`.
///
/// Resolves the binary through `PATH` (or an explicit path), builds the newline-delimited
/// JSON requests, and hands the raw reply lines to `CodexAppServerResponse`. The client never
/// touches tokens: the CLI owns its own login state.
public struct CodexAppServerClient: Sendable {
    private let runner: any CodexProcessRunning
    private let executable: String?
    private let environment: CredentialEnvironment
    private let clientVersion: String
    private let timeout: TimeInterval

    public init(
        runner: any CodexProcessRunning = CodexProcessRunner(),
        executable: String? = nil,
        environment: CredentialEnvironment = CredentialEnvironment(),
        clientVersion: String = CodexEndpoints.appServerClientVersion,
        timeout: TimeInterval = CodexEndpoints.appServerTimeout
    ) {
        self.runner = runner
        self.executable = executable
        self.environment = environment
        self.clientVersion = clientVersion
        self.timeout = timeout
    }

    /// Absolute path to the binary, or `nil` when it is not installed.
    public func resolvedExecutable() -> String? {
        Self.resolveExecutable(executable ?? CodexEndpoints.appServerExecutableName, environment: environment)
    }

    /// `PATH` lookup without spawning anything, so a missing CLI is cheap to detect.
    /// Accepts an explicit path (anything containing `/`) as well as a bare executable name.
    public static func resolveExecutable(_ nameOrPath: String, environment: CredentialEnvironment) -> String? {
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

    /// Runs the handshake and parses the `account/rateLimits/read` result.
    func rateLimits() async throws -> CodexAppServerResponse {
        guard let executable = resolvedExecutable() else { throw CodexAppServerError.notInstalled }

        let lines = try await runner.run(
            executable: executable,
            arguments: CodexEndpoints.appServerArguments,
            requestLines: Self.requestLines(version: clientVersion),
            timeout: timeout
        )
        return try CodexAppServerResponse.decode(
            lines: lines,
            responseID: CodexEndpoints.appServerRateLimitsRequestID
        )
    }

    /// `[initialize, account/rateLimits/read]` as compact JSON lines (no `jsonrpc` field).
    static func requestLines(version: String) -> [String] {
        let initialize: [String: Any] = [
            "id": CodexEndpoints.appServerInitializeRequestID,
            "method": CodexEndpoints.appServerInitializeMethod,
            "params": [
                "clientInfo": [
                    "name": CodexEndpoints.appServerClientName,
                    "version": version
                ]
            ]
        ]
        let read: [String: Any] = [
            "id": CodexEndpoints.appServerRateLimitsRequestID,
            "method": CodexEndpoints.appServerRateLimitsMethod
        ]
        return [jsonLine(initialize), jsonLine(read)]
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else {
            // Callers only pass literal dictionaries; this cannot fail in practice.
            return "{}"
        }
        return line
    }
}

// MARK: - Real process transport

/// Spawns `codex app-server`, speaks newline-delimited JSON over stdio, and guarantees the
/// child is terminated and reaped: SIGTERM first, SIGKILL after 2s, stdin closed before the
/// wait. stderr is drained but never inspected — only its byte count is logged, because it can
/// contain tokens.
public struct CodexProcessRunner: CodexProcessRunning {
    private static let logger = Logger(subsystem: "dev.ies0411.fillline.usage-core", category: "codex-app-server")

    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        requestLines: [String],
        timeout: TimeInterval
    ) async throws -> [String] {
        guard !requestLines.isEmpty else { throw CodexAppServerError.malformedResponse }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            Self.close(stdinPipe.fileHandleForWriting)
            Self.close(stdoutPipe.fileHandleForReading)
            Self.close(stderrPipe.fileHandleForReading)
            throw CodexAppServerError.launchFailed
        }

        let handle = ProcessHandle(process: process, stdin: stdinPipe.fileHandleForWriting)
        let stderrBytes = ByteCounter()
        let stderrTask = Task.detached(priority: .utility) {
            Self.drain(stderrPipe.fileHandleForReading, into: stderrBytes)
        }

        do {
            let lines = try await withThrowingTaskGroup(of: [String].self) { group in
                group.addTask {
                    try await Self.exchange(
                        stdin: stdinPipe.fileHandleForWriting,
                        stdout: stdoutPipe.fileHandleForReading,
                        requestLines: requestLines
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CodexAppServerError.timedOut
                }
                do {
                    guard let lines = try await group.next() else {
                        throw CodexAppServerError.incompleteResponse
                    }
                    group.cancelAll()
                    return lines
                } catch {
                    group.cancelAll()
                    // Kill first: it closes the child's stdout, which ends the reader task and
                    // lets the group scope finish instead of waiting on a live pipe.
                    await handle.shutdown()
                    throw error
                }
            }
            await handle.shutdown()
            await stderrTask.value
            Self.logStderr(bytes: stderrBytes.value)
            return lines
        } catch {
            await handle.shutdown()
            await stderrTask.value
            Self.logStderr(bytes: stderrBytes.value)
            throw error
        }
    }

    // MARK: Exchange

    private static func exchange(
        stdin: FileHandle,
        stdout: FileHandle,
        requestLines: [String]
    ) async throws -> [String] {
        let terminalID = requestLines.count
        var received: [String] = []
        var nextRequest = 1

        try writeLine(requestLines[0], to: stdin)

        for try await line in stdout.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            received.append(trimmed)

            if nextRequest < requestLines.count, isAcknowledgement(trimmed, expectedID: nextRequest) {
                try writeLine(requestLines[nextRequest], to: stdin)
                nextRequest += 1
            }
            if CodexAppServerResponse.integer(CodexAppServerResponse.jsonObject(trimmed)?["id"]) == terminalID {
                return received
            }
        }
        throw CodexAppServerError.incompleteResponse
    }

    /// The server answers `initialize` with a reply to id 1 and/or an `initialized`
    /// notification (docs/providers/codex.md). Either one releases the next request.
    private static func isAcknowledgement(_ line: String, expectedID: Int) -> Bool {
        guard let object = CodexAppServerResponse.jsonObject(line) else { return false }
        if let method = object["method"] as? String, method == "initialized", object["id"] == nil {
            return true
        }
        return CodexAppServerResponse.integer(object["id"]) == expectedID
    }

    private static func writeLine(_ line: String, to handle: FileHandle) throws {
        guard let data = (line + "\n").data(using: .utf8) else {
            throw CodexAppServerError.ioFailed
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.ioFailed
        }
    }

    // MARK: Diagnostics

    /// Reads and discards stderr, counting bytes only. Never decodes the payload.
    private static func drain(_ handle: FileHandle, into counter: ByteCounter) {
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                return
            }
            guard let chunk, !chunk.isEmpty else { return }
            counter.add(chunk.count)
        }
    }

    private static func logStderr(bytes: Int) {
        logger.debug("app-server stderr bytes: \(bytes, privacy: .public)")
    }

    private static func close(_ handle: FileHandle) {
        try? handle.close()
    }
}

// MARK: - Process lifecycle

/// Serializes access to a non-`Sendable` `Process` across tasks. `@unchecked Sendable` is safe
/// here because every mutation is guarded and the only cross-thread calls (`terminate`,
/// `kill`, `waitUntilExit`) are themselves thread-safe.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    private let stdin: FileHandle
    private let lock = NSLock()
    private var didShutdown = false

    init(process: Process, stdin: FileHandle) {
        self.process = process
        self.stdin = stdin
    }

    /// Idempotent: close stdin, SIGTERM, escalate to SIGKILL after 2s, then reap.
    func shutdown() async {
        guard beginShutdown() else { return }

        // Closing stdin is the graceful signal; the deadline bounds everything else.
        try? stdin.close()

        if process.isRunning { process.terminate() }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        await waitUntilExit()
    }

    /// Synchronous so `NSLock` is never touched from an async context (Swift 6 rule).
    private func beginShutdown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didShutdown { return false }
        didShutdown = true
        return true
    }

    private func waitUntilExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                // Reaps the child: no zombie is left behind even if it ignored SIGTERM.
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

/// Thread-safe byte counter for the stderr drain.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0

    func add(_ count: Int) {
        lock.lock()
        bytes += count
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}
