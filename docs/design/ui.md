# UI design — menu bar label & popover

Status: implemented in `Sources/UsageApp`, typechecked against the macOS 14 SDK, **not yet
built with Xcode**. Visual proof: [`popover-mock.html`](popover-mock.html) (open it in a
browser; it is the only rendering available until Xcode is installed).

## 1. What this UI is for

The product question is not "how much did I use?" but **"how much is left, and when does it
come back?"** Every layout decision below serves that sentence:

- the remaining percent is the biggest thing in a row;
- the meter empties toward the wall, like a fuel gauge;
- a stale value keeps its number and gains an honest age;
- a missing value is missing, never `0%`.

The app lives in the menu bar, so the popover is a **glance**, not a dashboard. One screen,
no tabs, no charts, no scrolling by default.

**Visual thesis:** a quiet instrument. Monochrome until something is actually wrong, then
one signal colour. System type, hairline structure, tabular numbers, nothing decorative
that is not also information.

## 2. Layout (340 × ~460–520 pt, content-sized)

```
┌──────────────────────────────────────────────┐ 340
│ ◔ Fillline               checked 12s ago ↻ ⚙ │  header, 36
├──────────────────────────────────────────────┤
│ ┌ Claude Code            MAX          STALE ┐│  card, 12 radius
│ │ 98%  5-HOUR       resets in 2h 48m · 2% used│
│ │ ████████████████████████▏──────────         │  meter + 15% notch
│ │ 80%  WEEKLY         resets in 3d 2h · 20% used│
│ │ ██████████████████▏───────────────          │
│ │ ─────────────────────────────────────────  │
│ │ ◷ Stale · 4m ago — showing last known values│
│ └────────────────────────────────────────────┘│
│ ┌ Codex … ┐                                   │
│ ┌ Go …    ┐                                   │
├──────────────────────────────────────────────┤
│ 🔒 Read-only · no telemetry            Quit  │  footer, 26
└──────────────────────────────────────────────┘
```

- Width is fixed at **340 pt** so the popover does not resize when a plan badge or a
  status word changes.
- Height is content-sized. A healthy three-provider popover is ~470 pt; a card with a
  long unavailable explanation can push it to ~560 pt. No `ScrollView` in v1 — with three
  providers and at most three windows each, the content always fits a 900 pt display.
- Cards are 11 pt-radius panels with a 4.5% primary tint and a 1 pt hairline. No nested
  materials: the popover's own vibrancy is the background.

## 3. Remaining-first rules

### 3.1 The meter fills with remaining

A full bar means a full quota; an empty bar means the wall. This is the **opposite** of the
common "usage bar" and is deliberate:

1. The bar and the big number then read in the same direction. A 98% remaining row shows
   a 98% full bar; users never have to invert one to understand the other.
2. The product promise is remaining, so the most glanceable graphic encodes remaining.
3. The used percent still exists, as a 9.5 pt caption (`2% used`) after the countdown, for
   people who think in spend.

The **notch at 15%** is the warning threshold drawn into the track. When the remaining fill
shorter than the notch, the window is inside the warning zone. It is a physical cue that
works without colour.

### 3.2 Emphasis ladder

| Remaining | Number | Meter fill | Extra cue |
|---|---|---|---|
| ≥ 15% | primary, 20 pt semibold | graphite (`primary` 55%) | none |
| < 15% | primary | amber | none — the number and the notch are the signal |
| < 5% | primary | red | `LOW` pill with a red triangle and dark text |

Colour is never the only carrier: the number itself says `4%`, the pill says `LOW`, and the
VoiceOver label appends ", low". Text never uses amber (system orange on white is ~2:1);
amber and red are confined to the 4 pt meter and the decorative triangle.

### 3.3 Rounding

- **Remaining is floored** (`62.9% → 62%`). Overstating headroom is the one error this app
  must not make.
- A positive value below 1% renders **`<1%`**, not `0%`; `0%` means actually zero.
- **Used is rounded** and is only ever a caption.
- Thresholds are evaluated on the raw fraction, so 14.9% is a warning while the floored
  label reads `14%` — consistent with the threshold.

## 4. Type & spacing

System fonts only (constraint), but with a deliberate hierarchy:

