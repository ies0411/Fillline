#!/usr/bin/env python3
"""Generate the Fillline product status dashboard.

`docs/status/data.json` is the single source of truth for every number and
state word below; the only other input is the local git repository, read at
generation time (branch, commit count, dirty files, recent commits).

    python3 Scripts/status.py            # write docs/status/index.html
    python3 Scripts/status.py --open     # ...and open it in the browser
    python3 Scripts/status.py --out /tmp/status.html

Standard library only. The output is one self-contained HTML file: Tailwind
comes from the CDN, everything else is inline.
"""

from __future__ import annotations

import argparse
import html
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_FILE = ROOT / "docs" / "status" / "data.json"
DEFAULT_OUT = ROOT / "docs" / "status" / "index.html"
KST = timezone(timedelta(hours=9))

EMPTY = '<span class="text-faint">데이터 없음</span>'

TABS = [
    ("overview", "개요"),
    ("usage", "사용법"),
    ("providers", "Providers"),
    ("architecture", "아키텍처"),
    ("security", "보안 · 법적"),
    ("roadmap", "로드맵"),
    ("decisions", "리스크 · 결정"),
    ("log", "로그"),
]


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def esc(value):
    """Escape text for use in HTML text nodes and quoted attributes."""
    return html.escape("" if value is None else str(value), quote=True)


def inline(value):
    """Escape text, rendering `backticked` runs as inline code."""
    if value is None:
        return ""
    chunks = str(value).split("`")
    out = []
    for index, chunk in enumerate(chunks):
        if index % 2 == 1 and chunk.strip():
            out.append(f"<code>{esc(chunk)}</code>")
        else:
            out.append(esc(chunk))
    return "".join(out)


def field(obj, key):
    """Return a usable value for `key`, or None when it is absent/empty."""
    if not isinstance(obj, dict):
        return None
    value = obj.get(key)
    if value is None or value == "" or value == [] or value == {}:
        return None
    return value


def as_list(value):
    return value if isinstance(value, list) else []


def as_dict(value):
    return value if isinstance(value, dict) else {}


def text(value, mono=False, extra=""):
    """Render a data field as escaped text (inline code allowed)."""
    if value is None or value == "":
        return EMPTY
    body = inline(value)
    if mono:
        return f'<span class="font-mono text-[11px] leading-relaxed text-muted {extra}">{body}</span>'
    return f'<span class="{extra}">{body}</span>' if extra else body


def label(value, tone="muted"):
    tone_class = {
        "muted": "text-muted",
        "faint": "text-faint",
        "rust": "text-rust",
        "rose": "text-rose-700 dark:text-rose-300",
        "amber": "text-amber-800 dark:text-amber-300",
        "emerald": "text-emerald-800 dark:text-emerald-300",
    }.get(tone, "text-muted")
    return f'<span class="label-mono {tone_class}">{esc(value)}</span>'


def svg(body, cls="h-4 w-4"):
    return (
        f'<svg class="{cls}" viewBox="0 0 16 16" fill="none" stroke="currentColor" '
        'stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" '
        f'aria-hidden="true">{body}</svg>'
    )


_ICONS = {
    "gauge": '<path d="M2.4 12.6a6.1 6.1 0 1 1 11.2 0"/><path d="M8 12.6 10.8 7.4"/>'
             '<circle cx="8" cy="12.6" r=".85" fill="currentColor" stroke="none"/>',
    "check": '<path d="M3.2 8.4 6.3 11.5 12.8 4.6"/>',
    "alert": '<path d="M8 2.1 14.2 13H1.8L8 2.1Z"/><path d="M8 6.2v3.3"/>'
             '<circle cx="8" cy="11.4" r=".7" fill="currentColor" stroke="none"/>',
    "minus": '<path d="M3.5 8h9"/>',
    "lock": '<rect x="3.2" y="7" width="9.6" height="6.8" rx="1.4"/>'
            '<path d="M5.6 7V5.4a2.4 2.4 0 0 1 4.8 0V7"/>',
    "globe": '<circle cx="8" cy="8" r="5.7"/><path d="M2.6 8h10.8"/>'
             '<path d="M8 2.3c1.6 1.6 2.4 3.5 2.4 5.7S9.6 12.1 8 13.7C6.4 12.1 5.6 10.2 5.6 8S6.4 3.9 8 2.3Z"/>',
    "clock": '<circle cx="8" cy="8" r="5.7"/><path d="M8 4.4V8l2.4 1.5"/>',
    "flask": '<path d="M6.2 2.4h3.6"/><path d="M7 2.6v3.1L3.5 12a1.3 1.3 0 0 0 1.1 2h6.8a1.3 1.3 0 0 0 1.1-2L9 5.7V2.6"/>'
             '<path d="M5.1 9.6h5.8"/>',
    "shield": '<path d="M8 2.2 13 4v3.7c0 3-2 5.2-5 6.1-3-.9-5-3.1-5-6.1V4l5-1.8Z"/>',
    "terminal": '<rect x="2.2" y="3.2" width="11.6" height="9.6" rx="1.4"/>'
                '<path d="m5 6.4 2 1.6-2 1.6"/><path d="M8.6 9.8h2.6"/>',
    "branch": '<circle cx="4.4" cy="4.2" r="1.5"/><circle cx="4.4" cy="11.8" r="1.5"/>'
              '<circle cx="11.6" cy="6.6" r="1.5"/><path d="M4.4 5.7v4.6"/>'
              '<path d="M11.6 8.1c0 2-1.8 3.7-4.2 3.7H6"/>',
    "copy": '<rect x="5.6" y="5.6" width="7.6" height="7.6" rx="1.2"/>'
            '<path d="M10.4 5.6V4a1.2 1.2 0 0 0-1.2-1.2H4a1.2 1.2 0 0 0-1.2 1.2v5.2A1.2 1.2 0 0 0 4 10.4h1.6"/>',
    "sun": '<circle cx="8" cy="8" r="2.6"/><path d="M8 1.4v1.4M8 13.2v1.4M1.4 8h1.4M13.2 8h1.4'
           'M3.3 3.3l1 1M11.7 11.7l1 1M12.7 3.3l-1 1M4.3 11.7l-1 1"/>',
    "moon": '<path d="M12.8 9.4A5.6 5.6 0 0 1 6.6 3.2a5.7 5.7 0 1 0 6.2 6.2Z"/>',
}


def icon(name, cls="h-4 w-4"):
    return svg(_ICONS.get(name, ""), cls)


# --------------------------------------------------------------------------
# Live git facts
# --------------------------------------------------------------------------

def run_git(*args):
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def read_git():
    facts = {
        "branch": None,
        "commits": None,
        "dirty": None,
        "log": [],
        "upstream": None,
        "ahead": None,
        "behind": None,
    }
    branch = run_git("rev-parse", "--abbrev-ref", "HEAD")
    if branch:
        facts["branch"] = branch

    count = run_git("rev-list", "--count", "HEAD")
    if count and count.isdigit():
        facts["commits"] = int(count)

    status = run_git("status", "--porcelain")
    if status is not None:
        facts["dirty"] = len([line for line in status.splitlines() if line.strip()])

    log = run_git("log", "-15", "--date=short", "--pretty=format:%h%x1f%ad%x1f%s")
    if log:
        for line in log.splitlines():
            parts = line.split("\x1f", 2)
            if len(parts) == 3:
                facts["log"].append({"hash": parts[0], "date": parts[1], "subject": parts[2]})

    upstream = run_git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if upstream:
        facts["upstream"] = upstream
        counts = run_git("rev-list", "--left-right", "--count", f"{upstream}...HEAD")
        if counts:
            bits = counts.split()
            if len(bits) == 2 and bits[0].isdigit() and bits[1].isdigit():
                facts["behind"], facts["ahead"] = int(bits[0]), int(bits[1])
    return facts


# --------------------------------------------------------------------------
# Page shell: head, CSS, JS
# --------------------------------------------------------------------------

