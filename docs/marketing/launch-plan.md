# Fillline — 런치 계획

> 타깃: **v0.3.0 (서명·노타라이즈) 직후 첫 공개 런치**. 알파(ad-hoc 서명)는 조용히 배포하고
> 광고하지 않는다 — 첫인상이 "서명 안 된 앱"이면 안 된다.
> 각 플랫폼의 자기홍보 규칙은 **게시 직전에 직접 확인**한다(이 문서는 규칙 원문이 아니라 체크리스트다).

## 0. 런치 전제 (게이트)

런치를 켜려면 아래가 모두 참이어야 한다.

- [ ] **Developer ID 서명 + 노타라이즈 완료**, `spctl -a -vvv` 통과 (이슈 #5)
- [ ] DMG + universal zip이 GitHub Release에 첨부되고 `SHA-256` 표기
- [ ] **실제 앱 창 스크린샷 2장 이상** (라이트/다크, 이슈 #6) — 목업 이미지는 스크린샷으로 쓰지 않는다
- [ ] `brew install --cask fillline` 동작 (탭 또는 공식 cask 제출)
- [ ] README 최상단 3초 안에 "무엇/왜/설치"가 보임
- [ ] 이슈 템플릿의 "토큰 첨부 금지" 문구 유지, `SECURITY.md` 유효
- [ ] CI green, 테스트 수 명시(README 배지)
- [ ] 알려진 한계 섹션이 최신(비문서화 엔드포인트, 계정 제재 가능성)

## 1. 자산 체크리스트

| 자산 | 위치 | 상태 |
|---|---|---|
| 앱 아이콘 (16~1024, .icns) | `Resources/AppIcon.icns` | 제작 중 |
| OG/소셜 카드 1280×640 | `docs/marketing/assets/og-image.png` | 제작 중 |
| 스크린샷: 팝오버 라이트/다크 | `docs/marketing/assets/shot-*.png` | **대기** (#6) |
| 스크린샷: 메뉴바 확대 컷 | 위와 동일 | **대기** |
| GIF: 12초 (메뉴바 → 팝오버 → 리셋 카운트다운) | `docs/marketing/assets/demo.gif` | 대기 |
| README 히어로(문장 + 이미지 1장) | `README.md` | 카피 준비됨 |
| 릴리스 노트(사람이 읽는 형태) | GitHub Release | `.github/release.yml` 라벨 기반 자동 + 수동 인트로 |
| 상태 대시보드 공개 URL | GitHub Pages | 워크플로 추가 중 |

**스크린샷 촬영 규칙**: 실제 계정 값이 보이면 안 된다 → 데모/익명 상태로 촬영하거나 숫자를 마스킹.
창 크기는 실제(약 340 pt 폭) 그대로, 배경은 바탕화면 대신 단색/블러.

## 2. 타임라인

### T-14 ~ T-7: 준비
- 서명/노타라이즈 파이프라인 완료, v0.3.0 태그.
- 스크린샷·GIF 제작, README 히어로 교체, OG 카드 업로드(수동: Settings → Social preview).
- Homebrew cask 준비: `Casks/fillline.rb` (url/sha256/`app "Fillline.app"`, `uninstall quit:`), 탭 저장소 만들고 `brew install --cask ies0411/tap/fillline` 검증.
- `awesome-macos-menu-bar` 류 리스트에 PR 초안 작성(각 리스트의 기여 규칙 확인).
- Discussions 카테고리(Announcements/Ideas/Q&A) 정리, 첫 글 "Roadmap to v1" 게시.

### T-3: 소프트 닫기
- 지인 5~10명에게 조용히 배포, 설치 실패·첫 실행 마찰 수집. **버그만 고친다.**
- 텔레메트리가 없으므로 "설치했는지"는 물어봐야 안다 — 짧은 피드백 폼 대신 Discussions 댓글 유도.

### T-0: 공개 (화~목, 09:00–11:00 KST = 前日 20:00–22:00 ET)
순서와 이유:
1. **Show HN** (`Show HN: Fillline – see how much AI coding quota you have left`) — 기술 청중이 첫 30분 반응을 만든다. 본문에 아키텍처·비공식 엔드포인트·프라이버시를 명시(§copy.md).
2. 2시간 뒤 **r/macapps** + **r/ClaudeAI**(자기홍보 규칙 확인, 필요 시 모더레이터 사전 허가).
3. 같은 날 **X**: 12초 GIF + 한 문단 + 릴리스 링크. 고정 트윗.
4. **Product Hunt**는 별도 날짜로 분리(주중, 00:01 PT). HN과 겹치면 관심이 분산된다.

### T+1 ~ T+14: 흡수
- 이슈 응답 SLA: 24시간 내 첫 응답, provider 깨짐은 72시간 내 패치 릴리스.
- "왜 0%로 안 보여주나 / stale이 뭐냐" 질문이 반복되면 README 상단으로 승격.
- stars/다운로드/이슈 수를 `docs/status/data.json`에 기록(공개 대시보드).

## 3. 채널별 카피 규칙

| 채널 | 길이/형식 | 금지 |
|---|---|---|
| Show HN | 제목 80자 이내, 본문 200~400단어, 첫 문단에 "무엇/왜" | 마케팅 형용사, 별점 요청 |
| Reddit | 제목에 제품명+한 줄 가치, 본문에 **한계 먼저** | 링크만 던지기, 다중 서브레딧 동시 도배 |
| X | 1트윗 = 1주장 + GIF, 스레드는 4~6개 | 스레드에 링크 5개 |
| Product Hunt | tagline 60자, description 260자, 첫 댓글에 기술 배경 | 얼리버드 쿠폰(무료 OSS라 무의미) |
| Homebrew | cask 이름·설명은 사실만 | "공식" 표현 |

## 4. 반박 대응 (미리 준비)

| 예상 반박 | 답변 요지 |
|---|---|
| "비공식 엔드포인트는 ToS 위반 아닌가?" | 맞는 리스크다. README에 명시했고, Claude는 opt-in·메모리 전용이며, Codex는 **문서화된** app-server 경로를 우선한다. 계정 제재 가능성도 고지. 끄고 켤 수 있다. |
| "토큰을 훔쳐가는 것 아니냐" | 코드가 MIT이고 0 의존성이다. 토큰은 디스크에 쓰지 않고, 로그·크래시 리포트·이슈 템플릿에 남기지 않으며, 도메인 allowlist를 CI가 강제한다. 그래도 믿기 어려우면 `UsageCore`만 읽어보라. |
| "왜 0%가 아니라 stale인가" | quota 도구의 최악은 거짓 0%다. 실패하면 마지막 성공값 + 나이 + 연속 실패 횟수를 보여준다. |
| "Headroom 쓰면 되는데?" | 기능 수로는 그쪽이 많다. Fillline은 오픈소스·검증 가능·남은 % 중심·4-provider 단일 뷰다. |
| "메뉴바가 시끄럽다" | 라벨 스타일 3종(전체/글리프/최저만) + provider별 on/off. |
| "Windows/Linux는?" | v1 범위 밖. 코어(`UsageCore`)는 플랫폼 독립이라 기여 여지 있음. |

## 5. 검색/발견성 (이름이 아니라 설명으로 잡는다)

- GitHub description: `macOS 메뉴바에서 Claude Code · Codex · OpenCode Go · Antigravity 의 남은 사용량과 리셋 시각을 보여주는 앱. 남은 % 우선, stale은 정직하게. (Swift 6, MIT)`
- Topics(현재): `claude-code, codex, macos, menu-bar-app, opencode, quota, swiftui`
  추가 후보: `claude-usage, rate-limit, menu-bar, swift6, macos-app, ai-usage`
- README 첫 문단에 실제 검색어를 자연스럽게 포함: "Claude Code usage", "Codex rate limit", "OpenCode Go quota", "menu bar".
- 페이지: `https://ies0411.github.io/Fillline/` (상태 대시보드) — README에서 "Live project status"로 링크. 개발 과정이 투명하게 보이는 것 자체가 마케팅이다.

## 6. 측정

- GitHub: stars, forks, watchers, release asset downloads(`gh release view --json assets`), issue 응답 시간.
- 트래픽 유입은 GitHub Referrers로만 판단(외부 분석 도구 없음 — 제품 원칙과 일치).
- 성공 기준(30일): stars 100, 다운로드 300, 외부 이슈 5, "매일 씀" 신호 3.

## 7. 실패 시나리오

| 상황 | 대응 |
|---|---|
| HN 반응 없음 (< 10 points, 2시간) | 삭제하지 않는다. 2주 뒤 다른 앵글로 1회만 재시도(예: "stale 표시" 설계 이야기) |
| provider 엔드포인트가 런치 당일 깨짐 | 즉시 패치 릴리스 + 릴리스 노트에 원인 공개. `stale`이 정상 동작함을 보여주는 기회로 쓴다 |
| ToS 논쟁 확산 | 논쟁하지 않고 README의 리스크 섹션을 링크. 정책 변경 요청이 오면 기능을 내린다(제품 원칙) |
| 서명 실패로 설치 마찰 | `xattr -d com.apple.quarantine` 안내를 README 임시 섹션에 넣고, 서명을 최우선으로 고친다 |
