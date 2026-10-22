# Claude Code — usage source

Status: **verified live** (2026-10-21, macOS 26, Claude Code 2.1.x)
Provider ID: `claude-code`

## Decision

| Order | Source | Official? | Used for |
|---|---|---|---|
| 1 | `GET https://api.anthropic.com/api/oauth/usage` | undocumented | absolute % of the 5h session + weekly windows |
| 2 | `~/.claude/projects/**/*.jsonl` aggregation | local, official file format | token counts when the token read is off or the API cannot answer, **labelled `estimated`** (implemented in #16, see below) |
| — | `statusLine` stdin JSON (`rate_limits.*`) | **documented** | future opt-in: zero-credential path. Requires writing `~/.claude/settings.json`, so it needs explicit user consent |

Source 1 is **opt-in and off by default**, gated behind a "Read Claude Code login" toggle (see
§Legal). With the toggle off — the default — the card is served by source 2 and never touches
the Keychain; source 1 only wins when the user has opted in and the endpoint answers.

## Local-log aggregation (source 2, implemented 2026-10-23)

`ClaudeLocalLogAggregator` (`Sources/UsageCore/Providers/ClaudeCode/`) reads the transcripts
Claude Code already writes and reports token **quantities**. It is read-only: files are opened
with `FileHandle(forReadingFrom:)`, nothing under `~/.claude` is created, written or moved, and
no Keychain item, config file or network endpoint is touched.

### File shape

`~/.claude/projects/<project-slug>/<session-uuid>.jsonl`, newline-delimited JSON. Only
`type: "assistant"` records that carry `message.usage` are read:

```json
{"type":"assistant","timestamp":"2026-10-22T11:51:03.943Z","requestId":"req_…",
 "message":{"model":"claude-opus-5-5","usage":{
   "input_tokens":2,"output_tokens":324,
   "cache_creation_input_tokens":16191,"cache_read_input_tokens":29200}}}
```

`user`, `api-request`, `api-request-blob`, `attachment`, `permission-mode`, `last-prompt`,
`mode`, `atis-latch` and `summary` records are ignored. `timestamp` is ISO-8601 with
**milliseconds** and a `Z` suffix.

### Token definition

```
tokens = input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens
```

Every field is optional and a missing one counts as 0. Cache reads are the bulk of a real
session (16k cache_creation / 29k cache_read against 2 input tokens in the sample above), so
excluding them would understate usage by an order of magnitude — the number is documented rather
than hidden.

### Windows

- 5-hour total: `now - 5h <= timestamp <= now`.
- 7-day total: `now - 7d <= timestamp <= now`.
- **The left edge is inclusive**: a record exactly on a boundary counts. Records newer than
  `now` are ignored (clock skew). Membership is decided by `timestamp`, never by file order.
- The same `requestId` written more than once counts once (earliest copy wins).

### Output

| kind | label | value |
|---|---|---|
| `.rolling` | `"1.2M tokens · 5h"` | five-hour total |
| `.weekly7d` | `"6.3M tokens · 7d"` | seven-day total |

`source: .localLogs`, `status: .ok`. Empty/absent directory or no assistant records →
`status: .unsupported` with no windows (never `0%`). Unreadable files and symbolic links are
skipped, not followed.

**No percentage is ever produced.** Local logs contain no plan limit, so there is nothing to
divide by: `usedFraction` stays at the model's "no fraction" value (`0` — the model deliberately
has no optional fraction) and the label carries the quantity. `isEstimated: true` and the
existing amount-row path (`UsageFormat.isAmountRow`) render the row as text with no meter and
keep it out of the menu-bar percentage, the "lowest" summary, sparklines and alerts.

### Freshness caveat

These numbers describe **your own usage, not the provider's remaining quota**. Claude's 5-hour
session and weekly limits cannot be derived from local logs, so the card says `Estimated` and
shows a count. With the token read on, a successful API response wins and this path is not
shown; it only stands in when the credential or endpoint cannot answer, and then the failure
status is kept so stale API values are never replaced by an estimate.

### Incremental scan

Each file's `(offset, size, mtime)` is remembered and a poll parses only the appended byte range.
A truncated or in-place rewritten file resets that file's offset and records. Only
newline-terminated lines are consumed, so a crash-truncated tail is re-read after the next append
instead of counted twice. Malformed lines are skipped and counted internally; the count is never
shown in UI copy. A directory that grows to 47 files / 7,459 lines today costs one full scan after
launch and only appended bytes afterwards.

## Credential

- macOS Keychain, generic password, `service = "Claude Code-credentials"`, `account = $USER`.
- Value is JSON:
  ```json
  { "claudeAiOauth": { "accessToken": "sk-ant-oat01-…", "refreshToken": "sk-ant-ort01-…",
                       "expiresAt": 1792562995630, "refreshTokenExpiresAt": 0,
                       "scopes": ["user:profile", "user:inference", …],
                       "subscriptionType": "team", "rateLimitTier": "default_claude_max_5x" },
    "trustedDeviceToken": "…" }
  ```