STYLE = """
:root {
  --paper: 242 239 232;
  --surface: 250 248 243;
  --surface-2: 234 230 221;
  --ink: 26 25 21;
  --muted: 90 86 78;
  --faint: 133 127 116;
  --rust: 166 67 42;
}
html.dark {
  --paper: 18 17 14;
  --surface: 30 29 24;
  --surface-2: 40 38 31;
  --ink: 237 232 221;
  --muted: 176 168 154;
  --faint: 142 135 122;
  --rust: 224 132 99;
}
html {
  -webkit-text-size-adjust: 100%;
  scroll-behavior: smooth;
  scroll-padding-top: 7.5rem;
}
html.dark { color-scheme: dark; }
html:not(.dark) { color-scheme: light; }
body {
  background-color: rgb(var(--paper));
  background-image: radial-gradient(rgb(var(--ink) / 0.055) 0.6px, transparent 0.6px);
  background-size: 18px 18px;
  background-attachment: fixed;
  color: rgb(var(--ink));
  font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Segoe UI", system-ui, sans-serif;
  font-size: 14px;
  line-height: 1.6;
  word-break: keep-all;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}
html.dark body {
  background-image: radial-gradient(rgb(var(--ink) / 0.07) 0.6px, transparent 0.6px);
}
::selection { background: rgb(var(--rust) / 0.18); }

code {
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
  font-size: 0.86em;
  background: rgb(var(--ink) / 0.055);
  border: 1px solid rgb(var(--ink) / 0.05);
  border-radius: 4px;
  padding: 0.06em 0.32em;
  overflow-wrap: anywhere;
}

.label-mono {
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
  font-size: 10px;
  line-height: 1.4;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  font-weight: 500;
}

/* Inline code inside the usage table must not break mid-token
   ("Claude Code-credentials" was wrapping after the hyphen). */
.usage-table code {
  white-space: nowrap;
}

.focus-ring:focus-visible {
  outline: 2px solid rgb(var(--rust) / 0.65);
  outline-offset: 3px;
}

.skip-link {
  position: fixed;
  left: 1rem;
  top: -4rem;
  z-index: 60;
  background: rgb(var(--ink));
  color: rgb(var(--paper));
  padding: 0.5rem 0.85rem;
  border-radius: 0.4rem;
  font-size: 12px;
  transition: top 0.15s ease;
}
.skip-link:focus { top: 1rem; }

.tab {
  display: inline-flex;
  align-items: baseline;
  gap: 0.45rem;
  padding: 0.85rem 0.7rem 0.72rem;
  border-bottom: 2px solid transparent;
  color: rgb(var(--muted));
  font-size: 13px;
  font-weight: 500;
  white-space: nowrap;
  transition: color 0.16s ease, border-color 0.16s ease;
}
.tab:hover { color: rgb(var(--ink)); }
.tab[aria-selected="true"] { color: rgb(var(--ink)); border-bottom-color: rgb(var(--rust)); }
.tab-index {
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
  font-size: 9px;
  letter-spacing: 0.1em;
  color: rgb(var(--faint));
  transform: translateY(-1px);
}
.tab[aria-selected="true"] .tab-index { color: rgb(var(--rust)); }

.no-scrollbar::-webkit-scrollbar { display: none; }
.no-scrollbar { -ms-overflow-style: none; scrollbar-width: none; }

.icon-sun { display: none; }
.dark .icon-sun { display: block; }
.dark .icon-moon { display: none; }

.timeline {
  position: relative;
  margin: 0;
  padding: 0 0 0 1.45rem;
  border-left: 1px solid rgb(var(--ink) / 0.12);
  list-style: none;
}
.timeline > li { position: relative; padding-bottom: 1.35rem; }
.timeline > li:last-child { padding-bottom: 0; }
.timeline > li::before {
  content: "";
  position: absolute;
  left: calc(-1.45rem - 4px);
  top: 0.45rem;
  width: 7px;
  height: 7px;
  border-radius: 999px;
  background: rgb(var(--rust));
  box-shadow: 0 0 0 3px rgb(var(--paper));
}
.timeline > li.timeline-ink::before { background: rgb(var(--ink) / 0.5); }

/* No entrance animations on purpose.
   A staggered fade (animation-fill-mode: both + delay) renders content at partial
   opacity on the first paint, in headless screenshots, in print, and on slow
   machines — the page looked broken rather than animated. Motion lives in the
   hover/focus transitions, which never hide content. */
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
}

@media print {
  :root, html.dark {
    --paper: 255 255 255;
    --surface: 255 255 255;
    --surface-2: 246 244 239;
    --ink: 17 16 14;
    --muted: 66 62 56;
    --faint: 96 90 82;
    --rust: 132 52 32;
  }
  html, body {
    background: #ffffff !important;
    background-image: none !important;
    color: #111111 !important;
    font-size: 10pt;
  }
  body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .sticky { position: static !important; }
  [data-tabbar], .no-print, .skip-link { display: none !important; }
  [role="tabpanel"][hidden] { display: block !important; }
  .tabpanel { break-before: page; }
  .tabpanel:first-of-type { break-before: auto; }
  article, .break-inside-avoid { break-inside: avoid; }
  .max-w-6xl { max-width: none !important; }
  .page-load, .stat-card, .panel-enter > * { animation: none !important; }
  .timeline > li::before { box-shadow: 0 0 0 3px #ffffff; }
}
"""

TAILWIND_CONFIG = """
tailwind.config = {
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        paper: 'rgb(var(--paper) / <alpha-value>)',
        surface: 'rgb(var(--surface) / <alpha-value>)',
        'surface-2': 'rgb(var(--surface-2) / <alpha-value>)',
        ink: 'rgb(var(--ink) / <alpha-value>)',
        muted: 'rgb(var(--muted) / <alpha-value>)',
        faint: 'rgb(var(--faint) / <alpha-value>)',
        rust: 'rgb(var(--rust) / <alpha-value>)'
      },
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', '"Apple SD Gothic Neo"', '"Segoe UI"', 'system-ui', 'sans-serif'],
        mono: ['ui-monospace', 'SFMono-Regular', '"SF Mono"', 'Menlo', 'monospace'],
        serif: ['ui-serif', '"New York"', '"Iowan Old Style"', 'Georgia', 'serif']
      }
    }
  }
};
"""

THEME_BOOT = """
(function () {
  try {
    var stored = localStorage.getItem('fillline.status.theme');
    var dark = stored ? stored === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches;
    if (dark) document.documentElement.classList.add('dark');
    document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
  } catch (err) {}
})();
"""

PAGE_JS = """
(function () {
  var root = document.documentElement;
  var KEY = 'fillline.status.theme';
  var toggle = document.getElementById('theme-toggle');
  var mq = window.matchMedia('(prefers-color-scheme: dark)');

  function storedTheme() {
    try { return localStorage.getItem(KEY); } catch (err) { return null; }
  }

  function applyTheme(theme, persist) {
    var dark = theme === 'dark';
    root.classList.toggle('dark', dark);
    root.style.colorScheme = dark ? 'dark' : 'light';
    if (toggle) {
      toggle.setAttribute('aria-pressed', dark ? 'true' : 'false');
      toggle.setAttribute('aria-label', dark ? '라이트 모드로 전환' : '다크 모드로 전환');
      toggle.title = dark ? '라이트 모드로 전환' : '다크 모드로 전환';
    }
    if (persist) {
      try { localStorage.setItem(KEY, dark ? 'dark' : 'light'); } catch (err) {}
    }
  }

  applyTheme(storedTheme() || (mq.matches ? 'dark' : 'light'), false);

  if (toggle) {
    toggle.addEventListener('click', function () {
      applyTheme(root.classList.contains('dark') ? 'light' : 'dark', true);
    });
  }

  if (mq.addEventListener) {
    mq.addEventListener('change', function (event) {
      if (!storedTheme()) applyTheme(event.matches ? 'dark' : 'light', false);
    });
  }

  var tablist = document.querySelector('[role="tablist"]');
  var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
  var panels = Array.prototype.slice.call(document.querySelectorAll('[role="tabpanel"]'));

  function tabFor(id) {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].getAttribute('data-tab') === id) return tabs[i];
    }
    return null;
  }

  function activate(id, options) {
    options = options || {};
    var target = tabFor(id);
    if (!target) return;
    tabs.forEach(function (tab) {
      var on = tab === target;
      tab.setAttribute('aria-selected', on ? 'true' : 'false');
      tab.tabIndex = on ? 0 : -1;
    });
    panels.forEach(function (panel) {
      var on = panel.id === 'panel-' + id;
      panel.hidden = !on;
      if (on) {
        panel.classList.remove('panel-enter');
        void panel.offsetWidth;
        panel.classList.add('panel-enter');
      }
    });
    if (options.focus) target.focus();
    if (options.hash !== false) {
      try { history.replaceState(null, '', '#' + id); }
      catch (err) { location.hash = id; }
    }
  }

  var initial = (location.hash || '').replace(/^#/, '');
  if (!tabFor(initial)) initial = tabs.length ? tabs[0].getAttribute('data-tab') : null;
  if (initial) activate(initial, { hash: false });

  tabs.forEach(function (tab) {
    tab.addEventListener('click', function () {
      activate(tab.getAttribute('data-tab'));
    });
  });

  if (tablist) {
    tablist.addEventListener('keydown', function (event) {
      var index = tabs.indexOf(document.activeElement);
      if (index === -1) return;
      var next = -1;
      if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      else if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = tabs.length - 1;
      if (next === -1) return;
      event.preventDefault();
      activate(tabs[next].getAttribute('data-tab'), { focus: true });
    });
  }

  window.addEventListener('hashchange', function () {
    var id = (location.hash || '').replace(/^#/, '');
    if (tabFor(id)) activate(id, { hash: false });
  });

  function legacyCopy(value, done) {
    var area = document.createElement('textarea');
    area.value = value;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    try { document.execCommand('copy'); done(); } catch (err) {}
    document.body.removeChild(area);
  }

  Array.prototype.forEach.call(document.querySelectorAll('[data-copy]'), function (button) {
    button.addEventListener('click', function () {
      var value = button.getAttribute('data-copy');
      var original = button.getAttribute('data-label') || button.textContent;
      var done = function () {
        button.textContent = '복사됨';
        window.setTimeout(function () { button.textContent = original; }, 1600);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(value).then(done, function () { legacyCopy(value, done); });
      } else {
        legacyCopy(value, done);
      }
    });
  });
})();
"""


# --------------------------------------------------------------------------
# Shared UI pieces
# --------------------------------------------------------------------------

