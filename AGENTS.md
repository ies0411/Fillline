# Fillline — AI 코딩 CLI "남은 사용량" 메뉴바 앱

macOS 메뉴바에 Claude Code / OpenAI(Codex) / Go 의 **남은 사용량과 리셋 시각**을
상시 표시하는 오픈소스 앱. 목표는 "한도에 부딪히기 전에 보이게" 만드는 것.

- 라이선스: **MIT** (의존성은 MIT/Apache-2.0만 허용)
- 상태: 프리-알파 (설계 단계)
- 저장소 루트: 이 디렉터리 (`Fillline/`)

---

## 1. 제품 정의

| 항목 | 결정 |
|---|---|
| 형태 | 메뉴바 상주 앱 (`MenuBarExtra`) + 클릭 시 팝오버 상세 |
| 최소 OS | macOS 14 (Sonoma). macOS 26에서 개발/검증 |
| 배포 | GitHub Releases (universal, Developer ID 서명 + notarization) + Homebrew cask |
| 언어 | Swift 6 (strict concurrency), UI는 SwiftUI |
| 데이터 | 각 CLI가 이미 로컬에 저장한 자격증명/로그를 **읽기 전용**으로 재사용. 별도 로그인 플로우 없음(원칙) |
| 텔레메트리 | 없음. 네트워크는 provider 공식 엔드포인트 호출만 |

### 성공 기준 (v1)
1. 앱 실행 후 3초 내 첫 값 표시, 30초 주기 갱신.
2. Claude Code: 5시간 세션 + 주간(7일) 잔여 %와 리셋 카운트다운.
3. OpenAI: 세션/주간 잔여 %와 리셋.
4. Go: 확정된 소스에서 잔여 쿼터.
5. 네트워크/토큰 실패 시 **마지막 성공값 + stale 표시**, 절대 0%로 오표시하지 않음.
6. 토큰/이메일 등 민감정보는 로그·크래시 리포트·이슈 템플릿에 남기지 않음.

### Non-goals (v1)
- 토큰 사용량 기반 "비용 환산" 대시보드 (v2 후보)
- Windows/Linux
- 팀/조직 단위 집계
- 대화 내용·프롬프트 수집 또는 전송

---

## 2. Provider 범위 (핵심 리스크 영역)

> 세 provider 중 Claude/Codex는 **비공식(undocumented)** 엔드포인트에 의존한다. 계약이 아니라 관측이다.
> 따라서 모든 provider는 `primary → fallback → cached` 3단 폴백을 갖고,
> 파서는 fixture 기반 테스트로 고정한다. 상세 조사·실측 결과는 `docs/providers/` 참조.

**Phase 0 확정 (2026-10-21, 실측 기반. 상세: `docs/providers/`)**

| Provider | 1차 소스 | 폴백 | 비고 |
|---|---|---|---|
| **Claude Code** | `GET https://api.anthropic.com/api/oauth/usage` + Bearer + `anthropic-beta: oauth-2025-04-20` + **`User-Agent: claude-code/2.1.80`(필수)** | `~/.claude/projects/**/*.jsonl` 집계 (`estimated` 라벨) | Keychain `Claude Code-credentials` **읽기 전용, refresh 금지**(토큰 회전이 사용자 CLI 세션을 끊음). 최소 180초 간격, UA 없으면 429 폭풍 |
| **OpenAI Codex** | `codex app-server` → `account/rateLimits/read` (문서화된 JSON-RPC) | `GET https://chatgpt.com/backend-api/wham/usage` + `~/.codex/auth.json` 토큰 → 최후: `sessions/**/*.jsonl`의 `rate_limits` 블록 | refresh 금지. `auth.json` 없으면 `.notInstalled`. `reset_at`은 epoch **초** |
| **OpenCode Go** | `GET https://opencode.ai/zen/go/v1/usage` + Bearer `oc_sk_…` 키 | 마지막 성공 스냅샷 | `rolling`(5h) / `weekly`(7d) / `monthly` 3윈도우, `percent`=사용률 0–100. 403=구독 없음(`.notSubscribed`) |
| **Antigravity** (선택, 기본 off) | **`agy -p /usage --output-format json`** 서브프로세스 실행 후 출력 파싱 | 마지막 성공 스냅샷 | `gemini`/`3P` × `5h`/`weekly`. `remainingFraction`은 **남은 값(0–1)** → `used = 1 - remaining`. 자격증명·Google 엔드포인트 **절대 접근 금지**(ToS §6, 실제 계정 제재 사례). 5–10분 간격 |
| ~~Gemini CLI~~ | **제외(영구)** — 2026-06-18 개인/AI Pro/Ultra 자격 종료. 200 + `UNSUPPORTED_CLIENT` → 403 | — | `docs/providers/deferred.md` |

