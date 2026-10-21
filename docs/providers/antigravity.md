# Antigravity (Google) — usage source

Status: **contract-only** (`agy` is not installed on the reference machine; contract taken from the
official CLI docs + observed `/usage` JSON). Re-verify with a live capture when `agy` is available.
Provider ID: `antigravity` · Card label: "Antigravity"

## Why this provider exists and why "Gemini CLI" does not

Google's consumer Gemini CLI entitlement was **removed on 2026-06-18** for individuals, Google AI Pro
and Google AI Ultra (official deprecation page, last modified 2026-10-09). The failure is silent by
design:

1. `POST /v1internal:loadCodeAssist` → **HTTP 200**, no `currentTier`, and
   `ineligibleTiers[].reasonCode == "UNSUPPORTED_CLIENT"`.
2. `POST /v1internal:retrieveUserQuota` → **403 `SUBSCRIPTION_REQUIRED`** with no migration message.
3. The OAuth grant still refreshes — the *entitlement* is gone.

Enterprise/Standard seats and API-key auth are unaffected, but neither is what a consumer menu-bar app
is for. Antigravity is the only consumer surface Google still serves.

## Credentials: we never read them

Antigravity's Additional ToS §6 states that using third-party software/tools/services to access the
service "is a breach of this Agreement", with suspension/termination as the remedy — and Google
**enforced** this in Feb 2026 with mass 403 bans (permanent on the second violation, ToS amended
2026-09-03 to scope the penalty to the Antigravity/Gemini CLI accounts). Gemini CLI's own policy says
the same about "harvesting or piggybacking on Gemini CLI's OAuth authentication".

So we do **not** touch the Keychain item (`service "gemini"`, account `antigravity`), the file
fallback (`~/.gemini/antigravity-cli/antigravity-oauth-token`), the refresh token, or
`cloudcode-pa.googleapis.com`. Sending `User-Agent: antigravity` to that API would make it worse, not
better: deliberate client spoofing on top of an explicitly prohibited access pattern.

**What we do instead:** run the official client and read its own report. The grant is exercised by
Google's binary, not by us — structurally identical to Claude Code's documented `statusLine` and to
Codex's documented `app-server`.

## Invocation

```
agy -p /usage --output-format json --print-timeout 90s
```
- `/usage` (alias `/quota`) is documented at <https://antigravity.google/docs/cli/commands/usage/>;
  the headless docs explicitly say CLI-answered slash commands like `/model` and `/usage` "produce a
  text report rather than a standard event stream" and must be their own `--print` invocation.
- `--output-format json` and `--print-timeout` are both documented flags.
- `/usage` is answered by the CLI, not by a model turn → **no tokens spent**.
- Cost: each call cold-starts a full agent process. Poll at **≥ 5–10 min**, plus on popover open.
  Never 30s.
- Run it with `cwd` = a private temp dir (never `$HOME`, never the repo) and `BROWSER=/usr/bin/false`,
  so a silent-auth failure can never pop a browser out of a background refresh.
- 95s wall-clock timeout; SIGTERM then SIGKILL after 2s; always reap.

## Observed response

```json
{"command":{"name":"usage","data":{
  "groups":[
    {"displayName":"Gemini Models","buckets":[
      {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-10-21T12:00:00Z","remainingFraction":0.82},
      {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2026-10-27T00:00:00Z","remainingFraction":0.64}]},
    {"displayName":"Claude and GPT models","buckets":[
      {"bucketId":"3p-5h","window":"5h","resetTime":"2026-10-21T12:00:00Z","remainingFraction":0.35},
      {"bucketId":"3p-weekly","window":"weekly","resetTime":"2026-10-27T00:00:00Z","remainingFraction":0.71}]}]}}}
```

Mapping:
- **`remainingFraction` is remaining** (0–1) → `usedFraction = 1 − remainingFraction`. This is the
  opposite convention from Claude/Codex/OpenCode Go, which report *used* 0–100. Do not share the
  parser.
- `window == "5h"` → `.session5h`, `"weekly"` → `.weekly7d`. Labels carry the group
  (`Gemini · 5h`, `3P · Weekly`) because the two families have independent quotas.
- Buckets without `remainingFraction` are reset-time-only rows → skip them.
- Free/Starter accounts report **weekly only** → never synthesise a 5h row.
- Enterprise/Business have no per-model quotas (the CLI removed the usage panel) → `.unsupported`.
- The JSON payload is **observed, not contractual**: the flags are documented, the schema is not.
  Parse tolerantly, keep a plain-text fallback (`isEstimated: true`), and pin with fixtures.

## Failure modes

| Condition | App state |
|---|---|
| `agy` not on PATH | `.notInstalled` — "Antigravity CLI not found" |
| non-zero exit, stderr mentions auth/login | `.needsLogin` |
| exit 0, unrecognised envelope | text fallback, `isEstimated` on every window |
| both parsers fail | `.error("decoding-failed")` |
| enterprise account | `.unsupported` |
| timeout | `.error("timeout")`, keep last-good |

## Related, for reference only (do not implement)

The direct API (used by several OSS tools) is `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
with a bearer token from the keychain, returning `groups[].buckets[]{bucketId, window, resetTime, remainingFraction}`.
`fetchAvailableModels` returns a **pool-level** `quotaInfo` (burning one model moves every number by the
same amount), and `remainingAmount` has no total attached. Those tools are useful as protocol
documentation; they are ToS-breaching implementations, not precedent.

Also note: `~/.gemini/oauth_creds.json` is **legacy**. Gemini CLI moved its OAuth into
`HybridTokenStorage` — Keychain service `gemini-cli-oauth`, account `main-account` — and deletes the
file after migrating. Any doc still pointing at that file is stale.