def stat_cards(stats):
    if not stats:
        return f'<div class="rounded-xl border border-ink/10 bg-surface p-5 text-sm text-muted">{EMPTY}</div>'
    cards = []
    for index, stat in enumerate(stats, 1):
        item = as_dict(stat)
        cards.append(
            '<div class="stat-card rounded-xl border border-ink/10 bg-surface/80 p-4 transition-colors hover:border-ink/20 sm:p-5">'
            '<div class="flex items-baseline justify-between gap-2">'
            f'<div class="label-mono text-muted">{esc(field(item, "label") or "—")}</div>'
            f'<span class="font-mono text-[9px] tabular-nums text-faint">{index:02d}</span>'
            "</div>"
            f'<div class="mt-2.5 text-[1.75rem] font-semibold leading-none tracking-[-0.02em] tabular-nums">{esc(field(item, "value") or "—")}</div>'
            f'<div class="mt-2 text-[11.5px] leading-snug text-muted">{inline(field(item, "sub")) if field(item, "sub") else EMPTY}</div>'
            "</div>"
        )
    return '<div class="grid grid-cols-2 gap-3 md:grid-cols-4">' + "".join(cards) + "</div>"


def repo_strip(facts):
    branch = facts.get("branch")
    commits = facts.get("commits")
    dirty = facts.get("dirty")
    upstream = facts.get("upstream")

    parts = []
    parts.append(
        '<div class="flex flex-wrap items-center gap-x-5 gap-y-2.5 rounded-xl border border-ink/10 '
        'bg-surface/60 px-4 py-3 font-mono text-[11px] text-muted" aria-label="저장소 상태">'
    )
    parts.append(
        '<span class="inline-flex items-center gap-1.5">'
        f'<span class="text-faint">{icon("branch", "h-3.5 w-3.5")}</span>'
        f'<span class="text-ink/80">{esc(branch) if branch else "—"}</span></span>'
    )
    parts.append(
        '<span class="inline-flex items-center gap-1.5">커밋 '
        f'<span class="tabular-nums text-ink/80">{commits if commits is not None else "—"}</span></span>'
    )
    if dirty is None:
        dirty_html = '<span class="text-ink/80">—</span>'
    elif dirty == 0:
        dirty_html = (
            '<span class="inline-flex items-center gap-1.5">'
            '<span class="h-1.5 w-1.5 rounded-full bg-emerald-600 dark:bg-emerald-400"></span>'
            '<span class="text-ink/80">clean</span></span>'
        )
    else:
        dirty_html = (
            '<span class="inline-flex items-center gap-1.5">'
            '<span class="h-1.5 w-1.5 rounded-full bg-amber-500 dark:bg-amber-400"></span>'
            f'<span class="text-ink/80 tabular-nums">{dirty}</span> 미커밋</span>'
        )
    parts.append(f'<span class="inline-flex items-center gap-1.5">{dirty_html}</span>')

    if upstream:
        ahead = facts.get("ahead")
        behind = facts.get("behind")
        move = ""
        if ahead is not None and behind is not None:
            move = f' <span class="text-faint">↑{ahead} ↓{behind}</span>'
        parts.append(
            f'<span class="inline-flex items-center gap-1.5">업스트림 '
            f'<span class="text-ink/80">{esc(upstream)}</span>{move}</span>'
        )
    else:
        parts.append(
            '<span class="inline-flex items-center gap-1.5" title="원격 추적 브랜치가 없어 ahead/behind를 계산할 수 없습니다">'
            '업스트림 <span class="text-faint">없음</span></span>'
        )
    parts.append(
        '<span class="ml-auto inline-flex items-center gap-1.5 text-[10px] text-faint no-print">'
        f'{icon("terminal", "h-3 w-3")} 로컬 저장소 기준</span>'
    )
    parts.append("</div>")
    return "".join(parts)


def section_header(number, kicker, title, aside=""):
    aside_html = ""
    if aside:
        aside_html = (
            '<p class="max-w-xs text-[11.5px] leading-relaxed text-muted sm:text-right">'
            f"{aside}</p>"
        )
    return (
        '<header class="flex flex-wrap items-end justify-between gap-x-6 gap-y-2 border-b border-ink/10 pb-4">'
        "<div>"
        '<div class="flex items-center gap-2.5">'
        f'<span class="font-mono text-[10px] tracking-[0.18em] text-rust">{number}</span>'
        f'{label(kicker)}'
        "</div>"
        f'<h2 class="mt-1.5 text-[1.3rem] font-semibold tracking-[-0.02em]">{title}</h2>'
        "</div>"
        f"{aside_html}"
        "</header>"
    )


def panel(tab_id, number, kicker, title, aside, body, hidden=False):
    hidden_attr = " hidden" if hidden else ""
    return (
        f'<section role="tabpanel" id="panel-{tab_id}" aria-labelledby="tab-{tab_id}" tabindex="0"'
        f'{hidden_attr} class="tabpanel focus-ring pt-8 sm:pt-10">'
        f"{section_header(number, kicker, title, aside)}"
        f'<div class="mt-6">{body}</div>'
        "</section>"
    )


def note_row(value, icon_name="check", tone="text-ink/45"):
    return (
        '<li class="flex gap-2.5 text-[13px] leading-relaxed text-ink/85">'
        f'<span class="mt-[3px] shrink-0 {tone}">{icon(icon_name, "h-3.5 w-3.5")}</span>'
        f"<span>{inline(value)}</span></li>"
    )


# --------------------------------------------------------------------------
# Tab 01 — overview
# --------------------------------------------------------------------------

def render_overview(data, facts, number, hidden):
    meta = as_dict(data.get("meta"))
    summary = as_dict(data.get("summary"))
    blockers = as_list(data.get("blockers"))
    success = as_list(summary.get("success"))
    non_goals = as_list(summary.get("non_goals"))

    body = []
    what = field(summary, "what")
    why = field(summary, "why")
    body.append(
        '<p class="max-w-3xl text-pretty text-[17px] leading-[1.7] tracking-[-0.01em] text-ink/90 sm:text-[19px]">'
        f"{inline(what) if what else EMPTY}</p>"
    )
    if why:
        body.append(
            '<p class="mt-4 max-w-3xl border-l-2 border-rust/45 pl-4 text-[13.5px] leading-relaxed text-muted">'
            f"{inline(why)}</p>"
        )

    body.append('<div class="mt-8">')
    body.append(
        '<div class="flex items-baseline justify-between gap-3">'
        f'{label("Blockers · 지금 막힌 것")}'
        f'<span class="font-mono text-[10px] tabular-nums text-faint">{len(blockers):02d}</span>'
        "</div>"
    )
    if blockers:
        tones = [
            (
                "border-rose-700/25 bg-rose-500/[0.05] dark:border-rose-400/25 dark:bg-rose-400/[0.06]",
                "text-rose-700 dark:text-rose-300",
            ),
            (
                "border-amber-700/25 bg-amber-500/[0.06] dark:border-amber-300/25 dark:bg-amber-300/[0.06]",
                "text-amber-800 dark:text-amber-300",
            ),
        ]
        cards = []
        for index, blocker in enumerate(blockers):
            item = as_dict(blocker)
            border, accent = tones[index % len(tones)]
            title = field(item, "title")
            detail = field(item, "detail")
            action = field(item, "action")
            action_html = ""
            if action:
                action_html = (
                    '<p class="mt-2.5 flex gap-2.5 text-[12px] leading-relaxed">'
                    f'<span class="label-mono shrink-0 pt-[3px] text-faint">조치</span>'
                    f'<span class="text-ink/80">{inline(action)}</span></p>'
                )
            cards.append(
                f'<article class="break-inside-avoid rounded-lg border {border} p-4">'
                '<div class="flex items-center gap-2">'
                f'<span class="{accent}">{icon("alert", "h-3.5 w-3.5")}</span>'
                f'<span class="label-mono {accent}">Blocker {index + 1:02d}</span>'
                f'<span class="ml-auto label-mono text-faint">차단 요인</span>'
                "</div>"
                f'<h3 class="mt-2 text-[13.5px] font-semibold leading-snug">{esc(title) if title else "—"}</h3>'
                f'<p class="mt-1 text-[12.5px] leading-relaxed text-muted">{inline(detail) if detail else EMPTY}</p>'
                f"{action_html}"
                "</article>"
            )
        body.append('<div class="mt-3 grid gap-3 md:grid-cols-2">' + "".join(cards) + "</div>")
    else:
        body.append(f'<p class="mt-3 text-[13px] text-muted">{EMPTY}</p>')
    body.append("</div>")

    body.append('<div class="mt-8 grid gap-4 lg:grid-cols-[1.1fr_0.9fr]">')
    success_rows = []
    for index, item in enumerate(success, 1):
        success_rows.append(
            '<li class="flex gap-3 py-2.5 first:pt-0 last:pb-0">'
            f'<span class="mt-[2px] w-5 shrink-0 font-mono text-[10px] tabular-nums text-faint">{index:02d}</span>'
            f'<span class="text-[13px] leading-relaxed text-ink/85">{inline(item)}</span>'
            "</li>"
        )
    success_html = (
        "".join(success_rows)
        if success_rows
        else f'<li class="py-2.5 text-[13px] text-muted">{EMPTY}</li>'
    )
    body.append(
        '<section class="break-inside-avoid rounded-xl border border-ink/10 bg-surface/80 p-5">'
        '<div class="flex items-baseline justify-between gap-3">'
        f'<h3 class="text-[13.5px] font-semibold">성공 기준</h3>{label("v1", "rust")}'
        "</div>"
        f'<ol class="mt-3 divide-y divide-ink/10">{success_html}</ol>'
        "</section>"
    )

    non_goal_rows = []
    for item in non_goals:
        non_goal_rows.append(
            '<li class="flex gap-2.5 py-1.5">'
            f'<span class="mt-[4px] shrink-0 text-faint">{icon("minus", "h-3 w-3")}</span>'
            '<span class="text-[13px] leading-relaxed text-muted line-through decoration-ink/25">'
            f"{inline(item)}</span></li>"
        )
    non_goal_html = (
        "".join(non_goal_rows)
        if non_goal_rows
        else f'<li class="py-1.5 text-[13px] text-muted">{EMPTY}</li>'
    )
    body.append(
        '<section class="break-inside-avoid rounded-xl border border-dashed border-ink/15 p-5">'
        '<div class="flex items-baseline justify-between gap-3">'
        '<h3 class="text-[13.5px] font-semibold text-ink/80">Non-goals</h3>'
        f'{label("v1", "faint")}'
        "</div>"
        f'<ul class="mt-3">{non_goal_html}</ul>'
        "</section>"
    )
    body.append("</div>")

    aside = " · ".join(
        part for part in [
            f"v{esc(field(meta, 'version'))}" if field(meta, "version") else "",
            esc(field(meta, "status")) if field(meta, "status") else "",
        ] if part
    )
    return panel("overview", number, "Overview", "무엇을, 왜 만드는가", aside, "".join(body), hidden)