핵심 원칙(실측으로 확정됨):
- 단위가 **두 종류**다: Claude/Codex/OpenCode Go는 **0–100 "사용"** → 남은 % = `100 − used`.
  Antigravity는 **0–1 "남은 값"** → `used = 1 − remaining`. 파서를 공유하지 않는다.
- 리셋 시각 포맷도 **전부 다르다**: Claude `ISO8601 + 6자리 소수초`, Go `ISO8601 + 밀리초`, Codex `epoch 초`,
  Antigravity `ISO8601`(초 단위). provider별 파서 + 각각 테스트.
- **토큰 refresh는 어떤 provider에서도 하지 않는다.** 만료 시 `.needsLogin` + "CLI를 한 번 실행해 갱신" 안내.
- **자격증명을 읽는 provider는 Claude Code 하나뿐**이다. Codex/Antigravity는 CLI를 실행해 출력만 읽고,
  OpenCode Go는 자기 API 키를 쓴다. 이 비대칭을 README·UI에 그대로 드러낸다.
- Codex/Antigravity는 이 머신에 미설치 → `.notInstalled` 카드 UX가 v1 필수 요구사항.

### Provider 공통 규칙
- 자격증명은 **읽기만** 한다. **토큰 refresh는 하지 않는다** (Codex/Claude 모두 refresh token이 1회용이고
  회전시키면 원본 CLI 세션을 끊는다). 만료는 `.needsLogin`으로 표면화하고 사용자가 CLI를 실행해 갱신하게 한다.
- 호출 간격 하한 **60초/provider**, 지수 백오프 (60s → 2m → 5m → 15m, 최대 30분), `Retry-After` 존중.
- 429/401을 구분: 401은 "재로그인 필요" 상태로 UI 표시, 429는 조용히 백오프.
- 엔드포인트 URL·헤더·파싱 키는 **한 파일에 모아둔다** (`Sources/UsageCore/Providers/<Name>/Endpoints.swift`).

---

## 3. 아키텍처

```
Package.swift
  ├─ UsageCore (library, 테스트 가능, UI/AppKit 의존 없음)
  │    ├─ Models/        UsageSnapshot, LimitWindow, ProviderStatus
  │    ├─ Providers/     ClaudeCodeProvider, CodexProvider, GoProvider
  │    ├─ Auth/          KeychainReader, ClaudeCredentialStore, CodexAuthStore
  │    ├─ Net/           HTTPClient(protocol) + URLSession 구현, 재시도/백오프
  │    ├─ Schedule/      PollScheduler (actor, provider별 독립 주기)
  │    └─ Storage/       SnapshotCache (Application Support/ JSON)
  └─ UsageApp (executable, SwiftUI)
       ├─ App/           @main, MenuBarExtra, Settings scene
       ├─ Views/         MenuBarLabel, PopoverView, ProviderCard, Sparkline
       └─ Notifications/ UNUserNotificationCenter (80% / 95% / 리셋 임박)
```

원칙:
- **Core는 순수**: 네트워크/키체인/시계는 프로토콜로 주입 (`HTTPClient`, `Clock`, `CredentialStore`).
  → 모든 파싱·상태전이는 fixture만으로 테스트 가능해야 한다.
