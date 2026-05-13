# PR #542 Audit — Gate Apple Platform Verification to `workflow_dispatch` Only

**Slice:** Not a wave slice — operator/orchestrator-class CI cost-discipline change
**Owner:** Claude Code session (branch `claude/stoic-mcclintock-2a6901`)
**Base:** `master`
**Gate:** `operator` — CI/billing infrastructure decision
**Size:** 9 additions / 4 deletions / 1 file (`.github/workflows/apple-platform-verify.yml`)
**Chunking:** trivial (single-file CI config)

## What this PR does

Removes `push` and `pull_request` triggers from `.github/workflows/apple-platform-verify.yml`. Keeps `workflow_dispatch` so the workflow can still be triggered manually from the Actions tab.

After this lands, `repo-lints`, `analyze-and-test`, and `postgres-tests` are the only auto-running CI jobs on every commit (all Linux, all cheap).

## Why this PR exists (the root-cause story)

**CI has been at 100% failure for ~5 days** (since 2026-05-08). Every wave PR this orchestrator session audited inherited red CI status checks. The pattern (all jobs fail in 2-10 seconds, no log output, both macOS and Linux) is consistent with **GitHub Actions spending-cap exhaustion** cascading to all runners.

The Apple Platform Verification workflow runs 3 macOS-15 jobs (host tests + ForgeFlow iOS sim + Barrio iOS sim) on every push to master AND every PR. **macos-15 runners are billed at ~10× the Linux rate.** Eliminating the auto-run is the cost-discipline half of the fix:
- Operator needs to verify Settings → Billing & spending → "Actions spending limit" to clear the cascade (out of repo scope)
- This PR shrinks the per-commit Actions draw so the cap stops re-tripping once cleared

## Verdict

**approve-pending-operator** — escalating because:
1. CI/billing infrastructure decision (operator-class, not slice-class)
2. Removes automatic Apple verification on every PR — meaningful behavior change
3. The branch name `claude/stoic-mcclintock-2a6901` doesn't fit the slice-branch convention; this PR came from a Claude Code session outside the wave executor lanes

Recommendation: **approve-for-merge.** The change addresses the actual root cause of the 5-day CI red baseline. The diff is trivial (4 lines of trigger config + comment). The manual-trigger path is preserved + documented.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Diff is purely additive comment + trigger removal** (no other workflow logic touched) | ✓ — only `on:` block changed; `jobs:` block untouched |
| **`workflow_dispatch` preserved** so the Apple jobs can still run on demand | ✓ — `on: workflow_dispatch:` stays at the top of the trigger block |
| **Comment block lists what changes should trigger a manual Apple run** | ✓ — `ios/**`, `macos/**`, Firebase plists, MFA/session tests, Apple-platform Flutter code paths |
| **No other CI workflows touched** | ✓ — `.github/workflows/ci.yml` (the Linux repo-lints / analyze-and-test / postgres-tests workflow) is NOT in the diff |
| **Required-status-check implications** | NOT VERIFIED in this audit — operator should confirm whether the GitHub branch protection rules require Apple workflow status. If they do, branch protection must be updated to drop the requirement, or PRs will block on a check that no longer auto-runs. **Action item for operator.** |

## Risk analysis

**Risk if merged:**
- iOS/macOS regressions slip in unnoticed if author forgets to dispatch the workflow manually
- **Mitigation**: the comment block in the workflow file lists the files that should trigger a manual dispatch (`ios/**`, `macos/**`, Firebase plists, etc.). PR authors who touch those files now need discipline to remember.

**Risk if NOT merged:**
- CI red baseline continues. Every wave PR audit will show a misleading FAILURE status that obscures real failures when they occur.
- macOS billing continues at ~10× Linux rate per commit. Cost-discipline issue.

**Operator action items (beyond this PR):**
1. Verify and clear GitHub Actions spending cap in repo settings
2. Update branch protection rules to drop the Apple workflow requirement (if currently required)
3. Establish a habit/checklist for manually dispatching the Apple workflow before merging Apple-touching PRs

## Authority anchors

This PR doesn't cite a slice doc (it's not a wave slice). The root-cause diagnosis is consistent with the persistent CI red baseline observed across the wave. CLAUDE.md does not encode CI-billing policy — this is operator-infrastructure territory.

## Findings

One **non-blocking observation**: required-status-checks on branch protection rules may need to drop the Apple workflow. Operator should verify.

## Status

Awaiting operator approval. If approved, merging on its own is straightforward (no ledger update needed — this is not a wave slice).