# --------------------------------------------------------------------------
# Tab 02 — usage (how to actually run and read the app)
# --------------------------------------------------------------------------

def render_usage(data, facts, number, hidden):
    usage = as_dict(data.get("usage"))
    intro = field(usage, "intro")
    quickstart = [as_dict(s) for s in as_list(usage.get("quickstart"))]
    enable = [as_dict(s) for s in as_list(usage.get("enable"))]
    reading = [as_dict(s) for s in as_list(usage.get("reading"))]
    trouble = [as_dict(s) for s in as_list(usage.get("troubleshooting"))]

    body = []
    if intro:
        body.append(
            '<p class="max-w-3xl text-pretty text-[15px] leading-[1.75] text-ink/85 sm:text-[16px]">'
            f"{inline(intro)}</p>"
        )

    # --- quickstart steps ------------------------------------------------
    steps = []
    for index, step in enumerate(quickstart, 1):
        code = field(step, "code")
        detail = field(step, "detail")
        code_html = (
            '<pre class="mt-2.5 overflow-x-auto rounded-lg bg-ink/[0.055] px-3 py-2 '
            'font-mono text-[11px] leading-relaxed text-ink/80"><code>'
            f"{esc(code)}</code></pre>"
            if code
            else ""
        )
        steps.append(
            '<li class="flex gap-3.5">'
            f'<span class="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full '
            f'border border-ink/15 bg-surface-2 font-mono text-[11px] tabular-nums text-muted">{index}</span>'
            '<div class="min-w-0 flex-1">'
            f'<p class="text-[13.5px] font-medium leading-relaxed">{inline(field(step, "title"))}</p>'
            + (
                f'<p class="mt-1 text-[12.5px] leading-relaxed text-muted">{inline(detail)}</p>'
                if detail
                else ""
            )
            + code_html
            + "</div></li>"
        )
    if steps:
        body.append(
            '<div class="mt-7 rounded-xl border border-ink/10 bg-surface/70 p-4 sm:p-5">'
            f'{label("설치와 첫 실행")}'
            '<ol class="mt-3.5 space-y-4">' + "".join(steps) + "</ol>"
            "</div>"
        )

    # --- provider enablement table ---------------------------------------
    if enable:
        rows = []
        for item in enable:
            default = field(item, "default") or "—"
            tone = "emerald" if default == "켜짐" else "faint"
            rows.append(
                '<tr class="align-top transition-colors hover:bg-ink/[0.025]">'
                f'<th scope="row" class="px-4 py-3 text-left text-[12.5px] font-medium">{inline(field(item, "provider"))}</th>'
                f'<td class="whitespace-nowrap px-4 py-3">{label(default, tone)}</td>'
                f'<td class="px-4 py-3 text-[12px] leading-relaxed text-muted">{inline(field(item, "how"))}</td>'
                f'<td class="px-4 py-3 text-[12px] leading-relaxed text-faint">{inline(field(item, "needs"))}</td>'
                "</tr>"
            )
        body.append(
            '<div class="mt-7">'
            f"{label('provider 켜기 — 설정은 앱 우클릭 메뉴 또는 팝오버 하단 설정에서')}"
            '<div class="mt-2.5 overflow-x-auto rounded-xl border border-ink/10 bg-surface/70">'
            '<table class="usage-table w-full min-w-[760px] border-collapse text-left">'
            '<thead><tr class="border-b border-ink/10">'
            f'<th class="px-4 py-2.5">{label("Provider")}</th>'
            f'<th class="px-4 py-2.5">{label("기본값")}</th>'
            f'<th class="px-4 py-2.5">{label("켜는 법")}</th>'
            f'<th class="px-4 py-2.5">{label("필요한 것")}</th>'
            "</tr></thead><tbody>"
            + "".join(rows)
            + "</tbody></table></div></div>"
        )

    # --- how to read it ---------------------------------------------------
    if reading:
        chips = []
        for item in reading:
            chips.append(
                '<div class="rounded-lg border border-ink/10 bg-surface-2/60 px-3 py-2.5">'
                f'<p class="font-mono text-[12px] leading-none text-ink/90">{esc(field(item, "label"))}</p>'
                f'<p class="mt-2 text-[11.5px] leading-relaxed text-muted">{inline(field(item, "meaning"))}</p>'
                "</div>"
            )
        body.append(
            '<div class="mt-7">'
            f"{label('메뉴바 읽는 법 — 남은 %가 먼저, 사용 %는 보조')}"
            '<div class="mt-2.5 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">'
            + "".join(chips)
            + "</div></div>"
        )

    # --- troubleshooting --------------------------------------------------
    if trouble:
        items = []
        for item in trouble:
            items.append(
                '<li class="flex gap-3 border-t border-ink/[0.07] py-3 first:border-t-0 first:pt-0 last:pb-0">'
                '<div class="min-w-0 flex-1">'
                f'<p class="text-[12.5px] font-medium leading-relaxed">{inline(field(item, "symptom"))}</p>'
                f'<p class="mt-1 text-[12px] leading-relaxed text-muted">{inline(field(item, "fix"))}</p>'
                "</div></li>"
            )
        body.append(
            '<div class="mt-7 rounded-xl border border-ink/10 bg-surface/70 p-4 sm:p-5">'
            f'{label("문제가 생겼을 때")}'
            '<ul class="mt-3">' + "".join(items) + "</ul>"
            "</div>"
        )

    aside = (
        '<div class="hidden text-right sm:block">'
        f'{label("alpha · 무료 · MIT", "rust")}'
        "</div>"
    )
    return panel("usage", number, "Getting started", "설치하고, 켜고, 읽는 법", aside, "".join(body), hidden)


# --------------------------------------------------------------------------
# Tab 03 — providers
# --------------------------------------------------------------------------

PROVIDER_TONES = {
    "ok": {
        "border": "border-l-emerald-600/70 dark:border-l-emerald-400/70",
        "dot": "bg-emerald-600 dark:bg-emerald-400",
        "text": "text-emerald-800 dark:text-emerald-300",
        "badge": "border-emerald-700/20 bg-emerald-500/[0.06] dark:border-emerald-400/25 dark:bg-emerald-400/[0.08]",
    },
    "warn": {
        "border": "border-l-amber-600/80 dark:border-l-amber-300/80",
        "dot": "bg-amber-500 dark:bg-amber-300",
        "text": "text-amber-800 dark:text-amber-300",
        "badge": "border-amber-700/20 bg-amber-500/[0.07] dark:border-amber-300/25 dark:bg-amber-300/[0.08]",
    },
}
PROVIDER_TONE_FALLBACK = {
    "border": "border-l-ink/25",
    "dot": "bg-ink/35",
    "text": "text-muted",
    "badge": "border-ink/15 bg-ink/[0.03]",
}


