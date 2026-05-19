# Repo Cleanup V1 — Phase 0: Quiesce Triage

**Date:** 2026-05-16
**Owner:** Orchestrator (main chat)
**Purpose:** Read-only classification of all worktrees + open PRs so the tree can
be drained to a stable, frozen `master` before the full doc-alignment program
(Phases 1–5). No destructive action taken in this phase.

Authority: CLAUDE.md "Workflow" (orchestrator drains between batches; main chat
read-only across worktrees while they run) + "Commits & Push" + Ceiling/auth
gating rules. Decisions answered by operator 2026-05-16: **quiesce first**,
tiered-by-authority depth, conservative archive bar, phased PRs.

## Inventory

- **179 worktrees** total (`.claude/worktrees/**`, `.codex/worktrees/**`, loose dirs).
- `origin/master` @ `d38692ae` at triage time (moved 3× during a 5-file push — high churn).
- Raw data: `quiesce_triage_raw.tsv` (this dir).

| Bucket | Count | Disposition |
|---|---|---|
| MERGED_OR_DEAD (HEAD is ancestor of origin/master) | 140 | **Safe prune** — zero unmerged content |
| UNMERGED but SQUASH-MERGED (content on master via a merged PR) | 31 | **Safe prune** — branch tip orphaned by squash, no value lost |
| Redundant siblings of merged PRs | 4 | **Safe prune** after 1-line verify |
| Dirty-WIP, generated artifacts only | 6 | **Safe prune** — `windows/flutter/generated_*`, `.gitignore`, soak doc |
| Open PRs | 4 | **Audit → merge or close** (one gated) |
| Genuine unmerged code (no PR) | 3 | **Salvage-assess** (two gated) |
| Findings/walkthrough branch | 1 | **Capture-as-doc assess** (`mobile-lane-pass-1`) |
| Dirty-WIP, real source file | 2 | **Glance before prune** |

Net: **~171 of 179 worktrees prune safely with zero value loss.** Real decisions
collapse to **4 PRs + 6 branches/files**.

## A. Open PRs (audit → merge or close)

| PR | Branch | Title | Mergeable | Gate |
|---|---|---|---|---|
| #845 | claude/cross-surface-parity-audit-docs | cross-surface parity audit register + fix specs | MERGEABLE | docs-only |
| #844 | claude/fix-demo-open-shift-clock-weekend-lunch | demo open-shift restaurant-local clock + weekend Lunch | UNKNOWN | demo writer-side |
| #832 | claude/fix-operator-web-live-onboarding-g24 | live operator-web onboarding custom-token + MFA (G24/G3) | UNKNOWN | **AUTH-CRITICAL — operator approval** |
| #825 | claude/demo-vendor-applicability-realistic-seed | realistic vendor_applicability seed | MERGEABLE | demo writer-side |

## B. Genuine unmerged code, no PR (salvage-assess)

| Branch | Ahead | Content | Gate / call |
|---|---|---|---|
| claude/gap-b2-wage-role-rows-hierarchy-scope | 1 | GAP B2 hierarchy scope for `wage_role_rows` (HP#11 wage slice) | **SCHEMA — operator approval** |
| codex/b6-benchmark-overrides | 1 | B6 benchmark overrides hierarchy (dup worktree `forge_flow_demo_b6_benchmark_overrides` same SHA) | salvage-assess |
| claude/admin-auth-session-ledger-parity | 2 | G5 release-mode fail-closed guard + G1+G2 auth-session ledger parity | **AUTH — likely redundant** (PR#831 merged; content verified byte-identical on master earlier) — verify then prune |

## C. Findings/walkthrough branch (capture-as-doc)

- **claude/mobile-lane-pass-1** — 12 genuine commits, no PR. Content = mobile
  cold-boot Pass 1/2 walkthrough findings + matrix updates referencing already-merged
  PRs #755/756/757. Per CLAUDE.md the mobile lane "closed for walkthrough 2026-05-15
  (transitioned to Per-Daypart Targets V1 plan)". Likely the *findings* are the only
  unmerged value and may already be captured in the per-daypart V1 plan. **Operator
  call:** confirm findings are captured → prune; else salvage findings into a single
  archived doc (no code merge).

## D. Dirty-WIP with real source edits (glance before prune)

| Worktree | Branch (state) | Uncommitted | Note |
|---|---|---|---|
| agent-a8255bc01c8f236b8 | claude/demo-seed-completeness (MERGED) | `M lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` | branch already on master; likely stray |
| agent-a9e0a8f747a6bd0c5 | claude/b2-1-idempotency-replay-fix (MERGED) | `M tool/advisor_proxy/advisor_proxy.dart` | **PROXY-touching** — glance, likely stray |

Other 6 dirty worktrees: only `windows/flutter/generated_plugin_registrant.{cc,h}`,
`generated_plugins.cmake`, `.gitignore`, or one soak-harness doc edit — build
artifacts, discard.

## Recommended drain order (requires operator authorization — destructive + gated)

1. **Glance D** (2 files) — confirm stray, discard.
2. **Audit + merge** PRs #845, #844, #825 (docs/demo, ungated). Hold #832 for explicit auth approval.
3. **Salvage-assess B + C** — confirm `admin-auth-session-ledger-parity` redundant; decide `gap-b2` (schema-gated) and `b6-benchmark-overrides` salvage-or-drop; capture/confirm `mobile-lane-pass-1` findings.
4. **Prune** the ~171 safe worktrees (`git worktree remove` + branch delete for merged/squash-merged/redundant).
5. Re-fetch, confirm `origin/master` stable, **freeze** → enter Phase 1.

**No step 1–5 action will be taken without explicit operator authorization per
bucket.** Auth (#832, admin-auth-session), schema (gap-b2), and proxy (advisor_proxy
glance) items remain individually gated regardless of audit verdict.