- `expiresAt` is epoch **milliseconds** (the API's `resets_at` is ISO8601 — do not confuse them).
- `user:profile` scope is required. A token minted by `claude setup-token` only has
  `user:inference` and **cannot** read usage → return `.needsLogin`.
- Some installs have only `mcpOAuth` and no `claudeAiOauth` → `.needsLogin`, never crash.
- Fallback path `~/.claude/.credentials.json` (mode 0600) exists on some setups; use
  "freshest `expiresAt` wins", never file-first (a stale file yields HTTP 429, see below).
- **We do not refresh.** Refresh tokens are single-use and rotating them can log the user out of
  their real CLI session. On expiry: `.needsLogin` + "run any Claude Code command to refresh".

## Request

```
GET /api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/2.1.80      # MANDATORY
```
The `User-Agent` is not cosmetic: requests without a `claude-code/*` UA are bucketed
punitively and return a persistent 429 with `retry-after: 0`.
Minimum poll interval 180s (the limit appears to be ~5 requests per access token).

## Captured response (2026-10-21, masked)

```json
{
  "five_hour":  { "utilization": 2.0,  "resets_at": "2026-10-21T08:39:59.776536+00:00",
                  "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null },
  "seven_day":  { "utilization": 20.0, "resets_at": "2026-10-24T15:59:59.776553+00:00", … },
  "seven_day_opus": null, "seven_day_sonnet": null, "seven_day_oauth_apps": null,
  "limits": [
    { "kind": "session",       "group": "session", "percent": 2,  "severity": "normal", "resets_at": "…", "scope": null },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 20, "severity": "normal", "resets_at": "…", "scope": null },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 0,  "severity": "normal", "resets_at": "…",
      "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } }
  ],
  "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null },
  "spend": { "enabled": false, "percent": null, "used": null, "limit": null, … }
}
```

Traps observed:
- `resets_at` carries **6 fractional digits** → `ISO8601DateFormatter()` default fails; use
  `ISO8601FormatStyle(includingFractionalSeconds: true)` or a `.withFractionalSeconds` formatter.
- The empty codename keys (`tangelo`, `amber_ladder`, `granite_teacup`, `weekly_scoped_shares`,
  `member_dashboard_available`, …) are feature flags / future buckets. Do **not** model them;
  decode tolerantly and ignore unknown keys.
- `utilization`/`percent` are **0–100 used**, not fractions. Remaining = `100 − used`.
- Any bucket may be `null` (especially `seven_day_opus`, which is unused on team plans).

## Failure modes

| HTTP | Meaning | App state |
|---|---|---|
| 401 | token expired / wrong scope | `.needsLogin` |
| 429 | per-token rate limit (often self-inflicted by missing UA) | `.rateLimited`, back off, keep last-good |
| 403 | plan does not expose usage | `.unsupported` |
| 5xx / timeout | transient | `.stale(age)` after backoff |

## 두 경로의 트레이드오프 (2026-10-22 결정)

| | A. OAuth usage 엔드포인트 (현재) | B. `statusLine` 훅 (이슈 #10) |
|---|---|---|
| 문서화 | ❌ 비공식, UA 위장 필요 | ✅ 공식 설정 옵션 |
| 토큰 열람 | ⚠️ Keychain에서 읽음 | ✅ 읽지 않음 |
| 정책 리스크 | Anthropic 자격증명 정책과 충돌 소지 | 낮음 (사용자가 자기 설정에 명령 등록) |
| 최신성 | 앱이 원할 때 폴링 (180s) | Claude Code가 화면을 그릴 때만 갱신 |
| 설치 마찰 | 토글 1개 | `~/.claude/settings.json` 수정 동의 필요 |
| 앱 미사용 시 | 계속 갱신 | 값이 멈춤 → `.stale` 표시 |

**결정:** A를 유지하되 **"Advanced · Claude Code"로 강등**하고 기본 off (v0.3.0에서 UI 반영 완료).
B는 #10으로 구현하되, 켜져 있으면 A를 자동으로 끈다(둘 중 하나만). 둘 다 기본값이 아니다 —
기본 상태의 Claude 카드는 로컬 로그 집계(`estimated`)만 보여준다 (소스 2는 #16에서 구현:
퍼센트 없이 5h/7d 토큰 수량만).

## Legal

Anthropic's Claude Code docs (*Authentication and credential use*) state that OAuth tokens are for
"ordinary use of Claude Code and other native Anthropic applications" and that "developers may not
collect, store, or intermediate Claude.ai credentials or session tokens".
→ Consequences we enforce in code and docs:
1. Opt-in toggle, default **off** on first launch, with a one-screen explanation.
2. Token read into memory only; never written to disk, logs, crash reports, or IPC.
3. No credential-holding wrapper, no proxying, no multi-account support.
4. README links the policy and says the feature may be removed if Anthropic objects.

## Breakage history to watch

- `anthropics/claude-code` #30930, #31021, #31637 — usage endpoint 429 storms, per-token limits.
- #45133 — `rate_limits` missing from statusLine JSON on some 2.1.x builds.
- #77697, #81707, #89985 — Keychain ACL prompts after each token refresh.
