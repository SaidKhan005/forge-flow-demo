# PR #510 Audit — B9.1 Sign-In Security 301 Redirect

**Slice:** B9.1 (Lane B — features)
**Owner:** Codex executor
**Branch:** `codex/b9-1-sign-in-security-redirect`
**Base:** `master` (no drift)
**Gate:** `auto` (no auth/proxy/schema touch; static nginx redirect only)
**Size:** 69 additions / 0 deletions / 3 files / 97 diff lines
**Chunking:** light variant (trivial)

## Pattern B compliance

Both audit tables present in PR body ✓.

## Verdict

**approve-for-merge** — auto-merged.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Redirect block placed BEFORE the `location /` SPA fallback in both Dockerfiles | ✓ — line 123 of `Dockerfile.operator_web` precedes the fallback block; same on `Dockerfile.admin_console:113` |
| Query params preserved via `$is_args$args` | ✓ — diff shows `return 301 "/my-account$is_args$args#security";` on both dockerfiles |
| Test asserts block ordering (legacy < fallback) | ✓ — `sign_in_security_redirect_test.dart:39-58` enforces `legacyIndex < fallbackIndex` |
| Test asserts the 301 line preserves `$is_args$args` + `#security` fragment | ✓ — `redirectLine` raw-string in test enforces exact shape |
| No auth/RLS/schema/proxy touch | ✓ — only Dockerfiles + 1 test |
| Frozen-surface untouched | ✓ |
| Demo carve-out untouched | ✓ |
| No `audit_logs` write | ✓ — static-redirect, no mutation |

## Authority anchors verified

- `docs/_execution/lane_b_features/03_execution_slices.md:142` — slice scope matches diff.
- `docs/_decisions/post_codex_wave_decisions_2026-05-12.md:25` — decision #7 (consolidate sign-in-security → My Account#security).
- Note from PR body: HTTP cannot preserve inbound fragments; redirect sets `#security` per decision-approved destination. Correct.

## Findings

None.

## Merge

Auto-merged at `bdfab551` on `origin/master` per Gate=auto + clean audit + no operator-decision finding.