| Role | Face | Size / weight |
|---|---|---|
| Window name | SF Pro | 12.5 semibold, tracking −0.1 |
| Big remaining value | SF Pro, `monospacedDigit` | 20 semibold |
| Window label | SF Pro, uppercase, tracking 0.7 | 9.5 semibold |
| Countdown / used | SF Pro, `monospacedDigit` | 9.5 regular |
| Card title (empty state) | SF Pro | 12 semibold |
| Body copy | SF Pro | 10–10.5 regular |
| Badges | SF Pro, uppercase, tracking 0.5–0.7 | 8.5–9 semibold |
| Footer | SF Pro | 9.5 regular |

Numbers use `.monospacedDigit()` everywhere so a countdown does not jitter. Window labels
are the only tracked uppercase text; it separates "metadata" from "values" without another
colour. Spacing: 8 pt between cards, 11–12 pt card padding, 8 pt between window rows,
4 pt between a row and its meter.

## 5. State matrix

Every row below has a dedicated rendering; none is a blank card. "Menu bar" describes the
value shown by the label, not the popover.

| State | Trigger | Card | Menu bar |
|---|---|---|---|
| **ok** | fresh snapshot | rows; no footer | value, no prefix |
| **stale** | `ok` older than `max(180, interval + 120)` s | rows + `STALE` badge + "Stale · 4m ago — showing last known values." | `~` prefix if ≤ 30 min old, otherwise omitted |
| **needs login** | 401, missing/expired credential | no rows: "Sign in to Claude Code", "Run the CLI once…", `claude` + copy; if last-good values exist: rows + footer + command | omitted |
| **not installed** | CLI/credential directory absent | "Codex CLI not found. Install it and sign in once; this card fills in on its own." | omitted |
| **not subscribed** | HTTP 403 (Go) | "This key has no Go plan." | omitted |
| **rate limited** | HTTP 429 | no rows: "Rate limited · next try in 2m"; with last-good: rows + footer "Rate limited · retry in 2m · values from 4m ago." | omitted |
| **unsupported** | endpoint not available for the account | "Not available for this account." | omitted |
| **error(code)** | 5xx, decoding, network, Keychain | "Couldn't read usage (http-500). It will retry automatically."; with last-good: rows + footer | omitted |
| **Claude opt-out** | `claudeOAuthReadEnabled == false` | "Local logs only" + explanation + "Turn on in Settings" | Claude omitted |
| **loading** | no snapshot yet | spinner + "Checking…" (never a skeleton number) | omitted |
| **first run** | `hasCompletedOnboarding == false` | full onboarding screen (below) | gauge icon only |
| **all hidden** | every provider disabled | "All cards are hidden" + Settings | gauge icon only |

Rationale for the menu bar being stricter than the popover: a failure status cannot be
expressed next to a number in a 12 pt label, so a stale-by-hours or failed value is left
out of the menu bar entirely. `~` is reserved for stale-but-recent values, where it is
both readable and honest. The popover always retains and explains the last known values.

## 6. Menu bar label

Styles (Settings → Menu bar → Label):

| Style | Example | Purpose |
|---|---|---|
| Letters + numbers | `C 62% · O 51% · G 41%` | default; predictable positions |
| Icons + numbers | `✦ 62% · ‹/› 51% · ⚡ 41%` | compact, language-neutral |
| Compact | `✦ 41%` | provider glyph + **lowest** remaining; for crowded bars |
| Lowest provider only | `G 41%` | worst provider + its letter |

- Provider order is fixed (`Claude`, `Codex`, `Go`), not sorted by urgency, so positions
  stay learnable. Given up: if macOS truncates from the right, the last card disappears
  first. Compact mode is the documented answer to a crowded bar; we do not measure the
  menu bar width.
- No data → gauge icon only (`◔`), never `0%`.
- Any value below 5% adds a small warning triangle before the numbers.
- `~` prefix marks a last-known value; the accessibility label says "approximately".
- Tooltips are not used in the menu bar (macOS does not reliably show them there).

## 7. Countdown & age

