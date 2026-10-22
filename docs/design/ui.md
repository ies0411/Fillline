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
no tabs, no charts, and no scrolling until the cards outgrow one screen (§2).

**Visual thesis:** a quiet instrument. Monochrome until something is actually wrong, then
one signal colour. System type, hairline structure, tabular numbers, nothing decorative
that is not also information.

## 2. Layout (340 × ~510–772 pt, content-sized up to a 708 pt card ceiling)

```
┌──────────────────────────────────────────────┐ 340
│ ◔ Fillline               checked 12s ago ↻ ⚙ │  header, 36
├──────────────────────────────────────────────┤
│ ┌ Claude Code            MAX          STALE ┐│  card, 12 radius
│ │ 98%  5-HOUR       resets in 2h 48m · 2% used│
│ │ ████████████████████████▏──────────         │  meter + 15% notch
│ │ 80%  WEEKLY         resets in 3d 2h · 20% used│
│ │ ██████████████████▏───────────────          │
│ │ ╱────────────────────────────────────────  │  trail, 20 pt (§12)
│ │ ─────────────────────────────────────────  │
│ │ ◷ Stale · 4m ago — showing last known values│
│ └────────────────────────────────────────────┘│
│ ┌ Codex … ┐                                   │
│ ┌ Go …    ┐                                   │
│ ┌ Antigravity, only if on ┐                   │
├──────────────────────────────────────────────┤
│ 🔒 Read-only · no telemetry            Quit  │  footer, 26
└──────────────────────────────────────────────┘
```

- Width is fixed at **340 pt** so the popover does not resize when a plan badge or a
  status word changes.
- Height is content-sized **up to a ceiling**. Measured from the shipping renders at 2×: a
  healthy **four-provider** popover is 738 pt (card stack 674 pt), the tallest four-provider
  state (one stale card, which adds a footer line) is 682 pt, first run ~510 pt. All of it sits
  under the ceiling, so a four-provider popover does not scroll and no scroll indicator ever
  appears. Antigravity is opt-in: a stock install is one card shorter than the diagram.
  The older, sparkline-free mock measured 646 pt for the same four cards; §12 added ~29 pt
  per card, so the numbers above are the ones to use.
