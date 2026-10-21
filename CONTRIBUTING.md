# Contributing

Thanks for helping. This project touches credentials, so the rules below are stricter than
usual — please read them before opening a PR.

By contributing you agree that your work is licensed under the [MIT License](LICENSE) and
that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Build and test

The core library needs only Command Line Tools. The app bundle needs full Xcode.

```bash
swift build            # UsageCore
swift test             # fixture-based tests, no network, no real account
swift build -v
swift test --parallel
```

App bundle (optional, requires Xcode + XcodeGen):

```bash
brew install xcodegen
xcodegen generate
./Scripts/build.sh
```

Never commit `.xcodeproj`, `build/`, `DerivedData/`, or `.swiftpm/` — they are generated and
gitignored. `Package.resolved` **is** committed; keep it in the diff when dependencies
change.

Rules for dependencies: none by default. A new dependency must be MIT or Apache-2.0, justify
itself in the PR description, and be proposed in its own PR.

## Adding a provider

Five steps, all required in the same PR:

1. **Conform to `UsageProvider`.** Implement the protocol in
   `Sources/UsageCore/Providers/<Name>/`. UI code must not import provider internals.
2. **Put every URL, header name, and response key in `<Name>/Endpoints.swift`.** No URL
   literals anywhere else, and only hosts on the allowlist (`api.anthropic.com`,
   `chatgpt.com`, `opencode.ai`). Adding a host requires a separate PR that updates both
   the allowlist constant and the CI guard.
3. **Add a masked fixture** under `Tests/UsageCoreTests/Fixtures/<Name>/` and a parser test
   that decodes it. Capture it from a real response, then mask it (below) before committing.
4. **Add a fallback path.** Every provider is `primary → fallback → cached`. If the primary
   endpoint fails, the provider must degrade, not throw the whole app into an error state.
5. **Add a stale-path test.** Simulate a failing `HTTPClient`, then assert that the previous
   snapshot survives with `stale` status and a correct age, and that no fabricated value
   (especially `0%`) is ever produced.

A provider parser change **without** its fixture will be rejected. This is not negotiable:
the endpoints are undocumented, and fixtures are the only regression net we have.

## Fixture masking rules

Fixtures are committed to a public repo. Treat every captured response as hostile until
proven clean.

- **Never commit real tokens, emails, org IDs, account IDs, or session cookies.** Not even
  expired ones.
- Replace access tokens, refresh tokens, API keys, and JWTs with `<redacted>`. This includes
  anything matching `sk-ant-*`, `oc_sk_*`, `sk-*`, and `eyJ...` (JWT) shapes.
- Truncate or zero UUIDs and opaque IDs (`00000000-0000-0000-0000-000000000000`).
- Replace emails with `user@example.com`, names with `Example User`.
- Keep the *structure* — field names, types, nullability, nesting, and numbers — intact.
  Removing optional fields defeats the point of the fixture.
- Reduce timestamps to fixed, readable values. Deterministic fixtures beat "realistic" ones.
- Run `git diff` before committing and look for `sk-`, `Bearer `, and `@` by eye.

## Commits and PRs

- **Conventional Commits:** `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
  Example: `fix(codex): tolerate missing weekly window in usage payload`.
- **One PR = one concern.** A parser fix does not carry a UI refactor.
- Provider breakage fixes are `fix:` and ship as a patch release.
- User-facing strings are review targets: keep remaining-% primary, never imply a value is
  fresh when it is stale, and never display an estimate without an `estimated` label.
- Do not `git push` or commit on someone else's behalf; no force-pushes to `main`.
- Changes to project policy documents (`AGENTS.md`, this file, `SECURITY.md`) go in their
  own PR, separate from code.

## Reporting a broken provider

Use the "Provider broken" issue template. Include the provider, the HTTP status, and the
shape of the response **with all values removed**. Do not paste a token, a cookie, or a
full session log — the template will remind you, but it is your responsibility.