- 상태 전이는 `actor PollScheduler` 한 곳에서만. SwiftUI는 `@Observable` 뷰모델로 구독.
- provider 실패는 앱 전체 실패가 아니다. 카드 단위로 독립 상태(`ok / stale / needsLogin / unsupported`).
- UI 스레드에서 네트워크/키체인 접근 금지.

### 데이터 모델 (초안)
```swift
struct LimitWindow: Codable, Sendable {
    enum Kind: String, Codable { case session5h, weekly7d, monthly, credits }
    let kind: Kind
    let label: String          // "5-hour", "Weekly"
    let usedFraction: Double   // 0...1 (unknown이면 nil)
    let resetsAt: Date?
    let capturedAt: Date
}

struct UsageSnapshot: Codable, Sendable {
    let provider: ProviderID
    let plan: String?          // "Max", "Plus", ...
    let windows: [LimitWindow]
    let source: Source         // .api, .localLogs, .cache
    let status: ProviderStatus // .ok, .stale(age), .needsLogin, .rateLimited(retryAfter), .unsupported
}
```

### 표시 규칙
- 메뉴바 라벨: 기본 `C 62% · O 40%` (provider별 1개 숫자, 사용자가 어떤 윈도우를 쓸지 선택).
  공간 부족 시 아이콘 + 최솟값만. 5% 이하일 때만 색/강조 변경 (색맹 고려해 숫자도 유지).
- 팝오버: provider 카드 스택, 각 카드에 윈도우별 progress bar + `리셋까지 3h 12m`.
- "남은 %"가 기본 표기, 사용 %는 보조. (제품 목표가 remaining이므로)
- 새로고침 실패 시 `stale · 4분 전` 같은 명시 라벨. 절대 값을 지어내지 않는다.

---

## 4. 보안 / 프라이버시 (오픈소스 신뢰의 핵심)

- 토큰을 파일로 복사·저장하지 않는다. Keychain에서 읽어 메모리에서만 사용.
- 로깅: 토큰·쿠키·이메일·org id는 `Redacted` 래퍼를 거치게 하고, `os.Logger` privacy: `.private`.
- 디버그 덤프 기능은 기본 비활성 + 명시적 경고.
- 앱은 샌드박스 **비활성** (직접 배포). 이유: `~/.claude`, `~/.codex` 읽기와 기존 Keychain 항목 접근.
  → Mac App Store 배포는 포기한다. README에 명시.
- 네트워크 도메인 allowlist를 코드 상수로 고정하고, 그 외 요청은 만들지 않는다.
- 이슈/PR 템플릿에 "토큰·세션 로그 첨부 금지" 문구 고정.
- 각 provider의 ToS를 README에 링크하고 "비공식 엔드포인트 사용, 계정 제재 가능성" 리스크를 고지.

---

## 5. 개발 환경 / 빌드

현재 이 머신 상태 (2026-10-21 확인):
- macOS 26.0.1 (arm64), Swift 6.2.1 (CLT)
- **Xcode 미설치** (`xcodebuild` 사용 불가) → 앱 번들/서명/실행에는 Xcode 설치 필요.
  `UsageCore`는 `swift build`/`swift test`로 진행 가능 (UI 없이 개발/검증되는 구조를 유지하는 이유).
- 설치됨: `claude` (`/opt/homebrew/bin`), `opencode`. **미설치: `codex`** (`~/.codex` 없음)
  → Codex provider는 계약 기반 구현 + `.notInstalled` 카드로 검증. 실측은 Codex 설치 후.
- 실측 확인: Keychain `Claude Code-credentials` 읽기 성공(프롬프트 없음), `~/.claude/.credentials.json` 없음,
  OpenCode 키 `~/.config/opencode/.secrets/opencode-key` (`oc_sk_…`, 51자) 존재.

