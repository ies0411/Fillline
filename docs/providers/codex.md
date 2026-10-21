# OpenAI Codex — usage source

Status: **contract-only** (Codex CLI not installed on the reference machine; response shape taken
from the documented app-server RPC + observed `/wham/usage` payloads). Re-verify with a live
capture during Phase 1.
Provider ID: `codex`

## Decision

| Order | Source | Official? | Notes |
|---|---|---|---|
| 1 | `codex app-server` → `account/rateLimits/read` (JSON-RPC over stdio) | **documented** | richest: `rateLimitsByLimitId` buckets + reset credits; we never touch the token |
| 2 | `GET https://chatgpt.com/backend-api/wham/usage` | internal HTTP | one request, needs the CLI's access token |
| 3 | newest `$CODEX_HOME/sessions/**/*.jsonl` `payload.rate_limits` block | local log | last resort, labelled with its own age (not implemented yet) |

Implemented in `Sources/UsageCore/Providers/Codex/` as `CodexStrategy.defaultOrder = [.appServer, .http]`:
strategy 1 is tried first, a missing `codex` binary is a typed `.notInstalled` that falls through to
strategy 2, and if everything fails the **last** failure is surfaced. Both strategies currently report
`Source.api`, so the UI cannot yet say which one won (tracked in AGENTS §10).

## Credential

`$CODEX_HOME/auth.json` (default `~/.codex/auth.json`):
```json
{ "OPENAI_API_KEY": null,
  "tokens": { "id_token": "<jwt>", "access_token": "<jwt>", "refresh_token": "<opaque>", "account_id": "<uuid>" },
  "last_refresh": "2026-10-20T…Z", "auth_mode": "chatgpt" }
```
- `cli_auth_credentials_store` in `~/.codex/config.toml` may be `file` (default), `keyring`
  (Keychain service `Codex Auth`, account `cli|<sha256(path)[:16]>`), `auto`, or `ephemeral`.
  With `keyring` the file is deleted → we must fall back to Keychain (Phase 1).
- `access_token` is a JWT: `exp` gives expiry, and
  `https://api.openai.com/auth.chatgpt_plan_type` gives plan (`plus`, `pro`, …) with **no network call**.
- **Never refresh.** Refreshing rotates the refresh token and can revoke the CLI's own session.
  On expiry → `.needsLogin`, message "run `codex` once to refresh".
- If a token looks stale, retry the *other* credential store before reporting `.needsLogin`
  (a stale Keychain item shadowing a fresh `auth.json` is a known failure mode).

## Request

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <tokens.access_token>
ChatGPT-Account-Id: <tokens.account_id>
User-Agent: codex-cli
```
If `~/.codex/config.toml` sets `chatgpt_base_url` without `/backend-api`, the path becomes
`/api/codex/usage` — read the config before hardcoding.

## Expected response

```json
{
  "plan_type": "plus",
  "rate_limit": {
    "allowed": true, "limit_reached": false,
    "primary_window":   { "used_percent": 55, "limit_window_seconds": 18000, "reset_at": 1778670307, "reset_after_seconds": 2547 },
    "secondary_window": { "used_percent": 51, "limit_window_seconds": 604800, "reset_at": 1779157165 }
  },
  "additional_rate_limits": [],
  "credits": { "has_credits": false, "unlimited": false, "balance": "0" },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": null
}
```

Mapping:
- `primary_window` → `LimitWindow(kind: .session5h)` (`limit_window_seconds == 18000`).
- `secondary_window` → `.weekly7d` (`604800`).
- `additional_rate_limits[]` → extra `.weeklyScoped` windows labelled by `limit_name`
  (e.g. `gpt-5.3-codex-spark`).
- `reset_at` is epoch **seconds** (Claude's is ISO8601 — keep the two parsers separate).
- `used_percent` is 0–100 used. Remaining = `100 − used`.
- `credits.balance` is a **string**; show only if `has_credits` is true and `unlimited` is false.
- app-server additionally returns `rateLimitsByLimitId` (`codex`, `codex_other`, `codex-spark`) and
  `rateLimitResetCredits { availableCount, credits[] }`.

## app-server protocol notes (implemented)

- Spawn `codex app-server --listen stdio://`; newline-delimited JSON, **no `"jsonrpc"` field**.
- `{"id":1,"method":"initialize","params":{"clientInfo":{…}}}` → `initialized` notification →
  `{"id":2,"method":"account/rateLimits/read"}`.
- 10s hard timeout for the whole exchange; stdin closed before SIGTERM, SIGKILL after 2s, always reaped.
  stderr is drained but only its **byte count** is logged (it can contain tokens).
- Response parsing is tolerant by design: accepts `usedPercent`/`used_percent`,
  `windowMinutes`/`window_minutes`/`limit_window_seconds`, and `resetsAt` as either epoch seconds or ISO-8601.
- `windowMinutes` 300 → `session5h`, 10080 → `weekly7d`, anything else → `Kind.rolling` with a
  human label (`3h`, `2d`). `rateLimitsByLimitId` keys other than the default get a ` (other)` suffix.
- `credits.balance` surfaces only when `hasCredits && !unlimited`, as a `Credits · N` window with no
  fraction. `rateLimitResetCredits.availableCount` is appended to the plan string
  (`"plus · 2 reset credits"`) because `UsageSnapshot` has no dedicated field yet.
- RPC failures are reduced to stable codes (`app-server-rpc-<abs code>`) — message text never reaches
  the UI or logs.

## Failure modes

| Condition | App state |
|---|---|
| `~/.codex` missing | `.notInstalled` — card shows "Codex CLI not installed" |
| `401` / JWT `exp` in the past | `.needsLogin` |
| `limit_reached: true` | `.ok` but window at 100% — surface "limit reached, resets HH:MM" |
| `rate_limits: null` in local logs | treat as "no data", not as 0% |

## Legal

`/backend-api/wham/usage` is an internal ChatGPT backend endpoint, not part of the public API.
Reading one's own quota is not prohibited anywhere we found, but no license is granted either.
Prefer the documented app-server method in the shipped default path, and keep the HTTP strategy
as a visible fallback in settings. Never resell or proxy inference.