def provider_card(provider):
    item = as_dict(provider)
    tone_key = field(item, "tone")
    tone = PROVIDER_TONES.get(tone_key, PROVIDER_TONE_FALLBACK)
    tone_label = (str(tone_key).upper() if tone_key else "—")

    notes = as_list(item.get("notes"))
    notes_html = ""
    if notes:
        notes_html = (
            '<ul class="space-y-1.5 border-t border-ink/10 px-5 py-4">'
            + "".join(
                '<li class="flex gap-2.5 text-[12.5px] leading-relaxed text-muted">'
                '<span class="mt-[7px] h-1 w-1 shrink-0 rounded-full bg-ink/25"></span>'
                f"<span>{inline(note)}</span></li>"
                for note in notes
            )
            + "</ul>"
        )
    legal = field(item, "legal")
    legal_html = ""
    if legal:
        legal_html = (
            '<div class="border-t border-ink/10 px-5 py-4">'
            '<div class="rounded-md border border-ink/10 bg-paper/60 px-3.5 py-3">'
            f'{label("법적 메모", "rust")}'
            f'<p class="mt-1 text-[12px] leading-relaxed text-muted">{inline(legal)}</p>'
            "</div></div>"
        )

    verification = field(item, "verification")
    return (
        f'<article class="flex h-full flex-col break-inside-avoid overflow-hidden rounded-xl border border-y-ink/10 border-r-ink/10 border-l-2 {tone["border"]} bg-surface/80">'
        '<div class="flex flex-wrap items-start gap-3 px-5 py-4">'
        f'<span class="grid h-8 w-8 shrink-0 place-items-center rounded-md border border-ink/12 bg-surface-2/70 font-mono text-[12px] font-semibold text-ink/75">{esc(field(item, "short") or "·")}</span>'
        '<div class="min-w-0 flex-1">'
        '<div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">'
        f'<h3 class="text-[15px] font-semibold tracking-[-0.01em]">{esc(field(item, "name") or "—")}</h3>'
        f'<span class="inline-flex items-center gap-1.5 rounded-full border px-2 py-[1px] {tone["badge"]}">'
        f'<span class="h-1.5 w-1.5 rounded-full {tone["dot"]}"></span>'
        f'<span class="font-mono text-[9px] font-medium tracking-[0.12em] {tone["text"]}">{esc(tone_label)}</span>'
        "</span></div>"
        f'<p class="mt-0.5 text-[11.5px] leading-relaxed text-muted">{esc(verification) if verification else EMPTY}</p>'
        "</div></div>"
        '<dl class="grid grid-cols-1 gap-x-8 gap-y-3.5 border-t border-ink/10 px-5 py-4 sm:grid-cols-2">'
        f'<div><dt class="label-mono text-muted">윈도우</dt><dd class="mt-0.5 text-[12.5px] leading-relaxed text-ink/85">{text(field(item, "windows"))}</dd></div>'
        f'<div><dt class="label-mono text-muted">단위</dt><dd class="mt-0.5">{text(field(item, "units"), mono=True)}</dd></div>'
        f'<div class="sm:col-span-2"><dt class="label-mono text-muted">1차 소스</dt><dd class="mt-0.5">{text(field(item, "source"), mono=True)}</dd></div>'
        f'<div><dt class="label-mono text-muted">자격증명</dt><dd class="mt-0.5 text-[12.5px] leading-relaxed text-ink/85">{text(field(item, "credential"))}</dd></div>'
        f'<div><dt class="label-mono text-muted">리셋 포맷</dt><dd class="mt-0.5">{text(field(item, "reset_format"), mono=True)}</dd></div>'
        "</dl>"
        f"{notes_html}{legal_html}"
        "</article>"
    )


def render_providers(data, facts, number, hidden):
    providers = [as_dict(p) for p in as_list(data.get("providers"))]
    rejected = [as_dict(p) for p in as_list(data.get("rejected"))]
    measured = sum(
        1 for p in providers
        if isinstance(p.get("verification"), str) and p.get("verification").startswith("실측 완료")
    )

    body = []
    body.append(
        '<p class="max-w-3xl text-[13px] leading-relaxed text-muted">'
        "provider마다 데이터 소스와 자격증명 취급 방식이 다르다. 단위와 리셋 포맷도 공유하지 않는다 — "
        "파서를 하나로 합치면 한 provider의 응답 형식이 바뀔 때 나머지까지 함께 깨진다.</p>"
    )
    body.append('<div class="mt-6 grid items-stretch gap-3 lg:grid-cols-2">')
    body.append("".join(provider_card(p) for p in providers))
    body.append("</div>")

    body.append('<div class="mt-8">')
    body.append(f'{label("한눈에 비교")}')
    rows = []
    for p in providers:
        rows.append(
            '<tr class="align-top transition-colors hover:bg-ink/[0.025]">'
            '<th scope="row" class="whitespace-nowrap px-4 py-3 text-left text-[12.5px] font-medium">'
            f'<span class="mr-2 font-mono text-[10px] text-faint">{esc(field(p, "short") or "·")}</span>'
            f'{esc(field(p, "name") or "—")}</th>'
            f'<td class="px-4 py-3 font-mono text-[10.5px] leading-relaxed text-muted">{esc(field(p, "source") or "—")}</td>'
            f'<td class="px-4 py-3 text-[11.5px] leading-relaxed text-muted">{esc(field(p, "credential") or "—")}</td>'
            f'<td class="whitespace-nowrap px-4 py-3 font-mono text-[10.5px] leading-relaxed text-muted">{esc(field(p, "units") or "—")}</td>'
            f'<td class="whitespace-nowrap px-4 py-3 font-mono text-[10.5px] leading-relaxed text-muted">{esc(field(p, "reset_format") or "—")}</td>'
            "</tr>"
        )
    body.append(
        '<div class="mt-3 overflow-x-auto rounded-xl border border-ink/10">'
        '<table class="w-full min-w-[880px] border-collapse text-left">'
        '<thead><tr class="border-b border-ink/10 bg-surface-2/50">'
        '<th scope="col" class="label-mono px-4 py-2.5 text-muted">Provider</th>'
        '<th scope="col" class="label-mono px-4 py-2.5 text-muted">1차 소스</th>'
        '<th scope="col" class="label-mono px-4 py-2.5 text-muted">자격증명</th>'
        '<th scope="col" class="label-mono px-4 py-2.5 text-muted">단위</th>'
        '<th scope="col" class="label-mono px-4 py-2.5 text-muted">리셋 포맷</th>'
        "</tr></thead>"
        f'<tbody class="divide-y divide-ink/10 bg-surface/60">{"".join(rows)}</tbody>'
        "</table></div></div>"
    )

    body.append('<div class="mt-8">')
    body.append(f'{label("제외된 provider")}')
    if rejected:
        rejected_cards = []
        for r in rejected:
            rejected_cards.append(
                '<article class="break-inside-avoid rounded-xl border border-dashed border-ink/15 p-5">'
                '<div class="flex flex-wrap items-center gap-2.5">'
                f'<h3 class="text-[13.5px] font-semibold text-ink/75">{esc(field(r, "name") or "—")}</h3>'
                '<span class="rounded-full border border-rose-700/20 px-2 py-[1px] font-mono text-[9px] uppercase tracking-[0.12em] text-rose-700 dark:border-rose-400/25 dark:text-rose-300">제외</span>'
                "</div>"
                f'<p class="mt-2 max-w-3xl text-[12.5px] leading-relaxed text-muted">{inline(field(r, "reason")) if field(r, "reason") else EMPTY}</p>'
                f'<p class="mt-2 text-[11.5px] leading-relaxed text-faint">{inline(field(r, "verdict")) if field(r, "verdict") else ""}</p>'
                "</article>"
            )
        body.append('<div class="mt-3">' + "".join(rejected_cards) + "</div>")
    else:
        body.append(f'<p class="mt-3 text-[13px] text-muted">{EMPTY}</p>')
    body.append("</div>")

    aside = f"{len(providers)} providers · 실측 {measured}"
    return panel("providers", number, "Providers", "네 개의 소스, 네 개의 파서", aside, "".join(body), hidden)


# --------------------------------------------------------------------------
# Tab 03 — architecture
# --------------------------------------------------------------------------

def render_architecture(data, facts, number, hidden):
    architecture = as_dict(data.get("architecture"))
    tree = field(architecture, "tree")
    principles = as_list(architecture.get("principles"))
    polling = field(architecture, "polling")
    testing = field(architecture, "testing")

    body = []
    body.append(
        '<div class="overflow-hidden rounded-xl border border-ink/10 bg-surface/80">'
        '<div class="flex items-center justify-between border-b border-ink/10 px-4 py-2.5">'
        f'<span class="font-mono text-[10.5px] text-muted">Package.swift</span>'
        f'{label("module layout", "faint")}'
        "</div>"
        f'<pre class="overflow-x-auto px-5 py-5 font-mono text-[11.5px] leading-[1.8] text-ink/85">{esc(tree) if tree else "데이터 없음"}</pre>'
        "</div>"
    )

    body.append('<div class="mt-8">' + label("설계 원칙") + "</div>")
    principle_cards = []
    for index, principle in enumerate(principles, 1):
        principle_cards.append(
            '<div class="break-inside-avoid rounded-xl border border-ink/10 bg-surface/70 p-4">'
            '<div class="flex items-baseline gap-3">'
            f'<span class="font-mono text-[10px] tabular-nums text-rust">{index:02d}</span>'
            f'<p class="text-[13px] leading-relaxed text-ink/85">{inline(principle)}</p>'
            "</div></div>"
        )
    body.append(
        '<div class="mt-3 grid gap-3 sm:grid-cols-2">'
        + ("".join(principle_cards) if principle_cards else f'<p class="text-[13px] text-muted">{EMPTY}</p>')
        + "</div>"
    )

    def info_panel(icon_name, title_text, value):
        return (
            '<section class="break-inside-avoid rounded-xl border border-ink/10 bg-surface/70 p-5">'
            '<div class="flex items-center gap-2.5">'
            f'<span class="text-rust">{icon(icon_name, "h-4 w-4")}</span>'
            f'<h3 class="text-[13px] font-semibold">{title_text}</h3>'
            "</div>"
            f'<p class="mt-2 text-[12.5px] leading-relaxed text-muted">{inline(value) if value else EMPTY}</p>'
            "</section>"
        )

    body.append(
        '<div class="mt-8 grid gap-3 md:grid-cols-2">'
        + info_panel("clock", "폴링 전략", polling)
        + info_panel("flask", "테스트 전략", testing)
        + "</div>"
    )

    aside = "Core는 UI를 모른다"
    return panel("architecture", number, "Architecture", "순수한 코어, 격리된 실패", aside, "".join(body), hidden)


# --------------------------------------------------------------------------
# Tab 04 — security & legal
# --------------------------------------------------------------------------

SEVERITY = {
    "high": {
        "row": "border-l-rose-700/60 bg-rose-500/[0.04] dark:border-l-rose-400/60 dark:bg-rose-400/[0.05]",
        "tag": "border-rose-700/25 text-rose-700 dark:border-rose-400/30 dark:text-rose-300",
    },
    "medium": {
        "row": "border-l-amber-600/60 bg-amber-500/[0.05] dark:border-l-amber-300/60 dark:bg-amber-300/[0.05]",
        "tag": "border-amber-700/25 text-amber-800 dark:border-amber-300/30 dark:text-amber-300",
    },
}
SEVERITY_FALLBACK = {
    "row": "border-l-ink/20 bg-ink/[0.02]",
    "tag": "border-ink/20 text-muted",
}