```bash
# 코어 개발 (Xcode 없이 가능)
swift build
./Scripts/test-local.sh      # ⚠️ `swift test`는 CLT에서 테스트를 "실행하지 않고" exit 0 한다

# 앱 번들 (Xcode 설치 후)
brew install xcodegen            # 프로젝트 파일은 커밋하지 않고 project.yml에서 생성
xcodegen generate
xcodebuild -scheme Fillline -configuration Debug build
open build/Fillline.app

# 릴리스
./Scripts/release.sh             # universal build → codesign → notarytool → dmg
```

⚠️ **CLT 함정 (2026-10-21 실측)**: Command Line Tools만 있는 환경에서 `swift test`는
테스트 번들을 링크까지 하고 **실행 없이 exit 0**으로 끝난다(번들이 Mach-O bundle이고 `xctest` 하네스가 없음).
"테스트 통과"를 이 출력으로 판단하면 안 된다. 따라서 로컬 게이트는 항상 `./Scripts/test-local.sh`
(임시 러너를 만들어 실제 테스트를 실행하고, 실행된 테스트가 0개면 실패 처리). CI는 Xcode 러너에서
평범한 `swift test`를 쓴다.

규칙:
- `.xcodeproj`는 **커밋하지 않는다** (`project.yml`이 소스 오브 트루스).
- `Package.resolved`는 커밋. 의존성 추가는 PR에서 근거 제시(가능하면 0 의존성 유지).
- 빌드 산출물/민감 경로는 `.gitignore`에 포함 (`build/`, `DerivedData/`, `*.xcuserstate`).

---

## 6. 테스트 전략

| 레벨 | 대상 | 방식 |
|---|---|---|
| Unit | 응답 파서, 로그 집계, 리셋 시각 계산, 백오프 | `swift-testing`, 고정 fixture (실제 응답에서 토큰/이메일 마스킹) |
| Contract | provider별 엔드포인트 형태 | fixture JSON 스키마 검증 + 옵션 필드 처리 |
| Integration | `PollScheduler` + mock HTTP | 실패→stale→복구 시나리오 |
| UI | 팝오버 상태별 렌더 | SwiftUI Preview + 스냅샷(선택) |

- 네트워크 테스트는 **실제 계정 호출 금지** (CI에서 토큰 없음). `HTTPClient` mock 필수.
- 파서 회귀는 "실제 응답 캡처 → 마스킹 → fixture 커밋" 절차로만 추가한다.
- **로컬 게이트 = `./Scripts/test-local.sh`.** `swift test`의 exit code를 신뢰하지 마라(CLT에서 미실행).
  테스트 개수가 0이면 실패로 취급한다. 프로세스를 띄우는 테스트(Codex app-server)는 반드시
  주입된 fake runner를 써야 하고 실제 `codex`를 스폰해서는 안 된다.

---

## 7. 오픈소스 운영

```
README.md            # 스크린샷, 설치, 프라이버시 설명, 한계 고지
LICENSE              # MIT
CONTRIBUTING.md      # 빌드 방법, 새 provider 추가 가이드, fixture 마스킹 규칙
CODE_OF_CONDUCT.md
.github/workflows/ci.yml        # swift test (macOS runner), swiftformat --lint
.github/ISSUE_TEMPLATE/{bug,provider_broken}.yml
SECURITY.md          # 취약점 제보 경로 (토큰 유출 대응 포함)
docs/providers/*.md  # provider별 데이터 소스·깨짐 이력 문서화
docs/status/data.json # 제품/진행 상황의 단일 소스 (숫자·상태를 여기서만 고친다)
docs/status/index.html # `./Scripts/status.sh --open`으로 생성되는 대시보드 (커밋 대상)
```

- PR 규칙: 1 PR = 1 관심사, provider 파서 변경 시 fixture 동봉, 사용자 노출 문자열은 리뷰 대상.
- 릴리스: semver. provider API 깨짐 수정은 patch.
- 커밋: Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
- 사용자 요청 없는 `git push`/`git commit` 금지.

