# Summary

<!-- What changes, and why. Link the issue if there is one. -->

## Type

- [ ] `feat` — new behaviour
- [ ] `fix` — bug or provider breakage (patch release)
- [ ] `docs`
- [ ] `refactor` / `test` / `chore`

## Checklist

- [ ] One PR = one concern.
- [ ] `swift build -v` and `swift test --parallel` pass locally.
- [ ] **Provider parser change?** A masked fixture and a parser test are included in this PR.
      (A parser change without a fixture will be rejected.)
- [ ] Provider change keeps the `primary → fallback → cached` ladder, and there is a test
      proving failure yields `stale`, not a fabricated value — and never `0%`.
- [ ] Any new URL points at an allowlisted host (`api.anthropic.com`, `chatgpt.com`,
      `opencode.ai`). New hosts are a separate PR that updates the allowlist constant *and*
      the CI guard.
- [ ] No credentials, tokens, cookies, emails, or org IDs in the diff, the fixtures, or the
      PR description. If a real response was captured, it was masked per CONTRIBUTING.md.
- [ ] Commits use Conventional Commits.
- [ ] User-facing strings: remaining-% stays primary, stale values are labelled, estimates
      are marked `estimated`.

## Notes for reviewers

<!-- Risk, follow-ups, screenshots (of the UI only — never of a populated credential file). -->