def render_security(data, facts, number, hidden):
    security = as_dict(data.get("security"))
    asymmetry = field(security, "asymmetry")
    allowlist = as_list(security.get("allowlist"))
    policies = as_list(security.get("policies"))
    risks = [as_dict(r) for r in as_list(security.get("risks"))]

    counts = {}
    for risk in risks:
        key = str(field(risk, "level") or "").lower()
        counts[key] = counts.get(key, 0) + 1

    body = []
    body.append(
        '<div class="break-inside-avoid rounded-xl border border-y-ink/10 border-r-ink/10 border-l-2 border-l-rust bg-surface/80 p-5 sm:p-6">'
        '<div class="flex items-center gap-2.5">'
        f'<span class="text-rust">{icon("lock", "h-4 w-4")}</span>'
        f'{label("핵심 비대칭", "rust")}'
        "</div>"
        f'<p class="mt-2 max-w-3xl text-pretty text-[15px] leading-[1.7] text-ink/90">{inline(asymmetry) if asymmetry else EMPTY}</p>'
        "</div>"
    )

    body.append('<div class="mt-4 grid items-start gap-4 lg:grid-cols-2">')
    allow_chips = "".join(
        f'<li class="rounded-md border border-ink/12 bg-paper/70 px-2.5 py-1 font-mono text-[11px] text-ink/80">{esc(host)}</li>'
        for host in allowlist
    )
    allow_html = (
        allow_chips
        if allow_chips
        else f'<li class="text-[12px] text-muted">{EMPTY}</li>'
    )
    body.append(
        '<section class="break-inside-avoid rounded-xl border border-ink/10 bg-surface/70 p-5">'
        '<div class="flex items-center gap-2.5">'
        f'<span class="text-ink/50">{icon("globe", "h-4 w-4")}</span>'
        '<h3 class="text-[13px] font-semibold">네트워크 allowlist</h3>'
        "</div>"
        f'<ul class="mt-3 flex flex-wrap gap-2">{allow_html}</ul>'
        '<p class="mt-3 text-[11.5px] leading-relaxed text-faint">이 도메인 밖으로 나가는 요청은 만들지 않는다.</p>'
        "</section>"
    )

    policy_rows = "".join(note_row(policy) for policy in policies)
    policy_html = (
        policy_rows
        if policy_rows
        else f'<li class="text-[13px] text-muted">{EMPTY}</li>'
    )
    body.append(
        '<section class="break-inside-avoid rounded-xl border border-ink/10 bg-surface/70 p-5">'
        '<div class="flex items-center gap-2.5">'
        f'<span class="text-ink/50">{icon("shield", "h-4 w-4")}</span>'
        '<h3 class="text-[13px] font-semibold">정책</h3>'
        "</div>"
        f'<ul class="mt-3 space-y-2">{policy_html}</ul>'
        "</section>"
    )
    body.append("</div>")

    body.append('<div class="mt-8">' + label("리스크") + "</div>")
    risk_rows = []
    for risk in risks:
        level = str(field(risk, "level") or "").lower()
        tone = SEVERITY.get(level, SEVERITY_FALLBACK)
        risk_rows.append(
            f'<div class="break-inside-avoid rounded-r-lg border-y border-r border-ink/10 border-l-2 px-4 py-3 {tone["row"]}">'
            '<div class="flex items-start gap-3">'
            f'<span class="mt-[1px] shrink-0 rounded border px-1.5 py-[1px] font-mono text-[9px] tracking-[0.1em] {tone["tag"]}">{esc(level.upper() if level else "—")}</span>'
            f'<p class="text-[12.5px] leading-relaxed text-ink/85">{inline(field(risk, "text")) if field(risk, "text") else EMPTY}</p>'
            "</div></div>"
        )
    body.append(
        '<div class="mt-3 space-y-2">'
        + ("".join(risk_rows) if risk_rows else f'<p class="text-[13px] text-muted">{EMPTY}</p>')
        + "</div>"
    )

    aside = f"HIGH {counts.get('high', 0)} · MEDIUM {counts.get('medium', 0)}"
    return panel("security", number, "Security & legal", "읽기만 하고, 남기지 않는다", aside, "".join(body), hidden)


# --------------------------------------------------------------------------
# Tab 05 — roadmap
# --------------------------------------------------------------------------

ROADMAP_STATES = {
    "done": {
        "label": "완료",
        "badge": "border-emerald-700/25 text-emerald-800 dark:border-emerald-400/30 dark:text-emerald-300",
        "marker": "border-emerald-600/35 text-emerald-700 dark:border-emerald-400/40 dark:text-emerald-300",
        "bar": "bg-emerald-600/70 dark:bg-emerald-400/70",
    },
    "active": {
        "label": "진행 중",
        "badge": "border-indigo-600/25 text-indigo-700 dark:border-indigo-400/30 dark:text-indigo-300",
        "marker": "border-indigo-500/40 text-indigo-600 dark:border-indigo-400/45 dark:text-indigo-300",
        "bar": "bg-indigo-500/80 dark:bg-indigo-400/80",
    },
    "next": {
        "label": "다음",
        "badge": "border-ink/20 text-muted",
        "marker": "border-ink/20 text-muted",
        "bar": "bg-ink/35",
    },
    "later": {
        "label": "예정",
        "badge": "border-ink/12 text-faint",
        "marker": "border-dashed border-ink/20 text-faint",
        "bar": "bg-ink/20",
    },
}
ROADMAP_FALLBACK = {
    "label": "—",
    "badge": "border-ink/15 text-muted",
    "marker": "border-ink/15 text-faint",
    "bar": "bg-ink/15",
}


def render_roadmap(data, facts, number, hidden):
    phases = [as_dict(p) for p in as_list(data.get("roadmap"))]
    rows = []
    total_items = 0
    total_done = 0
    done_titles = []
    active_titles = []

    for phase in phases:
        items = [as_dict(i) for i in as_list(phase.get("items"))]
        phase_done = sum(1 for i in items if i.get("done") is True)
        total_items += len(items)
        total_done += phase_done
        state_key = str(field(phase, "state") or "").lower()
        state = ROADMAP_STATES.get(state_key, ROADMAP_FALLBACK)
        phase_name = field(phase, "phase") or "—"
        if state_key == "done":
            done_titles.append(str(phase_name))
        if state_key == "active":
            active_titles.append(str(phase_name))

        item_html = []
        for item in items:
            is_done = item.get("done") is True
            if is_done:
                marker = f'<span class="mt-[2px] shrink-0 text-emerald-700 dark:text-emerald-300">{icon("check", "h-3.5 w-3.5")}</span>'
                prefix = '<span class="sr-only">완료 — </span>'
                text_class = "text-ink/80"
            else:
                marker = '<span class="mt-[2px] h-3.5 w-3.5 shrink-0 rounded-[3px] border border-ink/20"></span>'
                prefix = '<span class="sr-only">미완료 — </span>'
                text_class = "text-muted"
            item_html.append(
                '<li class="flex gap-2.5 text-[12.5px] leading-relaxed">'
                f'{marker}{prefix}<span class="{text_class}">{inline(field(item, "text")) if field(item, "text") else "—"}</span>'
                "</li>"
            )

        ratio = f"{phase_done}/{len(items)}" if items else "—"
        percent = (phase_done / len(items) * 100) if items else 0
        items_html = (
            "".join(item_html)
            if item_html
            else f'<li class="text-[12.5px] text-muted">{EMPTY}</li>'
        )

        rows.append(
            '<li class="relative pl-10 sm:pl-12">'
            f'<span class="absolute left-0 top-0.5 grid h-8 w-8 place-items-center rounded-full border bg-paper {state["marker"]}">'
            + (
                f'<span class="absolute inset-0 rounded-full bg-indigo-500/20 animate-ping motion-reduce:animate-none"></span>'
                if state_key == "active" else ""
            )
            + (
                icon("check", "h-4 w-4")
                if state_key == "done"
                else '<span class="relative h-1.5 w-1.5 rounded-full bg-current"></span>'
                if state_key == "active"
                else '<span class="h-1.5 w-1.5 rounded-full bg-current"></span>'
                if state_key == "next"
                else '<span class="h-2 w-2 rounded-full border border-current"></span>'
            )
            + "</span>"
            '<div class="break-inside-avoid rounded-xl border border-ink/10 bg-surface/75 p-4 sm:p-5">'
            '<div class="flex flex-wrap items-center gap-x-3 gap-y-1.5">'
            f'<span class="font-mono text-[10px] uppercase tracking-[0.14em] text-faint">{esc(phase_name)}</span>'
            f'<h3 class="text-[14px] font-semibold">{esc(field(phase, "title") or "—")}</h3>'
            f'<span class="rounded-full border px-2 py-[1px] font-mono text-[9px] uppercase tracking-[0.12em] {state["badge"]}">{state["label"]}</span>'
            f'<span class="ml-auto font-mono text-[11px] tabular-nums text-muted">{ratio}</span>'
            "</div>"
            '<div class="mt-3 h-1 w-full overflow-hidden rounded-full bg-ink/10" aria-hidden="true">'
            f'<div class="h-full rounded-full {state["bar"]}" style="width: {percent:.1f}%"></div>'
            "</div>"
            f'<ul class="mt-3.5 space-y-1.5">{items_html}</ul>'
            "</div></li>"
        )

    overall_percent = (total_done / total_items * 100) if total_items else 0
    state_line = []
    if done_titles:
        state_line.append("완료 " + ", ".join(done_titles))
    if active_titles:
        state_line.append("진행 중 " + ", ".join(active_titles))

    body = []
    body.append(
        '<div class="break-inside-avoid rounded-xl border border-ink/10 bg-surface/80 p-5">'
        '<div class="flex flex-wrap items-baseline justify-between gap-2">'
        f'{label("전체 진행")}'
        f'<span class="font-mono text-[12px] tabular-nums text-ink/80">{total_done} / {total_items} <span class="text-faint">({overall_percent:.0f}%)</span></span>'
        "</div>"
        '<div class="mt-3 h-1.5 w-full overflow-hidden rounded-full bg-ink/10" role="progressbar" '
        f'aria-valuemin="0" aria-valuemax="{total_items}" aria-valuenow="{total_done}" aria-label="전체 로드맵 진행">'
        f'<div class="h-full rounded-full bg-rust" style="width: {overall_percent:.1f}%"></div>'
        "</div>"
        f'<p class="mt-2.5 text-[11.5px] text-muted">{" · ".join(state_line) if state_line else EMPTY}</p>'
        "</div>"
    )
    body.append(
        '<ol class="relative mt-6 space-y-4">'
        '<span class="absolute left-4 top-3 bottom-3 w-px bg-gradient-to-b from-ink/15 via-ink/10 to-transparent" aria-hidden="true"></span>'
        + "".join(rows)
        + "</ol>"
    )

    aside = f"{len(phases)} phases"
    return panel("roadmap", number, "Roadmap", "지금 어디까지 왔는가", aside, "".join(body), hidden)


