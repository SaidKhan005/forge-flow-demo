# PR #533 Audit — A3.1 Monolith Seam-Map + Bleed-Stop Lint

**Slice:** A3.1 (Lane A — code health)
**Owner:** Claude lane executor
**Branch:** `claude/a3-1-monolith-seam-map-bleed-stop-lint`
**Base:** `master` (rebased onto current `origin/master` by orchestrator; see "Conflict resolution" below)
**Gate:** `operator` per ledger (proxy-adjacent CI policy + bleed-stop ceiling is a long-term doctrine)
**Size:** 482 additions / 2 deletions / 4 files
**Chunking:** light variant (small surface, single commit, read-only inspection of monolith)
**Dependency:** A0 merged ✓

## Pattern B compliance

PR body contains the 14-lens self-audit (key verdicts inline; full table referenced from worker report). Lens N/A markers carry rationale for each non-applicable lens (1, 2, 3, 4, 6, 7, 8, 9, 11, 13). Acceptable Pattern B compliance.

## Verdict

**approve-pending-operator** — escalating to operator per Gate=operator. Audit is clean; gate is the proxy-adjacent CI policy and long-term bleed-stop doctrine commitment.

## Orchestrator pre-merge conflict resolution (NEW)

Worker's PR opened cleanly but conflicted on `.github/workflows/ci.yml` because PR #527 (A5+A8) merged after the worker's last rebase and renamed the lint-chain step from `"... / migration-cutoff / ..."` → `"... / migration / ..."` AND inserted the two new A5+A8 lint commands.

**Resolution (orchestrator-fix-by-default doctrine):** rebased the PR's single commit onto current `origin/master` and resolved the step-name conflict by taking A5+A8's canonical naming (drop "migration-cutoff", use "migration") + appending A3.1's `/ advisor-proxy-size lints` suffix. The body's lint chain merged automatically — both A5+A8's two new commands AND A3.1's `dart run tool/advisor_proxy_size_lint.dart` are present in the resolved file. Force-pushed with `--force-with-lease`. PR is now MERGEABLE/CLEAN.

The orchestrator's resolution is a **pure conflict-resolution edit** with no semantic change to the worker's intent. The new step name `"postgres-import / index-leading-column / permission-key / migration / release-dart-defines / actions-pinning / advisor-proxy-size lints"` is the natural composition of both PRs' changes.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **`tool/advisor_proxy/advisor_proxy.dart` itself NOT in diff** (read-only inspection per slice scope) | ✓ — `gh pr diff --name-only` returns only the 4 NEW/append files; the monolith is untouched |
| **Lint runs cleanly on current master state** | ✓ — `dart run tool/advisor_proxy_size_lint.dart` returns: `tool/advisor_proxy/advisor_proxy.dart 18871 lines (ceiling 19071, headroom 200). clean — monolith is within the bleed-stop ceiling.` — exact match to PR body's claim |
| **Ceiling math: current (18,871) + headroom (200) = ceiling (19,071)** | ✓ — `kAdvisorProxyMaxLines = 19071` at `tool/advisor_proxy_size_lint.dart:72`; current monolith is 18,871 lines per `wc -l`; difference = 200 ✓ |
| **Seam-map cluster 9 boundary (line 8512 — `routeRequest` mega-function)** | ✓ — `grep -n '^Future<void> routeRequest'` returns exactly `8512:Future<void> routeRequest(`. Exact match to seam map's Cluster 9 range start |
| **A11.1 gauge (line 6969) sits within Cluster 7 range (6516-7060)** | ✓ — `SessionRecordIncompleteGauge` at line 6969 is within Cluster 7's "Auth lockout + A11.1 session-record-gauge" cluster, exactly as documented. Confirms the seam map was refreshed against post-A11.1 master (worker's claim of mid-slice rebase handling) |
| **Lint testability** — `AdvisorProxySizeLintRunner` exposes a synthetic-input façade for unit tests | ✓ — verified via source read; the runner accepts in-memory `(fileText, ceiling)` so future unit tests can drive both pass and fail cases without touching the real monolith |
| **Worker's fail-case demonstration**: 250-line placeholder added, lint exits 1 with remediation message, placeholder reverted, blob SHA unchanged | ✓ — disclosed in PR body verification block; reproduced behavior matches the design |
| **CI wiring** | ✓ — `.github/workflows/ci.yml` now chains `dart run tool/advisor_proxy_size_lint.dart` after the existing 7 lints in the `repo-lints` job |
| **Seam map docs cross-reference the existing 25-step decomp plan** | ✓ — `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` cites `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` at header + per-cluster "Future extraction target → Decomp Step N" rows + dedicated cluster→step cross-reference section |
| **`docs/phases/proxy_split/proxy_split_plan.md`** got a +45 append (not replacement) linking back to both seam map and decomp doc | ✓ — diff shows pure append |
| **No tracker / ledger / index touch** | ✓ — diff scope confirms |
| **No `dart analyze` issues on the new tool file** | ✓ — disclosed in PR body |

