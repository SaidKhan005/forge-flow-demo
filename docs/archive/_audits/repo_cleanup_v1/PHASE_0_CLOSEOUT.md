# Repo Cleanup V1 — Phase 0 Closeout (Quiesce)

**Date:** 2026-05-16
**Owner:** Orchestrator (main chat)
**Status:** Quiesce ~95% done, BUT a true freeze is **blocked** by an active
worktree spawner + a live auth-architecture conflict. Operator decision required
before Phase 1.

## What was done (all operator-authorized)

| Action | Result |
|---|---|
| Worktree prune | **179 → 4 real** (main + this session + gap-b2 parked + transient respawns). 175+ removed. |
| Branch refs | 463+ deleted (172 with worktrees + 291 merged orphan refs). 142 remain (~140 unmerged orphan refs flagged for separate triage — NOT bulk-deleted to avoid losing squash-orphan edge cases). |
| PR #845 (docs parity) | Audited approve-for-merge → **merged** |
| PR #844 (demo open-shift test reconcile) | Audited, not redundant (test-only other half of #843) → **merged** |
| PR #825 (vendor_applicability seed) | Audited stale-but-clean, HP#2-compliant → **merged** |
| PR #832 (live operator-web onboarding, AUTH) | Audited auth-sound w/ documented incomplete tail → **merged** per operator approval |
| mobile-lane-pass-1 findings | Salvaged (+150/-0 walkthrough verification append + new salvage doc) → **committed**, branch pruned |
| admin-auth-session-ledger-parity | Agent-confirmed fully redundant (landed via #831; merge would regress) → **pruned, not merged** |
| b6-benchmark-overrides ×2, demo-seed-completeness WIP, b2-1-idempotency WIP | Agent-confirmed superseded on master → **dropped, pruned** |

## Parked / tracked (operator decisions)

- **gap-b2-wage-role-rows-hierarchy-scope** — GENUINE unmerged HP#11 value
  (master has a `inheritedFromLabel: null` stub waiting for it; 8 files /
  ~1027 insertions incl. a new schema migration + resolver + 4 tests).
  Operator decision: **PARK as a tracked future slice.** Worktree
  `.claude/worktrees/agent-aa8f0545111eb6b7e` retained. Branch is behind its
  merge-base; needs rebase + re-audit + `migration_drift_scanner --fix
  --strict-docs` + `migration_cutoff_lint` + explicit schema merge approval
  when scheduled. **TODO: fold into `docs/_indices/NEXT_WAVE_PLAN.md` during
  Phase 1.**
- **#832 server-route follow-up** — live onboarding cannot complete in-app
  (no `/v1/auth/password` set-route or `/v1/auth/tos/*` route; fails closed
  with calm copy). Known disclosed BLOCKER. **TODO: track as a scoped slice
  in NEXT_WAVE_PLAN during Phase 1.**

## BLOCKERS to a true freeze (Phase 1 cannot safely start)

1. **Active worktree spawner.** During the quiesce, new worktrees appeared
   repeatedly: `eloquent-yonath-fec6f8`, `agent-ad4a4a9c083299962`
   (respawned after deletion), `g24-s3prime`. Master HEAD moved 5+ times
   (`d38692ae → fe73f94c → … → 9a7c736e → 79a6b6ab`). A doc-alignment pass
   against a moving master produces stale/wrong docs — exactly what
   "quiesce first" was chosen to avoid. **The operator must halt whatever is
   launching sessions/agents (other Claude sessions, a /loop, a ralph-loop,
   CI automation) for the freeze to hold.**
2. **Live auth-architecture conflict.** `g24-s3prime` branch commit
   `26ab349f` *"G24/G3 S3′: delete magic-link/custom-token surface;
   operator-web onboarding = Firebase reset-email + email/password sign-in"*
   directly **reverses** the just-merged #832 (which *added* custom-token
   magic-link onboarding). This is an unresolved product/architecture
   decision, not a cleanup item. Reconciling auth docs in Phase 1 is
   impossible until the operator picks the onboarding direction
   (#832 custom-token vs S3′ reset-email).

## Recommended next step

Do **not** start Phase 1 until: (a) the spawner is halted and a final clean
prune confirms a stable worktree set, and (b) the #832-vs-S3′ onboarding
direction is decided (and the loser reverted/closed so auth docs have a
single truth to align to).