# --------------------------------------------------------------------------
# Tab 06 — open decisions
# --------------------------------------------------------------------------

def render_decisions(data, facts, number, hidden):
    decisions = [as_dict(d) for d in as_list(data.get("risks"))]

    rows = []
    for decision in decisions:
        rows.append(
            '<tr class="align-top transition-colors hover:bg-ink/[0.025]">'
            f'<td class="w-12 px-4 py-3 font-mono text-[10.5px] tabular-nums text-faint">{esc(field(decision, "id") or "—")}</td>'
            f'<th scope="row" class="px-4 py-3 text-left text-[12.5px] font-medium leading-relaxed">{inline(field(decision, "question")) if field(decision, "question") else "—"}</th>'
            f'<td class="px-4 py-3 text-[12.5px] leading-relaxed text-muted">{inline(field(decision, "stance")) if field(decision, "stance") else EMPTY}</td>'
            "</tr>"
        )

    body = []
    body.append(
        '<div class="rounded-r-lg border border-ink/10 border-l-2 border-l-rust bg-surface/60 px-4 py-3">'
        f'{label("정본", "rust")}'
        '<p class="mt-1 text-[12.5px] leading-relaxed text-muted">'
        "열린 결정의 정본은 <code>AGENTS.md</code> §10이다. 이 표는 요약이며, 결정을 바꿀 때는 "
        "<code>AGENTS.md</code>를 먼저 고치고 여기와 <code>docs/status/data.json</code>을 따라 맞춘다.</p>"
        "</div>"
    )

    empty_row = (
        '<tr><td colspan="3" class="px-4 py-4 text-[13px] text-muted">'
        + EMPTY
        + "</td></tr>"
    )
    rows_html = "".join(rows) if rows else empty_row

    body.append(
        '<div class="mt-4 overflow-x-auto rounded-xl border border-ink/10">'
        '<table class="w-full min-w-[640px] border-collapse text-left">'
        '<thead><tr class="border-b border-ink/10 bg-surface-2/50">'
        '<th scope="col" class="label-mono px-4 py-2.5 text-muted">#</th>'
        '<th scope="col" class="label-mono px-4 py-2.5 text-muted">결정</th>'
        '<th scope="col" class="label-mono px-4 py-2.5 text-muted">현재 기조</th>'
        "</tr></thead>"
        f'<tbody class="divide-y divide-ink/10 bg-surface/60">{rows_html}</tbody>'
        "</table></div>"
    )

    aside = f"열린 결정 {len(decisions)}"
    return panel("decisions", number, "Decisions", "아직 정하지 않은 것", aside, "".join(body), hidden)


# --------------------------------------------------------------------------
# Tab 07 — log
# --------------------------------------------------------------------------

def render_log(data, facts, number, hidden):
    product_log = [as_dict(entry) for entry in as_list(data.get("log"))]
    commits = as_list(facts.get("log"))

    body = []
    body.append(label("제품 로그"))
    product_rows = []
    for entry in product_log:
        product_rows.append(
            '<li>'
            f'<time class="font-mono text-[10.5px] tabular-nums text-faint">{esc(field(entry, "date") or "—")}</time>'
            f'<p class="mt-1 text-[13px] leading-relaxed text-ink/85">{inline(field(entry, "text")) if field(entry, "text") else EMPTY}</p>'
            "</li>"
        )
    product_html = (
        "".join(product_rows)
        if product_rows
        else f'<li class="text-[13px] text-muted">{EMPTY}</li>'
    )
    body.append(f'<ol class="timeline mt-3">{product_html}</ol>')

    body.append('<div class="mt-8">' + label(f"커밋 · 최근 {len(commits)}") + "</div>")
    commit_rows = []
    for commit in commits:
        commit_rows.append(
            '<li class="timeline-ink">'
            '<div class="flex flex-wrap items-baseline gap-2">'
            f'<code class="text-[10.5px]">{esc(commit.get("hash"))}</code>'
            f'<time class="font-mono text-[10.5px] tabular-nums text-faint">{esc(commit.get("date"))}</time>'
            "</div>"
            f'<p class="mt-1 text-[13px] leading-relaxed text-ink/85">{esc(commit.get("subject"))}</p>'
            "</li>"
        )
    if commit_rows:
        body.append('<ol class="timeline mt-3">' + "".join(commit_rows) + "</ol>")
    else:
        body.append(f'<p class="mt-3 text-[13px] text-muted">{EMPTY}</p>')

    body.append(
        '<p class="mt-8 text-[11.5px] leading-relaxed text-faint">'
        "커밋은 로컬 저장소 기준 최근 15개까지 표시한다. 제품 로그는 "
        "<code>docs/status/data.json</code>의 <code>log</code> 배열에서 온다.</p>"
    )

    aside = f"제품 로그 {len(product_log)} · 커밋 {len(commits)}"
    return panel("log", number, "Log", "무슨 일이 있었나", aside, "".join(body), hidden)


# --------------------------------------------------------------------------
# Header, hero, footer, document
# --------------------------------------------------------------------------

def render_header(meta, generated_at):
    product = field(meta, "product") or "Fillline"
    version = field(meta, "version")
    status = field(meta, "status")
    phase = field(meta, "phase")
    stamp = generated_at.strftime("%Y-%m-%d %H:%M")

    badges = []
    if status:
        badges.append(
            '<span class="hidden items-center gap-1.5 rounded-full border border-ink/12 bg-surface px-2 py-[2px] sm:inline-flex">'
            '<span class="h-1 w-1 rounded-full bg-rust"></span>'
            f'<span class="font-mono text-[9px] uppercase tracking-[0.12em] text-muted">{esc(status)}</span></span>'
        )
    if phase:
        badges.append(f'<span class="hidden truncate text-[11.5px] text-muted lg:inline">{esc(phase)}</span>')

    return (
        '<header class="sticky top-0 z-40 border-b border-ink/10 bg-paper/85 backdrop-blur-md">'
        '<div class="mx-auto flex h-14 max-w-6xl items-center gap-2.5 px-4 sm:gap-3 sm:px-6">'
        f'<span class="text-rust">{icon("gauge", "h-[18px] w-[18px]")}</span>'
        '<span class="font-serif text-[19px] leading-none tracking-[-0.01em] text-ink">'
        f"{esc(product)}</span>"
        + (f'<span class="font-mono text-[10px] text-faint">v{esc(version)}</span>' if version else "")
        + "".join(badges)
        + '<div class="ml-auto flex items-center gap-2.5 sm:gap-4">'
        '<div class="text-right">'
        '<div class="label-mono hidden text-faint sm:block">updated</div>'
        '<div class="font-mono text-[10.5px] tabular-nums text-muted sm:text-[11px]">'
        f'<span class="hidden sm:inline">{esc(stamp)}</span>'
        f'<span class="sm:hidden">{esc(generated_at.strftime("%H:%M"))}</span>'
        ' <span class="text-faint">KST</span></div>'
        "</div>"
        '<button id="theme-toggle" type="button" aria-pressed="false" aria-label="다크 모드로 전환" title="테마 전환" '
        'class="focus-ring no-print inline-flex h-8 w-8 items-center justify-center rounded-full border border-ink/12 bg-surface text-ink/65 transition-colors hover:border-ink/25 hover:text-ink">'
        f'<span class="icon-moon">{icon("moon", "h-4 w-4")}</span>'
        f'<span class="icon-sun">{icon("sun", "h-4 w-4")}</span>'
        "</button>"
        "</div></div></header>"
    )


