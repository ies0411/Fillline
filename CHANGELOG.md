# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Provider endpoints are undocumented and can break between releases; a fix for a
broken parser ships as a patch release.

## [Unreleased]

### Added
- **GitHub Copilot** provider (opt-in). Reads `GET https://api.github.com/copilot_internal/user`
  with a token obtained from `gh auth token` — no credential is copied, stored, or refreshed.
  Shows the monthly AI-credit allowance and the chat allowance. Copilot reports
  `percent_remaining` (0–100 **remaining**), the opposite polarity of Claude/Codex/OpenCode Go,
  so its parser is deliberately separate; `unlimited` and zero-entitlement buckets are shown as
  such and never as 0% used.
- **OpenRouter** provider (opt-in). Reads `GET https://openrouter.ai/api/v1/key`. OpenRouter
  exposes **no percentage at all**, only USD amounts, so the card shows `$8.50 left` and draws no
  meter — inventing a 0–100% bar from an unknown ceiling would break the "never mislabel" rule.
  Account balance needs a management key, so only per-key budget is read.

### Fixed
- Amount-only windows (OpenRouter) no longer render as an empty meter, and are excluded from the
  menu-bar percentage, the "lowest" summary, and sparklines.

## [0.2.1-alpha.1] — 2026-10-21

Third alpha. One visible change: a stale card now tells you *why* it is stale.

### Added
- `UsageSnapshot.consecutiveFailures`: a stale card now says how many refreshes in a row
  failed (`stale · 4m ago · 3 failures`), and VoiceOver reads the count in words. Old
  caches decode with a count of 0; `0` always means the last attempt succeeded.

## [0.2.0-alpha.1] — 2026-10-21

Second alpha. Focus: making the numbers **trustworthy** — where each value came from, how it
has been moving, and telling you before a limit is hit.

### Added
- `Source.appServer`: snapshots now record which Codex strategy produced them, so the card can
  badge the documented path (`APP SERVER`) instead of reporting `api` for everything.
- `UsageSnapshot.resetCredits`: Codex reset-credit availability is a real field, shown as
  `N resets` on the card, instead of being appended to the plan string.
- Quota alerts: `NotificationPlanner` in `UsageCore` decides when a window reaches 80% or
  95% or is about to reset, and the app delivers them through `UNUserNotificationCenter`.
  Off by default; permission is requested only when the master toggle is switched on, and
  each window alerts once per reset cycle (deduped across relaunches for 48 h).
- `SnapshotHistory` in `UsageCore`: bounded per-provider/window sample history (7-day
  retention, 720 points per series, newest kept) written atomically to `history.json`.
  Estimated and placeholder windows are never recorded, duplicate `capturedAt` values are
  rejected, and a corrupt file reads as an empty history. Storage only; the card sparkline
  consumes it.
- Seven-day sparkline on each provider card: remaining fraction for the card's longest-horizon
  window, fixed `0…1` domain, no axes or legend, hidden until two samples exist. The trail is
  spoken to VoiceOver as a trend sentence rather than hidden as decoration.

### Fixed
- An unauthenticated `codex app-server` reported `app-server-rpc-32600` and then fell through to
  the HTTP strategy, which fails the same way later. An "authentication required" RPC error is
  now classified as `needs login` and ends the strategy loop. The error text is never stored or
  logged — only a single classified bit travels with the error.

## [0.1.0-alpha.1] — 2026-10-21

First runnable alpha. A menu-bar app that shows **remaining** quota for Claude Code,
OpenAI Codex, OpenCode Go, and (opt-in) Antigravity.

### Added
- `UsageCore` library: provider protocol, per-provider parsers, `PollScheduler`
  (independent per-provider schedules, 60 s floor, exponential backoff honouring
  `Retry-After`), atomic `SnapshotCache`, and a redacting credential wrapper.
- Claude Code provider: `GET /api/oauth/usage` with the mandatory `claude-code/*`
  User-Agent, 180 s floor, read-only Keychain access, no token refresh.
- OpenAI Codex provider: `codex app-server` JSON-RPC strategy with HTTP and
  local JSONL fallbacks; `not installed` is a first-class state.
- OpenCode Go provider: `GET /zen/go/v1/usage` (`rolling` / `weekly` / `monthly`),
  `403` surfaced as `not subscribed`.
- Antigravity provider: runs `agy` once per poll, parses the usage report, never
  reads Google credentials.
- Menu-bar app: `MenuBarExtra` label with a degradation ladder, popover with
  per-provider status cards, reset countdowns, `stale · Nm ago` labelling,
  settings (poll interval, which window drives the number, per-provider switches),
  and a first-run onboarding screen with the Claude OAuth read off by default.
- Generated product dashboard (`Scripts/status.sh`) driven by `docs/status/data.json`.

### Fixed
- Snapshot cache wrote to the pre-rename `UsageApp` directory; it now uses
  `~/Library/Application Support/Fillline`.

### Known limitations
- Unsigned (ad-hoc) builds re-prompt for Keychain access on every rebuild;
  Developer ID signing and notarization are not set up yet.
- Codex and Antigravity are not installed on the reference machine, so their
  live responses remain unverified.
- No notifications yet.

[Unreleased]: https://github.com/ies0411/Fillline/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/ies0411/Fillline/releases/tag/v0.1.0-alpha.1
