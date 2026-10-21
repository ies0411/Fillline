import Foundation
import os

/// Antigravity provider — runs Google's official `agy` CLI and parses its `/usage` report.
///
/// This provider **never** reads Google OAuth credentials and **never** calls Google endpoints.
/// Antigravity's Additional ToS §6 prohibits reaching the Service through third-party software,
/// so the only legal path is the vendor's own binary (see `AntigravityEndpoints`).
///
/// `fetch` never throws: every failure is a stable `ProviderStatus` code, and a missing binary is
/// `.notInstalled` (never `.error`).
public struct AntigravityProvider: UsageProvider {
    public let id: ProviderID = .antigravity

    private static let logger = Logger(subsystem: "dev.ies0411.fillline.usage-core", category: "antigravity")

    private let runner: any AntigravityProcessRunning
    private let environment: CredentialEnvironment
    private let executable: String?
    private let timeout: TimeInterval

    public init(
        runner: any AntigravityProcessRunning = AntigravityProcessRunner(),
        executable: String? = nil,
        environment: CredentialEnvironment = CredentialEnvironment(),
        timeout: TimeInterval = AntigravityEndpoints.timeout
    ) {
        self.runner = runner
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    public func fetch(now: Date) async -> UsageSnapshot {
        guard let executable = Self.resolveExecutable(configured: executable, environment: environment) else {
            Self.logger.debug("agy not found; reporting notInstalled")
            return ProviderSupport.failureSnapshot(provider: id, status: .notInstalled, now: now)
        }

        let started = Date()
        let output: AntigravityProcessOutput
        do {
            output = try await runner.run(
                executable: executable,
                arguments: AntigravityEndpoints.arguments,
                // Inherit the user environment, but neuter browser launch paths so a silent-auth
                // failure cannot open a window during a menu-bar refresh.
                environment: AntigravityEndpoints.environment(from: environment.variables),
                timeout: timeout
            )
        } catch let error as AntigravityProcessError {
            // A binary that vanished between the lookup and the spawn is still "not installed".
            let status: ProviderStatus
            if case .launchFailed = error, !FileManager.default.isExecutableFile(atPath: executable) {
                status = .notInstalled
            } else {
                status = Self.status(for: error)
            }
            Self.logger.debug(
                "agy failed (\(String(describing: error), privacy: .public)) after \(Date().timeIntervalSince(started), privacy: .public)s"
            )
            return ProviderSupport.failureSnapshot(provider: id, status: status, now: now)
        } catch {
            return ProviderSupport.failureSnapshot(provider: id, status: .error("launch-failed"), now: now)
        }

        // Only exit status, duration, and byte counts — never output text (AGENTS §4).
        Self.logger.debug(
            "agy exit=\(output.exitCode, privacy: .public) duration=\(Date().timeIntervalSince(started), privacy: .public)s stdout=\(output.stdout.count, privacy: .public)B stderr=\(output.stderrByteCount, privacy: .public)B"
        )

        guard output.exitCode == 0 else {
            // An auth-looking stderr is actionable ("run `agy` once"); anything else is a code.
            let status: ProviderStatus =
                output.stderrHint == .authenticationRequired
                ? .needsLogin
                : .error("exit-\(output.exitCode)")
            return ProviderSupport.failureSnapshot(provider: id, status: status, now: now)
        }

        guard let report = AntigravityUsageReport.parse(output.stdout) else {
            Self.logger.debug("agy payload unrecognised; reporting decoding-failed")
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error(ProviderSupport.Failure.decoding),
                now: now
            )
        }

        // Enterprise/Business accounts get no usage panel at all. Never invent a 0%.
        guard report.panelPresent else {
            Self.logger.debug("agy usage panel missing (enterprise/business account); reporting unsupported")
            return ProviderSupport.failureSnapshot(provider: id, status: .unsupported, now: now)
        }

        let windows = report.buckets.map { bucket in
            Self.window(from: bucket, isEstimated: report.isEstimated, now: now)
        }
        guard !windows.isEmpty else {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error(ProviderSupport.Failure.emptyUsage),
                now: now
            )
        }

        return UsageSnapshot(
            provider: id,
            plan: nil,
            windows: windows,
            // There is no `.cli` source yet; `Source.api` is the closest existing case and is
            // tracked as a follow-up (the UI cannot distinguish it from an HTTP provider).
            source: .api,
            status: .ok,
            capturedAt: now
        )
    }

    // MARK: - Executable

    /// `explicit path` → `ANTIGRAVITY_CLI_PATH` → `agy` on `PATH`. `nil` means not installed.
    public static func resolveExecutable(configured: String?, environment: CredentialEnvironment) -> String? {
        if let configured, !configured.isEmpty {
            return AntigravityProcessRunner.resolveExecutable(configured, environment: environment)
        }
        if let fromEnvironment = environment.value(AntigravityEndpoints.executableEnvironmentKey) {
            return AntigravityProcessRunner.resolveExecutable(fromEnvironment, environment: environment)
        }
        return AntigravityProcessRunner.resolveExecutable(
            AntigravityEndpoints.executableName,
            environment: environment
        )
    }

    // MARK: - Mapping

    /// Antigravity reports **remaining**, so the shared model's used fraction is `1 − remaining`.
    static func window(
        from bucket: AntigravityUsageReport.Bucket,
        isEstimated: Bool,
        now: Date
    ) -> LimitWindow {
        let descriptor = descriptor(for: bucket.windowCode)
        return LimitWindow(
            id: "\(ProviderID.antigravity.rawValue).\(bucket.bucketID)",
            kind: descriptor.kind,
            label: "\(groupLabel(bucket.groupDisplayName)) · \(descriptor.cadence)",
            usedFraction: 1 - bucket.remainingFraction,
            resetsAt: bucket.resetsAt,
            isEstimated: isEstimated,
            isPlaceholder: false,
            capturedAt: now
        )
    }

    static func descriptor(for windowCode: String) -> (kind: LimitWindow.Kind, cadence: String) {
        switch windowCode.lowercased() {
        case "5h", "5-hour", "5hour", "session":
            (.session5h, "5h")
        case "weekly", "week", "7d":
            (.weekly7d, "Weekly")
        case "monthly", "month", "30d":
            (.monthly, "Monthly")
        default:
            // Unknown cadence: keep the row instead of dropping data the user may need.
            (.rolling, windowCode.isEmpty ? "Window" : windowCode.capitalized)
        }
    }

    /// `Gemini Models` → `Gemini`, `Claude and GPT models` → `3P`, anything else verbatim.
    static func groupLabel(_ displayName: String) -> String {
        let lowered = displayName.lowercased()
        if lowered.contains("gemini") { return "Gemini" }
        if lowered.contains("gpt")
            || lowered.contains("claude")
            || lowered.contains("3p")
            || lowered.contains("third")
        {
            return "3P"
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Usage" : trimmed
    }

    // MARK: - Status mapping

    /// Stable codes only; no stderr text, path, or environment value is propagated.
    static func status(for error: AntigravityProcessError) -> ProviderStatus {
        switch error {
        case .notInstalled:
            .notInstalled
        case .launchFailed:
            .error("launch-failed")
        case .ioFailed:
            .error("io-failed")
        case .timedOut:
            .error("timeout")
        }
    }
}
