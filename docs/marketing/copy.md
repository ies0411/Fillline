# Fillline — 카피 뱅크

> 사실만 쓴다. 검증되지 않은 수치·후기는 넣지 않는다.
> 공개 카피는 **영어가 기본**(레포/README/HN/PH), 한국어는 KO 채널(X, 블로그, 국내 커뮤니티)용.

## 0. 톤

- 짧은 문장. 형용사 대신 숫자와 상태.
- 자랑하지 않고 **한계를 먼저** 말한다(비문서화 엔드포인트, ad-hoc 알파).
- "남은", "left", "before you hit the wall"을 반복해 포지션을 고정.
- 금지어: revolutionary, seamless, supercharge, 10x, game-changer, "official".

## 1. 한 줄 (one-liner)

| 용도 | 문구 |
|---|---|
| GitHub description | `See how much AI coding quota you have left — Claude Code, Codex, OpenCode Go and Antigravity — in your macOS menu bar. Remaining % first, honest staleness, no telemetry.` |
| 메뉴바 앱 한 줄 | **`The fill line for your AI coding quota.`** |
| 대체 | `Know what's left before you hit the limit.` |
| KO | **`AI 코딩 한도, 남은 게 얼마인지 메뉴바에서.`** |

## 2. README 히어로 (상단 3줄)

```markdown
# Fillline

**See how much AI coding quota you have left — before you hit the wall.**

A macOS menu-bar app for Claude Code, OpenAI Codex, OpenCode Go and Antigravity.
Remaining-% first, honest staleness (`stale · 4m ago · 3 failures`), read-only credentials,
no token refresh, no telemetry. MIT, zero dependencies, ~2 MB.
```

KO 버전:

```markdown
**AI 코딩 한도가 얼마나 남았는지, 부딪히기 전에 보세요.**
Claude Code · OpenAI Codex · OpenCode Go · Antigravity를 위한 macOS 메뉴바 앱.
남은 % 우선, 정직한 stale 표시, 자격증명 읽기 전용, 토큰 refresh 없음, 텔레메트리 없음.
```

## 3. Show HN

**Title** (≤ 80자):
`Show HN: Fillline – remaining AI coding quota in the macOS menu bar`

**Body**:

> I kept burning through my Claude Code 5-hour window and only noticing when the CLI stopped.
> Every quota tool I found answers "how much have I used?" — I wanted the opposite question:
> **how much is left, and when does it reset?**
>
> Fillline is a menu-bar app for four tools: Claude Code, OpenAI Codex, OpenCode Go and
> Antigravity. The number in the menu bar is remaining %, per provider; the popover shows the
> windows (5-hour/weekly/rolling/monthly), a reset countdown, and a 7-day trail.
>
> Two things I deliberately did differently:
>
> 1. **Never lie about a stale value.** If a refresh fails, the card keeps the last known value
>    and says `stale · 4m ago · 3 failures — showing last known values.` It never falls back to 0%.
> 2. **Be explicit about credentials.** Only Claude Code's path reads a token (Keychain, opt-in,
>    in memory, never refreshed — refreshing would rotate it and log out the CLI). Codex runs
>    `codex app-server` and reads its response; Antigravity runs `agy` and reads its report;
>    OpenCode Go uses your own API key. The asymmetry is in the README instead of hidden.
>
> Honest limits: Anthropic's `/api/oauth/usage` and `chatgpt.com/backend-api/wham/usage` are
> undocumented, so they can break without notice — that's why every provider has a fallback and
> a fixture-tested parser. The alphas are ad-hoc signed; notarization is next.
>
> Swift 6, SwiftUI, zero dependencies, MIT. Source and a live project dashboard:
> https://github.com/ies0411/Fillline

**첫 댓글(작성자)** — 기술 질문을 미리 흡수:

> Architecture note: a testable `UsageCore` library (no AppKit) with per-provider ordered
> strategies (`app-server` → internal HTTP → local logs → cache), an actor `PollScheduler` with
> 60 s floor (180 s for Claude, which rate-limits aggressively), and `SnapshotHistory` for the
> sparkline. Tests are fixture-driven; 138 of them. You can build the core with Command Line
> Tools alone (`swift build`), the app needs Xcode.

## 4. Reddit

### r/macapps

**Title**: `Fillline – a menu-bar app that shows how much AI coding quota you have LEFT`

