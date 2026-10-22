# Claude Code — usage source

Status: **verified live** (2026-10-21, macOS 26, Claude Code 2.1.x)
Provider ID: `claude-code`

## Decision

| Order | Source | Official? | Used for |
|---|---|---|---|
| 1 | `GET https://api.anthropic.com/api/oauth/usage` | undocumented | absolute % of the 5h session + weekly windows |
| 2 | `~/.claude/projects/**/*.jsonl` aggregation | local, official file format | token counts when the API is unavailable, **labelled `estimated`** |
| — | `statusLine` stdin JSON (`rate_limits.*`) | **documented** | future opt-in: zero-credential path. Requires writing `~/.claude/settings.json`, so it needs explicit user consent |

We ship source 1 as the default because it needs no config mutation, and gate it behind a
"Read Claude Code login" toggle (see §Legal).

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
기본 상태의 Claude 카드는 로컬 로그 집계(`estimated`)만 보여준다.

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
