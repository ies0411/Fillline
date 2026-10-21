# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report privately through GitHub Security Advisories:
<https://github.com/ies0411/Fillline/security/advisories/new>
(replace `OWNER` once the repository is public).

If Advisory reporting is unavailable, open a minimal issue that says only "security report
requested" — no details, no logs, no credentials — and a maintainer will open a private
channel.

Please include: affected version or commit, macOS version, steps to reproduce, and impact.
Redact tokens, cookies, emails, and org IDs from anything you paste.

**Expect an acknowledgement within 72 hours.** We will confirm the report, agree on a
disclosure timeline (default 90 days), and credit you in the advisory unless you ask
otherwise. This is a volunteer project: there is no bug bounty, and no warranty is offered.

## Scope

In scope:

- Credential handling: tokens read from the Keychain, `~/.codex/auth.json`, or
  `~/.config/opencode/.secrets/opencode-key` being leaked, logged, persisted, or written
  back to the source location.
- Domain allowlist bypass: any request to a host outside `api.anthropic.com`,
  `chatgpt.com`, `opencode.ai` (including via redirect, DNS tricks, or URL construction).
- Injection or memory-safety issues in response parsing that could lead to code execution.
- Supply-chain issues in the build, signing, or notarization scripts.
- Anything that would let a local attacker read another provider's credentials through the
  app.

Out of scope:

- **Quota values being wrong, missing, or stale.** That is a bug — please file a normal
  issue with the provider template. It is not a vulnerability unless it crosses into the
  categories above.
- Rate limiting or account action taken by a provider as a result of using undocumented
  endpoints. This risk is disclosed in the README; use at your own risk.
- Vulnerabilities that require an attacker who already has your user account, your unlocked
  Keychain, or physical access to an unlocked machine.
- Reports produced solely by a scanner, with no demonstrated impact.

## Token-leak response runbook

If a credential leaks — through a log, a crash report, a fixture, an issue, or a release
artifact — maintainers act in this order:

1. **Contain (immediate).** Delete or redact the exposed content (issue edit/delete, commit
   history rewrite, release asset removal). Make the repository private if the blast radius
   is unclear. Do not discuss specifics in public.
2. **Rotate (within 24 h).** Tell the affected user to revoke and re-issue the credential:
   Claude Code → `claude` logout/login or Keychain item deletion; Codex → `codex` logout and
   re-login; OpenCode → rotate the key at the provider and replace
   `~/.config/opencode/.secrets/opencode-key`. Rotation belongs to the credential owner; the
   app never writes these files.
3. **Purge.** Remove the secret from git history (`git filter-repo`), force-push the
   affected branches, invalidate caches and forks where possible, and re-issue any release
   artifact that embedded it. Assume anything pushed publicly is already copied.
4. **Patch.** Add a regression test and, where the leak came from code, a CI guard (the
   token-pattern grep step is the last line of defence) so the same path cannot recur.
5. **Disclose.** Publish a GitHub Security Advisory with severity, affected versions, the
   fixed version, and the rotation steps — after rotation is complete, not before.
6. **Review.** Record what failed in the PR that fixes it. If the leak was caused by a
   contributor's fixture, tighten `CONTRIBUTING.md` masking rules in the same PR.
