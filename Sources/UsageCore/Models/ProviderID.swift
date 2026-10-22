import Foundation

/// Stable identifier for every usage provider the app can display.
///
/// Raw values are persisted in `SnapshotCache`, so they must not change casually.
public enum ProviderID: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case openCodeGo = "opencode-go"
    case antigravity = "antigravity"
    case githubCopilot = "github-copilot"
    case openRouter = "openrouter"

    public var id: String { rawValue }

    /// Compact label for constrained menu bar space (e.g. `C 62%`).
    public var shortLabel: String {
        switch self {
        case .claudeCode: "C"
        case .codex: "O"
        case .openCodeGo: "G"
        case .antigravity: "A"
        case .githubCopilot: "P"
        case .openRouter: "R"
        }
    }

    /// Human-readable name used in the popover.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "OpenAI Codex"
        case .openCodeGo: "OpenCode Go"
        case .antigravity: "Antigravity"
        case .githubCopilot: "GitHub Copilot"
        case .openRouter: "OpenRouter"
        }
    }
}