def render_hero(meta, stats, facts):
    tagline = field(meta, "tagline")
    repo = field(meta, "repo")

    meta_bits = []
    if field(meta, "license"):
        meta_bits.append(esc(field(meta, "license")))
    if repo:
        meta_bits.append(esc(repo))
    meta_bits.append("docs/status/data.json")

    return (
        '<div class="mx-auto max-w-6xl px-4 sm:px-6">'
        '<section class="page-load pt-10 sm:pt-12">'
        '<div class="flex items-center gap-3">'
        f'{label("Product status")}'
        '<span class="h-px flex-1 bg-ink/10"></span>'
        '<span class="hidden font-mono text-[10px] text-faint sm:inline">single source · data.json</span>'
        "</div>"
        f'<h1 class="mt-4 max-w-3xl text-balance text-[1.6rem] font-semibold leading-[1.3] tracking-[-0.025em] sm:text-[2.15rem]">{esc(tagline) if tagline else EMPTY}</h1>'
        '<p class="mt-3 flex flex-wrap items-center gap-x-2.5 gap-y-1 font-mono text-[10.5px] text-faint">'
        + '<span class="text-ink/25">/</span>'.join(f"<span>{bit}</span>" for bit in meta_bits)
        + "</p>"
        "</section>"
        f'<section aria-label="핵심 지표" class="mt-8">{stat_cards(stats)}</section>'
        f'<div class="mt-3">{repo_strip(facts)}</div>'
        "</div>"
    )


def render_footer(meta):
    repo = field(meta, "repo")
    license_name = field(meta, "license") or "MIT"
    product = field(meta, "product") or "Fillline"
    command = "python3 Scripts/status.py --open"

    return (
        '<footer class="mt-4 border-t border-ink/10 bg-surface/40">'
        '<div class="mx-auto max-w-6xl px-4 py-8 sm:px-6">'
        '<div class="flex flex-col gap-6 sm:flex-row sm:items-start sm:justify-between">'
        "<div>"
        '<div class="flex items-center gap-2.5">'
        f'<span class="text-rust">{icon("gauge", "h-4 w-4")}</span>'
        f'<span class="font-serif text-[15px] text-ink">{esc(product)}</span>'
        f'<span class="rounded-full border border-ink/15 px-2 py-[1px] font-mono text-[9px] uppercase tracking-[0.12em] text-muted">{esc(license_name)}</span>'
        "</div>"
        '<p class="mt-2 max-w-md text-[11.5px] leading-relaxed text-muted">'
        "Claude, OpenAI, OpenCode, Google과 제휴하거나 후원받지 않은 독립 프로젝트입니다. "
        "비공식 엔드포인트 사용과 계정 제재 가능성은 README에 고지되어 있습니다.</p>"
        "</div>"
        '<div class="sm:text-right">'
        f'{label("재생성", "faint")}'
        '<div class="mt-1.5 inline-flex items-center gap-3 rounded-md border border-ink/12 bg-paper px-2.5 py-1.5">'
        f'<code class="border-0 bg-transparent p-0 text-[11px]">{esc(command)}</code>'
        f'<button type="button" data-copy="{esc(command)}" data-label="복사" aria-label="재생성 명령 복사" '
        'class="focus-ring shrink-0 rounded border border-ink/10 px-2 py-1 text-[10.5px] leading-none text-muted transition-colors hover:border-ink/25 hover:text-ink">복사</button>'
        "</div>"
        f'<p class="mt-2 max-w-xs text-[11px] leading-relaxed text-faint sm:ml-auto">이 페이지는 <code>{esc(command)}</code> 으로 재생성됩니다.</p>'
        "</div></div>"
        '<div class="mt-6 flex flex-wrap items-center justify-between gap-2 border-t border-ink/10 pt-4 font-mono text-[10px] text-faint">'
        f'<span>source docs/status/data.json</span>'
        f'<span>{len(TABS)} sections · {esc(repo) if repo else "local"}</span>'
        "</div></div></footer>"
    )


def build_document(data, facts, generated_at):
    meta = as_dict(data.get("meta"))
    stats = as_list(data.get("stats"))
    product = field(meta, "product") or "Fillline"
    tagline = field(meta, "tagline") or "제품 상태"

    tab_buttons = []
    for index, (tab_id, tab_label) in enumerate(TABS, 1):
        selected = index == 1
        tab_buttons.append(
            f'<button type="button" role="tab" id="tab-{tab_id}" aria-controls="panel-{tab_id}" '
            f'aria-selected="{"true" if selected else "false"}" tabindex="{0 if selected else -1}" '
            f'data-tab="{tab_id}" class="tab focus-ring">'
            f'<span class="tab-index" aria-hidden="true">{index:02d}</span>'
            f"<span>{esc(tab_label)}</span></button>"
        )

    panels = [
        render_overview(data, facts, "01", False),
        render_usage(data, facts, "02", True),
        render_providers(data, facts, "03", True),
        render_architecture(data, facts, "04", True),
        render_security(data, facts, "05", True),
        render_roadmap(data, facts, "06", True),
        render_decisions(data, facts, "07", True),
        render_log(data, facts, "08", True),
    ]

    favicon = (
        "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E"
        "%3Crect width='16' height='16' rx='4' fill='%23f2efe8'/%3E"
        "%3Cpath d='M3 12a5 5 0 1 1 10 0' fill='none' stroke='%23a6432a' stroke-width='1.6' stroke-linecap='round'/%3E"
        "%3Cpath d='M8 12 10 7.6' fill='none' stroke='%23a6432a' stroke-width='1.6' stroke-linecap='round'/%3E%3C/svg%3E"
    )

    head = (
        "<!doctype html>\n"
        '<html lang="ko">\n<head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{esc(product)} — 제품 상태</title>\n"
        f'<meta name="description" content="{esc(tagline)}">\n'
        '<meta name="color-scheme" content="light dark">\n'
        '<meta name="theme-color" content="#f2efe8" media="(prefers-color-scheme: light)">\n'
        '<meta name="theme-color" content="#12110e" media="(prefers-color-scheme: dark)">\n'
        f'<link rel="icon" href="{favicon}">\n'
        f"<script>{THEME_BOOT}</script>\n"
        '<script src="https://cdn.tailwindcss.com"></script>\n'
        f"<script>{TAILWIND_CONFIG}</script>\n"
        f"<style>{STYLE}</style>\n"
        "</head>\n"
        '<body class="min-h-screen antialiased">\n'
        '<a href="#main" class="skip-link">본문으로 건너뛰기</a>\n'
    )

    header = render_header(meta, generated_at)
    hero = render_hero(meta, stats, facts)

    tabbar = (
        '<div data-tabbar class="sticky top-14 z-30 mt-8 border-b border-ink/10 bg-paper/90 backdrop-blur-md">'
        '<div class="mx-auto max-w-6xl px-2 sm:px-6">'
        '<div role="tablist" aria-label="Fillline 상태 섹션" aria-orientation="horizontal" '
        'class="no-scrollbar -mb-px flex overflow-x-auto">'
        + "".join(tab_buttons)
        + "</div></div></div>"
    )

    noscript = (
        '<noscript><div class="mx-auto mt-4 max-w-6xl px-4 sm:px-6">'
        '<div class="rounded-lg border border-amber-700/25 bg-amber-500/[0.06] px-4 py-3 text-[12.5px] text-amber-900 dark:text-amber-200">'
        "탭 전환에는 JavaScript가 필요합니다. 인쇄할 때는 모든 섹션이 한 번에 표시됩니다.</div>"
        "</div></noscript>"
    )

    main = (
        '<main id="main">\n'
        + hero
        + "\n"
        + noscript
        + "\n"
        + tabbar
        + "\n"
        + '<div class="mx-auto max-w-6xl px-4 pb-16 sm:px-6">'
        + "".join(panels)
        + "</div>\n</main>\n"
    )

    footer = render_footer(meta)
    scripts = f"<script>{PAGE_JS}</script>\n</body>\n</html>\n"

    return head + header + "\n" + main + footer + scripts


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Render the Fillline product status dashboard from docs/status/data.json."
    )
    parser.add_argument("--out", metavar="PATH", default=str(DEFAULT_OUT),
                        help="output HTML path (default: docs/status/index.html)")
    parser.add_argument("--data", metavar="PATH", default=str(DATA_FILE),
                        help="data file to read (default: docs/status/data.json)")
    parser.add_argument("--open", action="store_true",
                        help="open the generated page in the default browser")
    args = parser.parse_args(argv)

    data_path = Path(args.data).expanduser()
    if not data_path.is_absolute():
        data_path = (Path.cwd() / data_path).resolve()
    try:
        data = json.loads(data_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"error: data file not found: {data_path}", file=sys.stderr)
        return 1
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: cannot read {data_path}: {error}", file=sys.stderr)
        return 1
    if not isinstance(data, dict):
        print(f"error: {data_path} must contain a JSON object", file=sys.stderr)
        return 1

    out = Path(args.out).expanduser()
    if not out.is_absolute():
        out = (Path.cwd() / out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)

    generated_at = datetime.now(KST)
    facts = read_git()
    document = build_document(data, facts, generated_at)

    tmp = out.with_name(out.name + ".tmp")
    tmp.write_text(document, encoding="utf-8")
    tmp.replace(out)

    size = len(document.encode("utf-8"))
    try:
        shown = out.relative_to(ROOT)
    except ValueError:
        shown = out
    print(f"{shown} · {size:,} bytes · {len(TABS)} tabs · {generated_at.strftime('%Y-%m-%d %H:%M')} KST")

    if args.open:
        opener = "open" if sys.platform == "darwin" else "xdg-open"
        try:
            subprocess.run([opener, str(out)], check=False, timeout=15)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"warning: could not open {out}: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