## Honesty observations (POSITIVE)

1. **Mid-slice base drift handled correctly**: Worker disclosed that master advanced FIVE times during execution (PRs #522, #525, #526, #527, #529). Worker rebased twice. After A11.1 (PR #522) added 131 lines to the monolith mid-slice, worker caught it and updated the lint constant + seam map + plan doc to reflect 18,740 → 18,871, ceiling 18,940 → 19,071. Preserved the 200-line headroom contract. One amend used (clearly disclosed). Then the orchestrator did a SIXTH rebase for the A5+A8 conflict — also clean.

2. **Canonical-hook installer pattern**: Worker disclosed running `pwsh scripts/install_git_hooks.ps1`. Same pattern as A2.1 / A4.1 / A7.1 / A10.1 workers this wave — install the canonical lightweight hook rather than bypass with `--no-verify`.

3. **Read-only discipline**: Worker explicitly designed the slice to NOT touch the monolith. The verification block confirms via "verified the monolith content blob is unchanged (sha `f8965f7c1ef91c0e862f4e48c81e8fe9c92d6ff4`)" — the blob SHA verification step is a strong honesty signal.

## Operator-decision rationale (why this needs operator sign-off)

Per CLAUDE.md "Agent-Led Slices" durable rule:
> *"Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict."*

A3.1 does NOT touch the proxy code itself (read-only inspection only). But:

1. **CI-enforced ceiling on the proxy monolith** is a long-term doctrine commitment. The 200-line headroom + ratchet rule will shape every subsequent proxy contribution. Operator should sign off on the 200-line headroom and the rule that decomposition slices must drop the ceiling.

2. **Bleed-stop policy is a doctrine, not a code change**. The lint will block future PRs that grow the monolith. Operator should confirm this is acceptable — there's a real chance Codex or future executors hit the ceiling mid-slice and need to extract before continuing.

3. **Seam map is the canonical reference for the future proxy-split phase**. Operator should confirm the 12-cluster boundaries match the architecture intent before the decomp work consumes this map.

## Recommendation

**approve-for-merge.** Execution is excellent:
- Read-only inspection of the monolith (blob SHA verified unchanged)
- 12-cluster seam map with file:line ranges that spot-check correctly (`routeRequest` @ line 8512, A11.1 gauge @ line 6969 within Cluster 7)
- Bleed-stop lint with sane 200-line headroom contract
- CI wiring is additive, single-line append to the existing chain
- Testable façade (`AdvisorProxySizeLintRunner`) enables future unit coverage
- Worker's mid-slice rebase handling and orchestrator's post-rebase conflict resolution both clean

If approved, I will merge + update the ledger (A3.1 → merged). **This unblocks A3.2 (bare-catch tail chunk 1 of 3)** per the ledger dependency column.

## Authority anchors verified

- `docs/_execution/lane_a_code_health/03_execution_slices.md` "Slice A3.1 — Monolith Seam-Map + Bleed-Stop Lint" (scope matches diff)
- `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` (existing 25-step decomp plan; the new seam map cross-references it)
- `CLAUDE.md` HP #4 (RLS-ready) + Build Toward Production doctrine

## Findings

None blocking. Three positive observations (mid-slice rebase honesty, canonical hooks, blob-SHA-verified read-only discipline). One orchestrator-applied conflict resolution (mechanical, no semantic change).

## Status

Awaiting operator approval. Will merge + update ledger on go-ahead.
