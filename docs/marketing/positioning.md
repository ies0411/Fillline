# Fillline — 포지셔닝

> 이 문서는 **주장의 근거**를 담는다. 카피(`copy.md`)와 런치 계획(`launch-plan.md`)은 여기서 파생된다.
> 경쟁 제품 정보는 2026-10-21 공개 페이지 기준이며, 인용 전에 반드시 재확인한다.

## 1. 한 줄 정의

**EN** — Fillline shows how much AI coding quota you have **left**, in your menu bar, before you hit the wall.
**KO** — Fillline은 AI 코딩 도구의 **남은 사용량**을 메뉴바에 상시 표시합니다. 한도에 부딪히기 전에 보이게.

한 줄 원칙: **"남은 %가 먼저, 사용 %는 보조."** 세상의 quota 도구 대부분은 "얼마나 썼나"를 보여준다.
Fillline은 "얼마나 남았나"를 보여준다 — 사용자가 실제로 알고 싶은 것.

## 2. 누가 쓰는가 (ICP)

| 세그먼트 | 상황 | Fillline이 파는 것 |
|---|---|---|
| **A. Claude Max 5x/20x 파워유저** | 5시간 창을 몇 번씩 리셋하며 하루를 설계. 한도에 걸리면 작업이 멈춤 | 5h·주간 잔여와 리셋 카운트다운을 항상 눈에 |
| **B. Codex Plus/Pro 개발자** | 세션·주간 창 + 리셋 크레딧. CLI에 quota 명령이 없음 | 세션/주간 + `N resets` |
| **C. OpenCode Go 구독자** | rolling/weekly/monthly 3중 쿼터 | 3윈도우 동시 표시 |
| **D. 멀티툴 사용자** | Claude + Codex + Go를 상황 따라 섞어 씀. 어느 게 임박했는지 모름 | 4-provider 단일 뷰, 최저 잔여 강조 |
| (부차) **E. Antigravity 사용자** | Google의 소비자용 quota UI가 빈약 | opt-in CLI 리포트 파싱 (자격증명 접근 없음) |

**핵심 페르소나**: 하루 6시간 이상 AI CLI로 코딩하고, 월 $100~$200를 이미 쓰고 있고, 한도 리셋 시각을
머릿속으로 계산하고 있는 사람. 이 사람에게 "남은 62%"는 기능이 아니라 **작업 계획 도구**다.

## 3. 그들이 지금 하는 일 (JTBD)

1. "지금 이 작업을 밀어붙여도 되는가, 아니면 리셋을 기다려야 하는가?"
2. "오늘 남은 시간에 몇 번 더 돌릴 수 있는가?"
3. "Claude가 20% 남았는데 Codex는 80%다 — 이번 작업은 어디로 보낼까?"
4. "내가 산 플랜을 실제로 다 쓰고 있는가?"

현재 대체 수단: CLI를 다시 쳐서 quota 화면 열기, 브라우저 대시보드 열기, 머릿속 암산, 또는 **아무것도 안 함**(=한도에 부딪힌 뒤 알게 됨).

## 4. 왜 Fillline인가 (메시지 기둥 3개)

### 기둥 1 — 남은 % 우선
- 증거: 메뉴바 라벨이 `C 62% · O 40% · G 24%`, 카드의 지배적 요소는 큰 잔여 숫자, 사용 %는 작은 보조 텍스트.
- 반대 진영: "오늘 얼마나 썼나" 대시보드(ccusage류), 비용 환산 중심 도구.

### 기둥 2 — 정직한 stale
- 증거: 갱신 실패 시 값은 그대로 두고 `stale · 4m ago · 3 failures — showing last known values.`라고 쓴다.
  **절대 0%로 표시하지 않는다.** 1회 실패는 조용히, 2회부터 이유를 말한다.
- 왜 중요한가: quota 도구의 최악의 버그는 "0%라고 거짓말"이다. 그러면 사용자는 멀쩡한 계정을 못 쓴다고 믿는다.

