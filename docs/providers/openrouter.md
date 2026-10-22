# OpenRouter — credit balance source

Status: **contract-implemented, not captured live** (2026-10-22 — no OpenRouter key on the dev
machine; the shape below is the documented key endpoint plus issue #13's field list).
Provider ID: `openrouter`
Opt-in: **off by default** (needs a key the user owns).

## Decision

| Order | Source | Official? | Notes |
|---|---|---|---|
| 1 | `GET https://openrouter.ai/api/v1/key` | documented | key limit / effective budget |
| 2 | last-good snapshot | — | labelled `stale · Nm ago` |

Explicitly **not** used:

- `GET /api/v1/credits` — the *account* balance, but management-key only; an inference key gets
  **403**. v1 does not call it, so no 403 noise and no second credential class.
- the OpenRouter web session / cookies — out of scope for a no-login app (issue #13).
- `rate_limit` in the key response — deprecated server-side; not even decoded.

## Credential

Discovery order (first hit wins):

1. `$OPENROUTER_API_KEY`
2. `$XDG_DATA_HOME/opencode/auth.json` → default `~/.local/share/opencode/auth.json`,
   entry `openrouter`, field `.key` → `.access` → `.token`
3. the app's own keychain item — service `dev.ies0411.fillline`, account `openrouter`, read-only
   (a bare token or `{"key": "…"}` both parse; a future paste UI can write it, this app only reads)
4. otherwise `.needsLogin`

Read-only everywhere. The key never expires on a clock, and nothing here refreshes or writes it.

## Request

```
GET https://openrouter.ai/api/v1/key
Authorization: Bearer <key>
Accept: application/json
```

Host is `openrouter.ai`; `api.openrouter.ai` does not resolve.

## Expected response

```json
{ "data": {
    "label": "sk-or-…",
    "limit": 20.0,
    "usage": 11.5,
    "limit_remaining": 8.5,
    "limit_reset": "monthly",
    "is_free_tier": false,
    "effective_budget": {
      "limit_usd": 20.0, "remaining_usd": 8.5, "limit_reset": "monthly",
      "resets_at": "2026-11-01T00:00:00.000Z" },
    "budgets": [
      { "limit_usd": 20.0, "remaining_usd": 8.5, "limit_reset": "monthly",
        "resets_at": "2026-11-01T00:00:00.000Z" } ] } }
```

## Mapping — money, not a percentage

| Field | Use |
|---|---|
| `effective_budget.remaining_usd` | **first choice** for the balance |
| `limit_remaining` | fallback (the *key's* remaining limit, not the account balance) |
| `limit` / `effective_budget.limit_usd` | only to decide whether a cap exists |
| `budgets[].resets_at` | reset countdown, ISO-8601 **with milliseconds** |
| `is_free_tier` | plan badge `Free` |

The window is a single `.credits` row:

- `label` = `"$8.50 left"`, or `"$8.50 left · no cap"` when no key limit is known;
- `usedFraction` stays `0` and means nothing — the UI renders an **amount row** (a `.credits` row
  whose label starts with `$`) as text: no meter, no percentage, no "x% used" caption, and it is
  kept out of the percent-driven menu-bar number and sparkline;
- a negative balance is shown as `-$0.25 left`, never clamped to zero;
- if the payload reports **no** balance at all, the provider returns no windows. A 0% or 100% bar
  would be a fabricated reading, which AGENTS §9 forbids.

Amount encoding is a label convention on purpose: `LimitWindow`/`UsageSnapshot` stay unchanged
(issue #13), and no second money model exists yet.

## Failure modes

| HTTP | Meaning | App state |
|---|---|---|
| 200 | ok | `.ok` (possibly with no windows) |
| 401 | bad/revoked key | `.needsLogin` |
| 403 | key not allowed for this endpoint | `.error("http-403")` (quiet; no retry storm) |
| 429 | rate limited | `.rateLimited`, back off |

Minimum interval: **120 s**; default poll stays 300 s. Both are also enforced on manual refresh.

## Legal / privacy

- One documented GET per poll, with the user's own key. No cookies, no web session, no scraping.
- The key is held in memory only, never logged (it sits inside a `Credential`, whose textual forms
  are `<redacted>`), and never written back to `auth.json` or the keychain.
- Only `openrouter.ai` is in the network allowlist.
