# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Provider endpoints are undocumented and can break between releases; a fix for a
broken parser ships as a patch release.

## [Unreleased]

### Added
- Codex `app-server` strategy (`account/rateLimits/read`) preferred over the internal HTTP endpoint.
- Antigravity provider that runs `agy -p /usage --output-format json` and parses its report
  (opt-in, off by default, 300 s floor, no credential access).

### Changed
- `UsageSnapshot.source` cannot yet distinguish app-server from HTTP; see AGENTS.md §10 #8.
- Reset-credit availability currently rides in the plan string; see AGENTS.md §10 #9.

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