| Input | Rendered |
|---|---|
| 3 h 12 m ahead | `resets in 3h 12m` |
| 90 s | `resets in 1m` |
| 59 s | `resets in <1m` |
| past | `resetting…` |
| `resetsAt == nil` | `no reset time` |
| placeholder reset | `~ resets in 5h`, secondary (not tertiary: contrast) |
| estimated reset | `~ resets in 3h 12m`, normal colour + source badge when relevant |

Ages: `just now`, `4m ago`, `2h ago`, `3d ago`. Countdowns re-render through one
`TimelineView` every 30 s; the model refetches when a reset passes, and the row switches
to `resetting…` in the meantime rather than inventing a fresh value.

## 8. First run & consent

The first run replaces the popover contents with one screen (no modal, no tour):

1. **"See the wall before you hit it."** — one sentence of product intent.
2. Three privacy facts: reads existing logins, never refreshes tokens, no telemetry.
3. **Claude Code login** toggle, **off**, labelled "Off · local logs only."
   One sentence of trade-off: "Anthropic's policy doesn't allow apps to collect Claude.ai
   credentials, so this stays off unless you choose it." Link: README section
   `#unofficial-and-what-that-means`.
4. Primary action **Start monitoring** — always enabled, independent of the toggle.
   No pre-checked consent, no "recommended", no nagging. The CTA does not require the
   privacy-hostile option to be enabled.

Persistence: `UserDefaults` key **`claudeOAuthReadEnabled`** (default `false`), plus
`hasCompletedOnboarding`. Until onboarding is complete, no provider is polled and the menu
bar shows only its icon, so no Keychain or network read happens before the explanation is
seen. Turning the toggle off later also deletes the in-memory and cached Claude values.

The API does not yet implement the local-log estimate; the card says so plainly instead of
implying a local number exists. This is a deliberate honesty gap, not a placeholder value.

## 9. Settings

Single grouped form, 460 × 600:

- **Refresh** — 1 / 3 / 5 min (segmented), "Refresh now" + spinner, last check time.
  Claude's 180 s floor is stated, not hidden.
- **Menu bar** — which window drives the number (session-first, 5-hour/rolling, weekly,
  lowest of any window), label style, and a live preview of the actual label.
- **Providers** — one toggle each; off means no requests at all.
- **Claude Code** — the OAuth read toggle (disabled when the Claude card is off), policy
  sentence, README link, and "When off, the Claude card shows local logs only."
- **Startup** — "Launch at login" visible but disabled ("Coming in a later version").
- **About** — version, privacy/limits link, "Show welcome screen next time", trademark
  disclaimer.

## 10. Motion

One orchestrated moment: on popover open, cards rise 5 pt and fade in with a 45 ms stagger
(240 ms ease-out). Numbers change with `.numericText()`; meter fills animate over 350 ms.
`accessibilityReduceMotion` removes the stagger and the offset. Nothing else animates —
no pulsing badges, no looping decoration.

## 11. Accessibility

- Every window row is one accessibility element: "5-hour, 98% remaining, resets in
  2 hours 48 minutes, 2% used". Meters and decorative glyphs are hidden.
- The menu bar label announces every visible value plus "low" where relevant.
- Status badges carry the full phrase ("Sign-in required"), not just a dot.
- Icon-only buttons have labels (refresh, settings, quit) and keep a focus ring
  (`.borderless` rather than `.plain`).
- Colour is redundant everywhere: words for state, numbers for thresholds, `LOW` for
  critical. Amber/red are restricted to non-text graphics.
- Body text uses `.secondary` on the popover material; tertiary is reserved for separators
  and decorative ticks.

## 12. What is not verified until Xcode

- `MenuBarExtra` label `.task { model.start() }` is assumed to run at launch. If it does
  not, the first poll would wait until the popover opens; the fix is a minimal app
  delegate or starting the loop from `App.init`.
- `SettingsLink` opening the Settings scene from a `.window`-style `MenuBarExtra`.
- True vibrancy/contrast of `.secondary` on the popover material, and macOS menu bar
  truncation behaviour.
- `@Bindable` bindings and `TimelineView` redraw cadence at runtime.
- App bundle build, signing, and the Keychain prompt path (requires Xcode).

The HTML mock is the visual contract; any change to the SwiftUI layout should be reflected
there first.
