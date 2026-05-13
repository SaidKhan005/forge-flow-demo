# PR #523 Audit — A10.1 Test Consolidation Pass (`test/load/pressure/` → `test/pressure/`)

**Slice:** A10.1 (Lane A — code health)
**Owner:** Claude lane executor
**Branch:** `claude/a10-1-test-consolidation-pass`
**Base:** `master` (no drift; rebased onto current `origin/master`)
**Gate:** `auto` per ledger
**Size:** 60 additions / 48 deletions / 20 files / 108 diff lines (mostly `git mv`)
**Chunking:** light variant (test-only refactor, no `lib/**` touch)
**Dependency:** A0 merged ✓

## Pattern B compliance

Both audit tables present in worker report (referenced from PR body); test/tooling-only refactor with 9/14 lenses marked N/A appropriately.

## Verdict

**approve-for-merge** — auto-merging per Gate=auto + clean audit + no operator-decision finding.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Dropped-entry verification: was `test/settings_permission_explainer_test.dart` actually deleted in `22db522a`? | ✓ — `git show 22db522a --stat` confirms 784-line deletion in W3.A dead-code sweep (PR #324, 2026-05-07). File no longer exists on master (Glob returns empty). Drop decision is correct. |
| 9 `git mv` renames preserve similarity 81–100% | ✓ — diff output reports `similarity index 81%`, 98%, 99%, 100% across the moves; blame chains will survive |
| Import path fix in `p3b_backfill_flood_runner_test.dart` | ✓ — `'../../../tool/pressure/p3b_backfill_flood.dart'` (from `test/load/pressure/`, 3 levels up) → `'../../tool/pressure/p3b_backfill_flood.dart'` (from `test/pressure/`, 2 levels up); math is correct |
| `kOutputDir` const in `p3a_webhook_flood_runner_test.dart` updated | ✓ — `'test/load/pressure'` → `'test/pressure'` |
| `.gitignore` retargeted for per-run findings JSONL / summary MD / raw JSONL | ✓ — three lines flipped at the bottom of the file |
| Comment-only refs in unrelated tests/tools | ✓ — `connector_backfill_job_repository_test.dart` (3 sites), `oauth_refresh_worker/main.dart`, `test/integration/pressure/README.md` (1 site each) |
| New `KNOWN_FAILING_TESTS.md` entry is pre-existing (NOT PR-introduced) | ✓ — worker explicitly states "Both reproduced verbatim against `origin/master` BEFORE the consolidation began" and `flutter test` reports 24/26 pass with the 2 expected failures. Closure-registry drift between `buildProductionRefreshClosures` (12 vendors) vs the assertions (10 vendors expected) is a known reconciliation problem, not a regression A10.1 introduced. |
| No helper duplication consolidation needed | ✓ — worker correctly identified `test/_helpers/migration_lf.dart` as unrelated (SQL CRLF normalization, not pressure-related); left alone |
| No `lib/**` files touched | ✓ — diff shows zero `lib/` paths |
| No trackers/ledger/indices touched | ✓ — only `docs/KNOWN_FAILING_TESTS.md` (test-discipline doc, not slice authority) + the two READMEs |

## Authority anchors verified

- `docs/_execution/lane_a_code_health/03_execution_slices.md` — "Slice A10.1 — Test Consolidation Pass" scope matches diff
- `docs/KNOWN_FAILING_TESTS.md` — file's own discipline ("Removed entries live in git history; do not keep a 'resolved' section here") honored by dropping the explainer entry outright

## Honesty observation (POSITIVE)

Worker disclosed in PR body that `core.hooksPath` was pointing at a stale heavy `dart analyze` hook, blocking the commit. Resolution: **re-ran `pwsh scripts/install_git_hooks.ps1` to repoint to the canonical lightweight `.githooks/`, then committed without `--no-verify`.** Same pattern as the A2.1 / A4.1 worker disclosures earlier this wave — install the canonical hook rather than bypass.

Worker also disclosed two pre-existing test failures discovered during verification (lines 253 + 322 in `p3c_oauth_refresh_storm_runner_test.dart`) and added them to `KNOWN_FAILING_TESTS.md` with full rationale rather than silently leaving them or attempting a scope-creep fix. Exactly the right move under the "Slice == A10.1 scope, not closure-registry repair" boundary.

## Authority-leftover footnote (NOT blocking)

Worker explicitly flagged a doc-hygiene followup: `docs/_audits/code_health/a11_soak_harness_durable_kit.md` (~10 refs), `a0_b1_b2_post_merge_verification.md` (1 ref), and `docs/_execution/b1_b2_proxy_soak_fix/01_execution_slice.md` (1 ref) still cite `test/load/pressure/` paths. Worker correctly left them alone because the slice forbids tracker/ledger/index touches. These docs are historical/planning records, so the stale references are not surfaced to runtime — a future doc-hygiene sweep slice can address.

## Findings

None.

## Merge

Auto-merging now per Gate=auto + clean audit. Will record the merge commit SHA in the change log entry below.
