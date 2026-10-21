# Deferred / rejected providers

Providers that were evaluated and are **not** shipped as specced, so the decision is not
re-litigated. Antigravity is now **implemented** — see `antigravity.md`.

## Google Gemini CLI — rejected (permanent, not deferred)

Consumer entitlement was removed on **2026-06-18** for individuals, Google AI Pro and Google AI Ultra
(official deprecation page, last modified 2026-10-09). The failure is silent by design:

1. `POST /v1internal:loadCodeAssist` → **HTTP 200**, no `currentTier`,
   `ineligibleTiers[].reasonCode == "UNSUPPORTED_CLIENT"`.
2. `POST /v1internal:retrieveUserQuota` → **403 `SUBSCRIPTION_REQUIRED`**, no migration wording.
3. The OAuth grant still refreshes — the entitlement is what disappeared.

There is no consumer quota path left:

| Attempt | Why it fails |
|---|---|
| `retrieveUserQuota` with the CLI's own token | 200 + `UNSUPPORTED_CLIENT`, then 403 (above) |
| `/stats` as a poller | session-scoped TUI text; no machine-readable schema; unreachable for consumer accounts |
| `-o json` | wraps the **model response** (`usage.input_tokens` …), not account quota |
| Reusing Google's first-party OAuth client secret | ToS violation (impersonation) |
| Reading the token and calling `cloudcode-pa` | Antigravity ToS §6 — see `antigravity.md`; enforced with permanent bans |

Also: `~/.gemini/oauth_creds.json` is **legacy**. Gemini CLI moved OAuth into `HybridTokenStorage`
(Keychain service `gemini-cli-oauth`, account `main-account`) and deletes the file after migrating.
Contributor notes and third-party docs that still point at that file are stale — including
`gemini-cli`'s own `docs/resources/quota-and-pricing.md`, which still promises 1,000/1,500/2,000
requests per day and "Log in with Google". Do not cite it.

Enterprise / Standard seats and API-key auth still work, but neither is what a menu-bar app is for; if
someone needs them, that is a separate provider.

## Adding a provider (checklist)

1. `Sources/UsageCore/Providers/<Name>/<Name>Endpoints.swift` — URLs, headers/argv, timeouts, and a
   comment stating the ToS position.
2. A `UsageProvider` conformance with an ordered strategy list (`primary → fallback → cached`).
3. Masked fixture in `Tests/UsageCoreTests/Fixtures/` + a fake transport (never a real process or a
   real account in tests).
4. Add the host (or the fact that there is no host, as with `agy`) to the domain allowlist constant
   **and** the CI allowlist grep.
5. A page here with: credential path (or explicitly "we never read it"), request contract, captured
   response, failure-mode table, legal paragraph. A PR without §5 is rejected.
6. Mind the units: Claude / Codex / OpenCode Go report **used** 0–100; Antigravity reports
   **remaining** 0–1. Never share a parser across providers.
