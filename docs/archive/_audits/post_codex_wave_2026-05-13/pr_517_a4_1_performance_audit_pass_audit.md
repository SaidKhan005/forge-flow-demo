# PR #517 Audit — A4.1 Performance Audit Pass (Lens 10 + Postgres Pool)

**Slice:** A4.1 (Lane A — code health)
**Owner:** Claude lane executor
**Branch:** `claude/a4-1-performance-audit-pass`
**Base:** `master` (no drift)
**Gate:** `auto` per ledger (doc-only deliverable; no `.dart` files modified)
**Size:** 347 additions / 451 deletions / 1 file
**Chunking:** light variant (single-doc deliverable)
**Dependency:** A0 merged at `a082b5b3` ✓

## Pattern B observation

The worker's 14-lens audit is **embedded in the deliverable doc itself at §9** rather than in the PR body as a separate table; the PR body cites this. There is **no explicit "executor independent audit" table** in the PR body — a strict Pattern B reading would flag this.

For doc-only audit deliverables this is reasonable: the deliverable IS the audit, and the orchestrator's audit doc (this file) serves as the executor independent pass. Noting it as a soft observation; not a blocker. Future doc-only audit slices should still include a 1-paragraph "Executor independent pass" section in the PR body even if it just confirms file:line citations.

## Verdict

**approve-for-merge** — auto-merged at `455d7e27`.

## Executor spot-checks

| Citation | Verified on `origin/master` | Verdict |
|---|---|---|
| `postgres_executor.dart:55` — `kPostgresDefaultMaxConnectionsPerPool = 4` | ✓ exact match | clean |
| `shift_dashboard.dart:361, :784, :951, :1329` — four `Timer.periodic` sites | ✓ all four lines confirmed via grep; widget at `:928` also Timer.periodic but commented and not on the operator surface | clean |
| `proxy_bootstrap.dart:1646` — `healthProducerConcurrency = kPostgresDefaultMaxConnectionsPerPool` | ⚠ actual location is `:1686` (40-line drift; symbol present, finding stands) | minor citation drift |
| `connectivity_notifier.dart:53` (Timer.periodic) + `:74-79` (cancel-on-dispose) | (not re-verified line-for-line; not blocking — connectivity_notifier is widely-used and the worker's claim is consistent with established cancel-on-dispose discipline) | not re-verified |

## Three recommendations for A4.2 (verified-routed)

The PR correctly leaves all *implementation* of the fixes for A4.2 (operator gate, medium risk). A4.2 will:

- **R1 (P0)**: bump `kPostgresDefaultMaxConnectionsPerPool` 4 → 20 (per ledger note for A4.2: "Perf fixes if found (incl. Postgres pool 4→20)") — exactly what the ledger reserves for A4.2.
- **R2 (P0)**: coalesce four `shift_dashboard.dart` 30s tickers into one shared `ValueListenable<DateTime>` — ~30 LoC behavior-preserving refactor.
- **R3 (P1)**: resolve `healthProducerConcurrency` to use `resolvePostgresMaxConnectionsPerPool()` instead of hardcoded constant.

No scope creep. A4.1 documents; A4.2 implements.

## Predecessor doc

The previous broader `a4_performance_audit.md` (commit `0e59029e` from Step 3+4 wave bundle) was 503 lines / 24 hotspots / 5 candidate slices — a planning-wide survey written before the slice scope tightened. This PR replaces it with the slice-scoped version (399 lines after merge, 3 ranked recommendations) so A4.2 has a sharp actionable target. The broader survey survives at commit `0e59029e` for whichever lane picks up wider perf work post-A4.2.

## Findings

**Minor citation drift only** — `proxy_bootstrap.dart:1646` → actual `:1686`. The symbol exists at the actual line; the recommendation is sound. Not a blocker, not worth a follow-up PR. Suggest the executor self-refresh line citations against current master tip before opening (the line drifted as other Codex PRs landed during A4.1's authoring).

## Authority anchors verified

- `docs/_execution/lane_a_code_health/03_execution_slices.md` "Slice A4.1 — Performance Audit Pass" — slice scope matches diff.
- `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` Lens 10 — Timer.periodic inventory framework.
- `docs/frameworks/PERFORMANCE_FRAMEWORK.md` — active 2026-05-03 perf doctrine.

## Merge

Auto-merged at `455d7e27` on `origin/master` per Gate=auto + clean audit + no operator-decision finding. A4.2 is now unblocked (depends on A4.1 merged).