### 기둥 3 — 자격증명 비대칭을 숨기지 않음
- Claude Code만 OAuth 토큰을 **읽는다**(opt-in, 기본 off, 메모리만, refresh 안 함).
- Codex는 `app-server`/CLI를 실행해 출력만 읽고, Antigravity는 `agy`를 실행해 출력만 읽는다.
- OpenCode Go는 사용자 자신의 API 키를 쓴다.
- 토큰을 디스크에 복사하지 않고, 로그·크래시 리포트·이슈 템플릿에 남기지 않는다. 텔레메트리 없음.
- 증거: README "How it gets your numbers" 표 + `SECURITY.md` + 코드의 `Redacted` 래퍼 + 도메인 allowlist CI 가드.

## 5. 경쟁 지형 (2026-10-21 기준, 인용 전 재확인)

| 제품 | 강점 | Fillline과의 차이 |
|---|---|---|
| **Headroom** (`headroom.day`) | 상업용, Claude/Codex/Antigravity/Gemini/Grok/Cursor/Copilot 다수 provider, 5h·주간, 리셋 크레딧, 80/95% 알림 | 기능 상당 부분 겹침. Fillline은 **오픈소스(MIT)·0 의존성·4-provider 집중·stale 정직성**으로 승부. 기능 수로는 못 이기므로 "읽고 검증할 수 있는 코드"를 판다 |
| **CodexBar** (steipete, MIT) | Swift 6, provider별 ordered strategy pipeline, read-only keychain 정책 enum | 아키텍처 선례. Fillline은 **Claude+Go+Antigravity를 한 뷰에** 놓고 남은 % 중심 UX를 전면에 |
| **ccusage** | JSONL만 읽는 zero-credential, `--json` | 서버 진실이 아닌 로컬 모델. Fillline은 provider가 말하는 실제 quota를 읽음 |
| **Claude-Code-Usage-Monitor** | provenance/confidence 라벨, 원자적 상태 파일 | 단일 provider 중심. Fillline은 4-provider + 메뉴바 상주 |
| **Quotio / NOTCHYLIMIT / Tokenscope / ai-usage 등** | notch UI, 다양한 미터 | 대부분 단일/이중 provider이거나 로컬 추정. Fillline의 축은 "남은 % + 정직한 stale + 다중 provider" |

**경쟁 우위의 본질**: 기능 목록이 아니라 **신뢰**다. quota 숫자는 틀리면 즉시 신뢰를 잃는다.
그래서 Fillline은 (a) 출처 배지(`APP SERVER` vs 내부 HTTP), (b) stale 라벨, (c) 테스트로 고정된 파서,
(d) 자격증명 처리의 명시적 문서화를 제품 표면에 올린다.

## 6. 말하지 말아야 할 것 (신뢰 리스크)

- ❌ "공식 앱" / "Anthropic·OpenAI와 제휴" — 사실 아님. README에 상표 고지 있음.
- ❌ "ToS 100% 안전" — 비문서화 엔드포인트를 쓴다. "리스크를 문서화했고, 계정 제재 가능성을 고지한다"가 정확.
- ❌ "토큰을 절대 안 읽는다" — Claude 경로는 읽는다(opt-in, 메모리). **비대칭을 그대로 말한다.**
- ❌ "무조건 정확" — provider가 응답을 바꾸면 깨진다. 대신 "깨지면 stale로 정직하게 표시한다".
- ❌ 스크린샷 없는 "완성된 제품" — 현재 알파는 ad-hoc 서명이고 실제 창 스크린샷이 아직 없다(이슈 #6). 이건 먼저 해결한다.

## 7. 목표 지표 (v1 알파 기간)

| 지표 | 목표 | 측정 |
|---|---|---|
| GitHub stars | 100 (첫 30일) | repo |
| Release 다운로드 | 300 (universal zip+dmg) | `gh release view --json assets` |
| 이슈 리포트 | 최소 5 (provider 깨짐 포함) | Issues |
| 유지율 신호 | "매일 쓰는" 코멘트 3건 | Discussions |
| 배포 건강 | CI green 유지, v0.3.0까지 서명/노타라이즈 | Actions |

수익화는 v1 범위 밖이다(순수 MIT OSS). 후보: 서명된 notarized 빌드에 대한 GitHub Sponsors,
또는 팀 대시보드(v2) — 결정 전에는 README에 약속하지 않는다.