### 7.1 진행 상황 대시보드 (사용자 상시 요청)

- 사용자는 **주기적인 진행/제품 리포트**를 원한다. 갱신은 `./Scripts/status.sh --open`.
- **숫자와 상태는 `docs/status/data.json`에서만 고친다.** HTML을 직접 편집하지 않는다(생성물).
- 갱신 시점: (1) 마일스톤 완료, (2) 커밋/푸시 후, (3) provider 상태 변화(실측/중단/제외),
  (4) 블로커 발생·해소. 최소한 Phase 전환 때는 반드시.
- `data.json`은 **사실만** 담는다. 확인하지 않은 값은 `"미확인"`으로 쓰고, 추정을 사실처럼 쓰지 않는다.
- 대시보드는 공개 문서다: 토큰·이메일·계정 ID·내부 경로(`/Users/...`)를 넣지 않는다.

---

## 8. 로드맵

**Phase 0 — 검증 스파이크 — ✅ 대부분 완료 (2026-10-21)**
- [x] Claude Code 실측 캡처 (HTTP 200, 5h 2% / weekly 20% / scoped Fable 윈도우 확인) → `docs/providers/claude-code.md`
- [x] OpenCode Go 실측 캡처 (HTTP 200, rolling 0% / weekly 59% / monthly 74%) → `docs/providers/opencode-go.md`
- [x] Codex: 계약 문서화 (`docs/providers/codex.md`) — **CLI 미설치로 실측 보류**
- [x] Go 소스 확정 = OpenCode Go. Gemini CLI 제외 근거 정리 → `docs/providers/deferred.md`
- [x] Keychain `Claude Code-credentials` 접근이 프롬프트 없이 동작 (기존 `security` 신뢰 항목 덕분).
      단, **ad-hoc 서명 빌드는 매번 재프롬프트** → 배포는 Developer ID 고정 서명 필수.
- [ ] Codex CLI 설치 후 `wham/usage` 실측 1회 (Phase 1 초입)

**Phase 1 — MVP (3~5일)**
- `UsageCore` 3-provider + 캐시 + 백오프 (스캐폴드 완료). `swift test` 그린 유지.
- `MenuBarExtra` 라벨/팝오버, 수동 새로고침, 설정(주기, 표시 윈도우), `.notInstalled`/`.needsLogin` 카드.
- Claude OAuth 읽기 토글(기본 off, 정책 고지 1스크린).

**Phase 2 — 신뢰성/UX**
- Codex app-server RPC 전략 추가(문서화된 경로 우선), 알림(80/95%), stale 표시 정교화,
  첫 실행 온보딩, 스냅샷 히스토리 축적(스파크라인 데이터).

**Phase 3 — 배포**
- Developer ID 서명/노타라이즈, DMG, Homebrew cask, README 스크린샷, GitHub Actions 릴리스.

**Phase 4 (선택)** — Antigravity provider, 비용 환산 뷰.

---

## 9. 에이전트 작업 규칙 (이 저장소)

- **UI/디자인 결정은 designer, 대량 기계적 수정은 fixer, 조사는 explorer**에게 위임한다.
  단, 파일 소유권이 겹치는 레인을 동시에 쓰지 않는다.
- provider 추가/수정 시 반드시: (1) fixture, (2) 폴백 경로, (3) stale 처리 테스트를 함께 낸다.
- "추정값"을 실제값처럼 표시하는 변경은 금지. 불확실하면 `estimated: true` + UI 라벨.
- 비밀정보 스캔: 커밋 전 `git diff`에서 `sk-`, `Bearer `, 이메일 패턴을 눈으로 확인.
- 이 문서(§1~§8)를 바꾸는 변경은 코드 변경과 분리된 PR로.

---

## 10. 열린 결정 (TBD)

