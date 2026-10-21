# Product operations

How this repository is run as a product, not a scratch project. The rules here are
also encoded in `AGENTS.md`; this page is the human-facing version.

Repository: <https://github.com/ies0411/Fillline>

## Branching

- `main` is always releasable and is protected against force-push and deletion.
- Work lands on short-lived branches named `<type>/<slug>` (`feat/codex-app-server`,
  `fix/go-403-state`) when it spans more than one commit or touches a provider parser.
- Solo changes of one commit may go straight to `main`, but never with a red
  `./Scripts/test-local.sh`.
- Tags are `vMAJOR.MINOR.PATCH` with `-alpha.N` / `-beta.N` for pre-releases, created
  from `main` only, and always pushed before the release is published.
- Commit messages follow Conventional Commits; the scope is the area (`core`, `ui`,
  `docs`, `tooling`, provider id).

## Branches of truth

| Question | Source of truth |
|---|---|
| What the product is and its rules | `AGENTS.md` |
| Provider contracts and failure modes | `docs/providers/*.md` |
| What changed in a release | `CHANGELOG.md` |
| Current progress, blockers, open decisions | `docs/status/data.json` (rendered to `docs/status/index.html`) |
| Build/release mechanics | `project.yml`, `Scripts/*.sh` |

Never duplicate a fact into a second file. If a number changes, change it where it is owned
and regenerate anything derived.

## Issues

Every non-trivial change starts as an issue. Titles are imperative and scoped:
`feat(core): …`, `fix(ui): …`, `chore(release): …`.

Labels carry semantics, and `release.yml` consumes them:

| Label | Meaning |
|---|---|
| `type:feat` / `type:fix` / `type:docs` / `type:chore` | the kind of change |
| `area:core` / `area:ui` / `area:provider` / `area:tooling` | where it lives |
| `provider:claude-code` / `provider:codex` / `provider:opencode-go` / `provider:antigravity` | which source it touches |
| `needs:verification` | ship only with a live capture or a reproduction |
| `blocked` | waiting on something outside the repo |
| `breaking` | needs a minor/major bump and a migration note |
| `good first issue` | self-contained, no credential access |
| `skip-changelog` | internal churn that should not appear in release notes |

## Milestones

- `v0.2.0 — MVP hardening` — correctness and trust: Codex live verification, strategy
  provenance, reset credits, notifications, glyph polish.
- `v0.3.0 — distribution` — signing, notarization, DMG, Homebrew cask, README screenshots,
  snapshot history.

A milestone closes only when every issue in it is closed or explicitly moved.

## Releases

1. `CHANGELOG.md` gets a version heading with the date and a `[Unreleased]` reset.
2. `./Scripts/test-local.sh` green, `swiftc -typecheck` clean for `Sources/UsageApp`.
3. Tag and push: `git tag -a vX.Y.Z -m "…" && git push origin vX.Y.Z`.
4. `gh release create vX.Y.Z --notes-file <extracted changelog> --prerelease|--latest`
   (categories come from `.github/release.yml`).
5. Provider-breakage fixes ship as patch releases; they are never batched into a feature
   release, because users are blocked on a wrong number.

## Provider breakage runbook

1. Reproduce with a real capture (masked) — never guess the new shape.
2. Update the parser + fixture + `docs/providers/<provider>.md` in one PR.
3. If the source is gone, degrade honestly: `.unsupported` or `.notInstalled`, never `0%`.
4. Patch release within the same day; add a `CHANGELOG.md` entry naming the provider.
