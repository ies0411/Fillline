# OpenCode Go — usage source

Status: **verified live** (2026-10-21). This is the only provider whose primary source is a plain,
stable JSON API with no cookies and no keychain.
Provider ID: `opencode-go`

## Decision

| Order | Source | Official? | Notes |
|---|---|---|---|
| 1 | `GET https://opencode.ai/zen/go/v1/usage` | documented in practice (used by Vendor tray/CLI) | `rolling` (5h) + `weekly` + `monthly` |
| 2 | last-good snapshot | — | labelled `stale · Nm ago` |

Nothing else. No local log aggregation, no scraping — the numbers are already server-side.

## Credential

Discovery order (first hit wins):
1. `$OPENCODE_API_KEY`
2. `$XDG_CONFIG_HOME/opencode/.secrets/opencode-key` → default `~/.config/opencode/.secrets/opencode-key`
   (single line, mode 0600, trim whitespace; format `oc_sk_…`, 51 chars)
3. `$XDG_DATA_HOME/opencode/auth.json` → default `~/.local/share/opencode/auth.json`,
   entry `opencode-go` then `opencode`, field `.key`

Notes: this key is a **pay-as-you-go / subscription API key**, not an OAuth session. It does not
expire on a 10-day clock and we never refresh it. `~/.local/share/opencode/opencode.db` may hold it
on newer builds — if neither file exists, show `.needsLogin` with a link to the OpenCode dashboard
rather than opening the DB (SQLite reads on someone's session DB are not worth the risk).

## Request

```
GET https://opencode.ai/zen/go/v1/usage
Authorization: Bearer <key>
```

## Captured response (2026-10-21)

```json
{ "usage": {
    "rolling": { "status": "ok", "percent": 0,  "resetsAt": "2026-10-21T05:44:23.000Z" },
    "weekly":  { "status": "ok", "percent": 59, "resetsAt": "2026-10-26T00:00:00.000Z" },
    "monthly": { "status": "ok", "percent": 74, "resetsAt": "2026-11-15T23:19:28.000Z" } } }
```

Mapping:
- `rolling` → `.session5h` (label "Rolling"), `weekly` → `.weekly7d`, `monthly` → `.monthly30d`.
- `percent` is **0–100 used** (not a fraction). Remaining = `100 − used`.
- `resetsAt` is ISO8601 with milliseconds (`…:23.000Z`) → `withFractionalSeconds` formatter.
- `percent == 0` means the upstream `resetsAt` is a `now + window` placeholder, not a real reset
  → keep the window but mark `isPlaceholder: true` and grey the countdown in the UI.
- Each window has its own `status` (`ok` / …). Treat a window whose `status != "ok"` as
  "no data for this window", not as 0%.

## Failure modes

| HTTP | Meaning | App state |
|---|---|---|
| 401 | invalid/revoked key | `.needsLogin` |
| 403 | valid key, **no Go subscription** | `.notSubscribed` — "This key has no Go plan" |
| 429 | rate limited | `.rateLimited`, back off |
| 404 | endpoint moved | `.unsupported` + telemetry-free warning in logs |

The response shape already changed once within an hour of launch: parse each window
defensively (all fields optional), and never assume a window is present.

## Legal

No credential intermediation, no cookies, no first-party-client impersonation. The endpoint is the
same one the vendor's own tooling calls with the user's own key. Domain is in the app's allowlist
(`opencode.ai`) and is the only outbound host for this provider.