- **Five providers or more scroll.** The card stack is the only part of the popover that
  grows with the provider count, so it is the only part that is a `ScrollView`; the header,
  both dividers and the footer are fixed chrome outside it. The stack is capped at
  `PopoverView.cardStackCeiling` = **708 pt**, which is what keeps the popover on a 900 pt
  display: six cards measure 922 pt of stack inside a 708 pt window, so the popover renders
  at **772 pt** instead of 986 pt, and the last cards are reached by scrolling (issue #15).
  Five cards are 847 pt of stack — already over the ceiling, so the same 772 pt popover with
  139 pt of travel; six have 214 pt. Measured for the four-, five- and six-provider cases with
  the shipping view hierarchy in a hosted `NSWindow`: `NSScrollView` content 674 / 847 / 922 pt
  against the 708 pt cap, and 0 pt of travel for the four-provider case.
  - **Why 708 and not 720.** The ceiling is a leftover-avoidance number, so it can move a
    little to land the cut somewhere sensible. At 720 the six-provider cut landed 9 pt *into*
    the fifth card's `65%` numeral — the tops of the digits stayed legible through the fade;
    at 708 it lands in the 14 pt of empty card between that card's title and its first
    numeral, so the visible top of the cut card contains no numerals at all. The shift is
    12 pt, inside the 16 pt the fade review allowed.
- The scroll indicator is an **overlay**, and the stack is pinned to the popover width
  rather than left flexible, so the indicator can never take width away from a card: it draws
  over the 12 pt gutter the cards already leave free. Pinning is what makes that true even if
  someone turns on legacy (space-taking) scroll bars in System Settings.
- **Edge fades are conditional.** The bottom edge fades **10 pt** while the stack fits — that
  value sits inside the list's own 10 pt bottom padding, so a fitted stack fades empty space
  and is pixel-for-pixel what it was before the scroll view existed (the four-provider renders
  are byte-identical). It grows to **28 pt** once the stack is taller than the ceiling: a
  20 pt headline numeral is ~15 pt tall, so a 10 pt fade would leave the top of a clipped
  numeral at ~80 % opacity — a sliced glyph, which reads as broken rather than as "more
  below"; at 28 pt the same numeral enters the fade at ~30 % and reaches zero before the clip.
  The overflow case also adds **18 pt** of bottom padding (the difference between the two
  fades), so scrolling to the end still leaves the last card outside the fade. The top edge
  stays at 10 pt: at rest the list starts 12 pt in, so nothing is under it, and a taller top
  fade would dim the first card's own top edge.
  - Fitted vs cut is **measured**, not inferred from the provider count: a preference carries
    the laid-out list height up to the popover, which compares it with the ceiling. Cards
    change height with state (a stale footer, a sign-in body), so "five providers" is not the
    same thing as "past the ceiling". The same measurement runs in the offscreen render path.
- Cards are 11 pt-radius panels with a 4.5% primary tint and a 1 pt hairline. No nested
  materials: the popover's own vibrancy is the background.
- The six-provider case is rendered for the docs as
  `docs/marketing/assets/app-popover-crowded-{light,dark}.png` (Claude Code, Codex, Go,
  Antigravity, Copilot, OpenRouter): four cards, then the fifth card's title dissolving at
  the 708 pt edge — the picture of "there is more, and it scrolls" rather than of a popover
  running off the display.

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
| **stale** | `ok` older than `max(180, interval + 120)` s | rows + `STALE` badge + "Stale · 4m ago — showing last known values." After 2+ failed refreshes the age gains the count: "Stale · 4m ago · 3 failures — showing last known values." (one failure is silent — a single bad poll is ordinary) | `~` prefix if ≤ 30 min old, otherwise omitted |
| **needs login** | 401, missing/expired credential | no rows: "Sign in to Claude Code", "Run the CLI once…", `claude` + copy; if last-good values exist: rows + footer + command | omitted |
| **not installed** | CLI/credential directory absent | "Codex CLI not found. Install it and sign in once; this card fills in on its own." | omitted |
| **not subscribed** | HTTP 403 (Go) | "This key has no Go plan." | omitted |
| **rate limited** | HTTP 429 | no rows: "Rate limited · next try in 2m"; with last-good: rows + footer "Rate limited · retry in 2m · values from 4m ago." | omitted |
| **unsupported** | endpoint not available for the account | "Not available for this account." | omitted |
| **error(code)** | 5xx, decoding, network, Keychain | "Couldn't read usage (http-500). It will retry automatically."; with last-good: rows + footer | omitted |
| **Claude opt-out** | `claudeOAuthReadEnabled == false` | "Local logs only" + explanation + "Turn on in Settings" | Claude omitted |
| **Antigravity off** | provider off — **the default** | card hidden; Settings lists it as opt-in | Antigravity omitted |
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
| Letters + numbers | `C 62% · O 40% · G 24% · A 88%` | default; predictable positions |
| Icons + numbers | `✦ 62% · ‹/› 40% · ⚡ 24% · ◌ 88%` | same information, no letters |
| Compact | `‹/› 40% · ⚡ 24%` | glyph + the **two lowest**; the safety valve when the bar is already crowded |
| Lowest provider only | `G 24%` | worst provider + its letter |

- Provider order is fixed (`Claude`, `Codex`, `Go`, `Antigravity`), not sorted by urgency,
  so positions stay learnable. Given up: if macOS truncates from the right, the last
  provider disappears first — with four labels that last one is Antigravity, which is also
  the one that is off by default.
- Four providers do not break the label at specimen width: letters + numbers measures
  ~198 pt with ~173 pt of slack before the clock, and the critical row (triangle + four
  numbers) ~197 pt. Where four really is too much is a real bar that already holds other
  items; compact degrades by intent — glyph + the **two lowest**, not the whole set. We
  still do not measure the real menu bar width.
- No data → gauge icon only (`◔`), never `0%`.
- Antigravity's mark (`◌`) is a ball held above a lift pad, drawn at the same stroke weight
  as the other provider glyphs so it still reads at 12 pt next to the system icons.
- Every provider mark must land in the same ink band at 10 pt (menu bar) and 12 pt (card),
  measured as the darkest pixel and the count of fully inked pixels in the 10 px box. The
  Codex mark (`<>`) was the outlier: at stroke 1.9 its arms were 0.8 px wide and it read
  127/255 with no solid pixel, next to 26/255 for the filled marks. It is now stroke 3 with
  **butt caps** — 45/255, 8 solid pixels, 15.3 % ink coverage, level with the bolt (26/255,
  8, 15.8 %). Round caps are what to avoid when re-tuning: each free end grows by half the
  stroke, which bridges the top and bottom gaps and turns `<>` into a closed ring at 12 pt.
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

Antigravity is not part of onboarding. It ships off, its card states `opt-in` in the
provenance line, and Settings is the only place it is turned on — no second consent screen,
no prompt on first run.

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
- The stale footer's count is spoken, not just drawn: "Stale for 4 minutes after 3 failed
  refreshes, showing last known values."
- Icon-only buttons have labels (refresh, settings, quit) and keep a focus ring
  (`GhostButtonStyle`, an app-owned style rather than `.borderless`: AppKit-composited
  styles are not rasterisable by `ImageRenderer`, so screenshots come out as
  placeholder art).
- Colour is redundant everywhere: words for state, numbers for thresholds, `LOW` for
  critical. Amber/red are restricted to non-text graphics.
- Body text uses `.secondary` on the popover material; tertiary is reserved for separators
  and decorative ticks.

## 12. Sparkline — the seven-day trail

Added for issue #7. Source: `SnapshotHistory` (`Sources/UsageCore/Storage`), drawn by
`Views/Sparkline.swift`, fed by `AppModel.sparklines`. On for every card; it has no settings
toggle.

### 12.1 What it is

One line per card, under the windows, plotting the **remaining** fraction of that card's
long-horizon window over the last seven days — oldest at the left edge, `now` at the right.
It answers the question the numbers cannot: *is this heading for the wall, and how fast?*
The big number says where you are; the line says which way it is going.

### 12.2 Placement and size

| Item | Value |
|---|---|
| Width | full card content width (292 pt of the 340 pt popover) |
| Height | 20 pt, including 2.5 pt of padding above and below the line |
| Position | directly under the window rows, above any status footer |
| Gap | 9 pt (the card's existing row spacing) |
| Card growth | ~29 pt per card; four providers ≈ +116 pt |

**Full width, not right-aligned.** Three reasons:

1. It continues a column. Number → label → meter → trail all share the same left and right
   edges, so the card reads as one instrument instead of a graphic parked in a corner.
2. A seven-day axis needs the width. A 90 pt stub would compress a week to ~3 pt per day and
   turn every slope into a staircase.
3. Right-aligning puts it under the countdown, not under the meter whose history it is, which
   is exactly the association the line exists to make.

It gets no divider, caption, background or extra padding beyond the table above. It is a
footnote to the numbers, not a second chart.

### 12.3 Quantities

- **Y — remaining, fixed to `0...1`.** Same domain as the meter, never auto-scaled: the top of
  the box is a full quota, the bottom is the wall, and the line's height means the same thing
  on every card. A floating `min...max` domain would draw nearly every healthy card as an
  identical full-height ramp and would turn a two-point wobble into a cliff.
- **X — time-true.** The 168 hours ending at `now`; each sample sits at its real position and
  is never stretched to fill the box. A card running for three days draws three days starting
  from the middle; a card with ten minutes of history draws a stub at the right edge and
  grows leftward. The empty left side is honest "no history yet", not missing data.
- **Series — the card's long-horizon window.** Weekly first, then model-scoped weekly,
  monthly, rolling, 5-hour, credits. The weekly window shares the axis's timescale and gives
  one readable slope; a 5-hour window would draw ~30 sawtooth cycles across the same axis and
  become the loudest thing on screen. Cards without a weekly window (Go's monthly,
  Antigravity's group, a Codex window of unknown duration) use the longest they have.
- **No caption names the window** — see §12.6 for why that trade-off is accepted.

### 12.4 Ink

- One line: **1.15 pt**, round caps and joins, `primary` at 45 % when the plotted window is
  healthy — the same ink as the meter fill, one step quieter.
- One area fill under the line at 10 % of that colour (≈4.5 % effective when healthy). With
  the fixed domain it is what carries the *level*: a card that has spent 20 points shows a
  visibly emptier box even though the stroke itself only moves 3–4 pt.
- **Warning (< 15 % remaining) and critical (< 5 %)** switch the line and the fill to the
  card's existing amber/red. No new hue is introduced, and the colour comes from the plotted
  window's newest sample, so a card can never show a grey line above an amber meter.
- Nothing else: no axis, gridlines, legend, markers, gradient or animation. Points arrive
  when the next poll lands, exactly like the meters.

### 12.5 Not enough data

| Samples in the window | Rendering |
|---|---|
| 0–1 | **nothing at all** — no element, and no space reserved in the card |
| 2–3 | the real polyline: one or two segments, at their true x positions |
| many | the same rule, more segments |

Never a flat line, never a placeholder box, never upsampled or interpolated points. A card
with two samples an hour apart draws a two-pixel stub, because that is the truthful drawing
of what is known; it lengthens by itself.

### 12.6 Accessibility

The sparkline is **its own accessibility element, not decoration**. The card's text states the
current remaining, the used percentage and the reset time, but it says nothing about direction
or rate — which is precisely what the line adds. Hiding it would withhold information from
VoiceOver users only. The label is a sentence:

> "Weekly remaining trend over the last 3 days 4 hours, down 12 points, now 80 %"

- Direction and distance are rounded to whole points; anything inside ±1 point reads "steady".
- The period is measured from the **oldest sample**, so a young series is described in minutes
  and never claims seven days of history it does not have.
- The window's own label is the only thing that identifies *which* series is drawn. That is
  the accepted cost of having no visible caption: adding one ("7d · weekly") would sit in the
  same visual band as the meter's own labels and start competing with them. VoiceOver gets the
  full sentence; sighted users read the line as the trail of the window above it.
- No hover state, no tooltip, no interaction.

### 12.7 Light and dark

Both appearances were rendered offscreen (`ImageRenderer`, the same approach the card mock was
checked with) at the real 292 pt width, in healthy, warning, critical, partial-history and
two-sample states. The healthy ink is `Color.primary` at a fixed alpha, so it inverts with the
appearance rather than being a hardcoded grey; the fill is the same colour at low alpha, so it
always stays *behind* the line. Amber and red are the system dynamic colours the meter already
uses. Two things the render changed: the plot gained 2.5 pt of vertical padding (without it a
healthy line hugged the box's top edge and read as a rule under the meter), and the fill and
stroke were lightened from 16 %/50 % to 10 %/45 % because a full-height low-alpha block was
competing with the meter bar.

### 12.8 Known limits

- `popover-mock.html` predates this section and still shows the four cards without sparklines.
  It stays frozen as the specimen for everything else; §12.2 carries the updated heights.
- Turning Claude's credential read off clears the card and its in-memory trail, but
  `SnapshotHistory` has no per-provider clear, so Claude samples already on disk stay in
  `history.json` until the seven-day retention prunes them.
- The menu bar shows no trend, and there is no setting to hide the sparkline.

## 13. What is not verified until Xcode

- `MenuBarExtra` label `.task { model.start() }` is assumed to run at launch. If it does
  not, the first poll would wait until the popover opens; the fix is a minimal app
  delegate or starting the loop from `App.init`.
- `SettingsLink` opening the Settings scene from a `.window`-style `MenuBarExtra`.
- True vibrancy/contrast of `.secondary` on the popover material, and macOS menu bar
  truncation behaviour.
- `@Bindable` bindings and `TimelineView` redraw cadence at runtime.
- The sparkline's `Canvas` inside a `.window` `MenuBarExtra`: stroke crispness of a 1.15 pt
  line on a non-Retina display, and whether the 10% area fill still reads against the
  popover's vibrancy rather than the solid background used for the offscreen check (§12.7).
- App bundle build, signing, and the Keychain prompt path (requires Xcode).
- The card stack's `ScrollView` and its edge fades (§2): the layout was measured in a hosted
  `NSWindow` — stack content 674 / 847 / 922 pt for four / five / six providers against the
  708 pt cap, 0 pt of travel for four and 139 / 214 pt for five and six — and scrolled to the
  end, where the last card lands inside the clip with its bottom edge still at full strength
  (the taller fade is measured to cover empty padding only). The fitted case is pixel-identical
  to the pre-scroll renders; the crowded render differs from them only inside the 28 pt fade
  band. What still needs a real popover is the *feel*: overlay indicator timing, wheel and
  trackpad inertia, and whether the fade reads on the popover material the way it does on the
  solid surface of a render. `ImageRenderer` cannot draw a `ScrollView` at all
  (AppKit-composited, like the `.borderless` button style §11 avoids), so the documentation
  renders swap it for a clipping container of the same size via `\.cardStackScrolls`; the
  renders show the ceiling, not the gesture.
- The one cut the conditional fade does not fix is the **top** edge while scrolling: it stays
  at 10 pt, so a card scrolled under it can still show the top of a numeral. Growing it would
  dim the first card at rest (the list only starts 12 pt in), so it is left alone until the
  app can tell "scrolled to the very top" from "at rest".

The HTML mock is the visual contract for the four-provider layout; any change to that layout
should be reflected there first. The sparkline (§12) is the one documented exception: the mock
is frozen and predates it, so §12.2 carries its measurements instead.