> Most quota apps tell you what you've used. I wanted the remaining number in the menu bar,
> because that's what decides whether I can start another task.
>
> Supports Claude Code, Codex, OpenCode Go and Antigravity. Menu bar shows `C 62% · O 40% · G 24%`;
> click for per-window meters, reset countdowns, and a 7-day trend.
>
> Things I'd want to know before installing:
> - It reads your Claude Code token from the Keychain **only if you turn it on** (default off),
>   keeps it in memory, and never refreshes it.
> - It never shows 0% when it simply failed to refresh — you get `stale · 4m ago` instead.
> - No telemetry, no account, no backend. MIT, zero dependencies.
> - Two of the endpoints are undocumented, so a provider can break after a CLI update. Fallbacks exist.
>
> Feedback on the menu-bar label (too busy? which window should it show?) is exactly what I need.

### r/ClaudeAI (자기홍보 규칙 확인 후)

> **Title**: `I built a menu-bar meter for the 5-hour and weekly windows (open source, opt-in token read)`
>
> Body: 위와 동일하되 3문단으로 축약. **"토큰을 읽는다"는 사실을 첫 문단에** 둔다.

## 5. X / Threads

1. `Your Claude Code 5h window is at 20% and you find out by getting blocked.`
2. `Fillline puts the remaining number in your menu bar. Four providers, one glance.` + GIF
3. `It never shows 0% when a refresh fails. It says: stale · 4m ago · 3 failures — showing last known values.`
4. `Only Claude's token is read (opt-in, memory only, never refreshed). Codex/Antigravity: we run the CLI. Go: your own API key.`
5. `Swift 6, zero deps, MIT. macOS 14+.` + repo link

KO 버전(1트윗): `클로드 5시간 창 20% 남은 걸 한도에 걸린 뒤에 알게 되죠. Fillline은 남은 %를 메뉴바에 띄웁니다. 4개 프로바이더, 텔레메트리 없음, MIT.`

## 6. Product Hunt

- **Tagline** (≤ 60): `See how much AI coding quota you have left`
- **Description** (≤ 260): `Fillline lives in your macOS menu bar and shows remaining Claude Code, Codex, OpenCode Go and Antigravity quota — with reset countdowns, a 7-day trend, and honest "stale" labelling instead of a fake 0%. Open source, no telemetry, read-only credentials.`
- **First comment**: Show HN 본문의 1·2번 문단을 압축 + "MIT, feedback welcome on the menu-bar label".

## 7. Homebrew cask

```ruby
desc "Menu-bar meter for remaining AI coding quota (Claude Code, Codex, OpenCode Go, Antigravity)"
homepage "https://github.com/ies0411/Fillline"
```

## 8. Awesome-list 한 줄

`[Fillline](https://github.com/ies0411/Fillline) — Menu-bar app showing remaining Claude Code / Codex / OpenCode Go / Antigravity quota; open source, no telemetry.`

## 9. FAQ (README/댓글 공용)

**Does it read my tokens?**
Only the Claude Code path, and only if you enable it. The token is read from the Keychain into
memory, never written to disk, never logged, never sent anywhere except `api.anthropic.com`.
Codex and Antigravity are driven by running their CLIs; OpenCode Go uses your own key.

**What happens when a provider breaks?**
The card keeps the last successful value, labels it `stale`, and shows how long ago plus how many
consecutive failures. It never displays 0% as a substitute for "unknown".

**Is this allowed by the providers' terms?**
Two of the endpoints are undocumented. That's a real risk, stated in the README: accounts can be
rate-limited or flagged. Claude's path is opt-in for that reason, and Codex prefers the documented
`app-server` interface. If a provider objects, the feature comes out.

**Why not just use the CLI?**
You can — and you'll see the numbers when you think to look. The point is the glanceable number
you see while deciding whether to start another task.

**Why is the app not on the Mac App Store?**
It needs to read `~/.claude`, `~/.codex`, `~/.config/opencode` and a pre-existing Keychain item,
which the sandbox forbids. It ships Developer ID signed and notarized from GitHub Releases.

**Does it work offline / with no account?**
Yes for Claude with the opt-in off (local log aggregation, labelled estimated). Live numbers need
the provider's own credential, which its CLI already stores.

## 10. 금지 문구 (체크리스트)

- [ ] "official" / "partnered with Anthropic, OpenAI, Google" — ❌
- [ ] "100% safe / ToS-compliant" — ❌
- [ ] "never reads your tokens" — ❌ (Claude 경로는 읽는다)
- [ ] "always accurate" — ❌
- [ ] 검증되지 않은 인용/별점/사용자 수 — ❌
