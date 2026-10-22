# GitHub Copilot — usage source

Status: **verified live** (2026-10-22, HTTP 200; free limited account, values masked).
Provider ID: `github-copilot`
Opt-in: **off by default** (it reads a credential through `gh`).

## Decision

| Order | Source | Official? | Notes |
|---|---|---|---|
| 1 | `GET https://api.github.com/copilot_internal/user` | undocumented (the endpoint the Copilot editor extensions call) | `quota_snapshots` buckets |
| 2 | last-good snapshot | — | labelled `stale · Nm ago` |

Nothing else: no scraping of the Copilot extension's storage, no web-session cookies, and no
`/copilot_internal/v2/token` (that path mints short-lived inference tokens, which this app has no
reason to hold).

## Credential

Discovery order (first hit wins):

1. `$GH_TOKEN`, then `$GITHUB_TOKEN` (the overrides `gh` itself documents);
2. `gh auth token` — the GitHub CLI prints the token it already stores;
3. otherwise `.notInstalled` (no `gh` on `PATH`) or `.needsLogin` (installed, signed out).

`gh` stays the owner of the OAuth session. This app **never** refreshes or writes a GitHub token:
a rotating refresh token consumed twice would end the user's CLI session (AGENTS §2).

The subprocess is deliberately small and boring:

- direct `exec` of the `gh` binary — never `/bin/sh -c`, so no shell parsing of anything;
- `auth token` only, with `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, `GH_PAGER=cat`;
- `BROWSER=/usr/bin/false`, so an unexpected auth failure cannot open a window during a refresh;
- a minimal environment allowlist (`HOME`, `PATH`, `XDG_*`, `TMPDIR`) — no `DISPLAY`, no token;
- stdin `/dev/null`, cwd = the system temp directory (never `$HOME`, never the repo);
- 5 s wall clock, then SIGTERM → SIGKILL → reap;
- diagnostics are **exit code and stderr byte count only**. stderr can contain the signed-in
  account name, so its text never leaves the runner.

## Request

```
GET https://api.github.com/copilot_internal/user
Authorization: Bearer <token from gh>
Accept: application/json
User-Agent: GitHubCopilotChat/0.23.2
Editor-Version: vscode/1.96.2
Editor-Plugin-Version: copilot-chat/0.23.2
X-GitHub-Api-Version: 2022-11-28
```

The `Editor-*` headers matter: without a Copilot-client identity the endpoint answers 401/403 for
otherwise valid tokens. They live in `GitHubCopilotEndpoints.swift` with the URL.

## Captured response (2026-10-22, redacted)

```json
{
  "copilot_plan": "individual",
  "access_type_sku": "free_limited_copilot",
  "quota_reset_date": "2026-11-01",
  "quota_reset_date_utc": "2026-11-01T00:00:00.000Z",
  "quota_snapshots": {
    "premium_interactions": {
      "entitlement": 0, "remaining": 0, "percent_remaining": 0.0,
      "unlimited": false, "has_quota": false, "quota_reset_at": 0,
      "quota_id": "premium_interactions"
    },
    "chat": {
      "entitlement": 200, "remaining": 200, "percent_remaining": 100.0,
      "unlimited": false, "has_quota": true, "quota_reset_at": 0,
      "quota_id": "chat"
    },
    "completions": {
      "entitlement": 2000, "remaining": 2000, "percent_remaining": 100.0,
      "unlimited": false, "has_quota": true, "quota_reset_at": 0,
      "quota_id": "completions"
    }
  }
}
```

(`login`, `id`, `analytics_tracking_id`, `organization_list` and the rest of the account envelope
are dropped: this app needs none of it and never stores it.)

## Mapping

| Bucket | Label | Kind |
|---|---|---|
| `premium_interactions` | `Premium` | `.monthly` |
| `chat` | `Chat` | `.monthly` |
| `completions` | `Completions` | `.monthly` |

- **`percent_remaining` is 0–100 REMAINING** — the opposite polarity of Claude/Codex/OpenCode Go.
  `usedFraction = (100 − p) / 100`, so the card's "40% remaining" is the provider's 40.
- `remaining / entitlement` is used only when `percent_remaining` is absent.
- `unlimited: true` buckets are **skipped** — there is no fraction to draw, and a 100% bar would be
  an invention.
- `entitlement <= 0` buckets are **skipped** for the same reason. The live free account reports
  `premium_interactions` that way; drawing it would show a permanent 0% bar.
- `quota_reset_at` is epoch **seconds**; the live payload sends `0`, which is treated as "no per-
  bucket reset" and falls back to `quota_reset_date_utc` (ISO-8601 with milliseconds) and then to
  `quota_reset_date` (`yyyy-MM-dd`, parsed as 00:00 UTC).
- `has_quota` and `credits_used` are ignored in v1 (not needed for the two windows above).
- `copilot_plan` becomes the plan badge (`individual` → `Individual`).

## Failure modes

| HTTP | Meaning | App state |
|---|---|---|
| 200 | ok | `.ok` |
| 401 | token rejected/expired | `.needsLogin` — `gh auth login` refreshes it |
| 403 | valid token, no Copilot seat for this account/org | `.notSubscribed` |
| 404 | endpoint not exposed for this account type | `.unsupported` |
| 429 | rate limited | `.rateLimited`, back off |

Minimum interval: 60 s (the base interval); default poll stays 300 s.

## Legal / privacy

- The endpoint is undocumented and may change without notice; every field is optional and unknown
  buckets are ignored, so a shape change degrades to "no windows", never to a wrong number.
- The token belongs to the user's own `gh` login and is used for exactly one request per poll.
  It is never logged, persisted, or refreshed.
- Only `api.github.com` is added to the network allowlist. Documentation links
  (`github.com/...`) are opened in the browser and are not part of the allowlist.