| # | 질문 | 현재 기조 |
|---|---|---|
| 1 | ~~"Go"의 정체~~ | **확정: OpenCode Go.** Gemini CLI는 정책상 제외 (§2) |
| 2 | 알림 기본값 (80/95% vs 리셋 임박만) | v1은 둘 다, 기본 off에서 시작 검토 |
| 3 | 과거 사용량 스파크라인 포함 여부 | v2. 단, 캐시에 스냅샷 히스토리는 v1부터 축적 |
| 4 | anthropic 429 대응 | UA 필수 + 180초 TTL + 지수 백오프. 로컬 로그 폴백은 `estimated` 라벨로만 |
| 5 | 앱 이름/번들 ID | 임시 `Fillline` / `dev.ies0411.fillline`. **상표 리스크로 "Claude"/"Codex"/"OpenCode"를 제품명에 쓰지 않는다** |
| 6 | Claude를 statusLine 훅(문서화 경로)으로 전환할지 | v1.x 후보. `~/.claude/settings.json` 수정이 필요해 명시 동의 필요 |
| 7 | Codex 실측 검증 시점 | Phase 1 초입 (CLI 설치 후) |
| 8 | `Source`가 전략을 구분하지 못함 (Codex app-server vs 내부 HTTP 모두 `.api`) | `Source.appServer` 추가 검토 — UI가 "문서화된 경로"인지 표시할 수 있어야 함. 모델 변경이라 UI 레인 종료 후 |
| 9 | `reset credits`가 plan 문자열에 붙어 있음 | `UsageSnapshot`에 전용 필드 추가 (UI에서 배지로 표시) |

---

## 11. 참고 구현 (경쟁/선례 조사)

- `ArrivaRUS/claude-codex-limits` — 메뉴바, Keychain `Claude Code-credentials` 재사용, `GET /api/oauth/usage`
- `claudget` — 크로스플랫폼, `~/.claude` 로컬 집계 + usage 엔드포인트, stale 표시 UX
- `usage-cli` — 메뉴바/트레이, 로컬 로그 기반 + Antigravity 공식 쿼터 엔드포인트
- `ryoppippi/ccusage` — JSON 출력 CLI (fixture/스키마 참고)
- `anthropics/claude-code` 이슈 #30930 / #31021 — usage API 429 이력 (백오프·토큰 refresh 관련)

차별점: **남은 % 중심 표기 + stale를 정직하게 표시 + 세 provider 단일 뷰 + 0 의존성/작은 번들**.

### 11.1 Phase 0 조사에서 얻은 참고 (2026-10-21)

- **`steipete/CodexBar`** (Swift 6, macOS 14+, MIT) — 가장 참고할 만한 아키텍처. provider별
  *ordered strategy pipeline*(`oauth → cli → web-cookies → api-token → local-probe`) + `availability`/`shouldFallback`,
  Keychain read-only allowlist, provider 토큰 **절대 쓰지 않음**, Keychain 프롬프트 정책 enum
  (`Never`/`Only on user action`/`Always`), "credential changed → Refresh" 복구 UX.
- **`Maciek-roboblog/Claude-Code-Usage-Monitor`** — provenance 라벨링의 선례: 모든 숫자에
  `source.kind` + `local_estimate`/official 구분 + `confidence`. 원자적 상태 파일 쓰기(temp→rename).
- **`ryoppippi/ccusage`** — 자격증명을 **전혀** 만지지 않는 zero-secret 패턴 (JSONL only) + `--json` 출력.
  단, 5시간 "block"은 로컬 모델이지 서버 진실이 아님 → official로 표기 금지.
- 공식 문서: Claude Code `statusLine` stdin의 `rate_limits.*` (유일하게 **문서화된** Claude 소스),
  Codex `app-server`의 `account/rateLimits/read`, Claude Code "Authentication and credential use" 절.
- 공통 교훈: "freshest credential wins"(stale 파일이 신선한 Keychain을 가리면 429/무한 로그인 루프),
  provider 단위 실패 격리, last-good + age 표기.
