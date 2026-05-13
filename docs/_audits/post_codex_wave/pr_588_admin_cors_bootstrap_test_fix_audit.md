# PR #588 Audit — admin_cors_bootstrap_test Sentinel-UUID Snapshot Fix

**Slice:** Housekeeping (not a ledger row — closes the deferral noted in Bundle 33's change-log entry)
**Owner:** Claude lane sub-agent (delegated from orchestrator)
**Branch:** `claude/admin-cors-bootstrap-test-fix`
**Base:** `master`
**Gate:** `auto` — pure test snapshot adjustment, no auth/RLS/schema/proxy semantic change
**Risk:** **Zero** — source-grep test only; production code unchanged
**Size:** 1 file / +16 / −3

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Pure test-side drift mirroring the live production SQL contract. Production code, RLS policies, migrations, and authority docs are all untouched and remain canonical.

## Background — why this audit doc exists

`docs/_audits/post_codex_wave/orchestrator_bundle_33_b10_1_fallout.md` (Bundle 33 change-log entry) deferred the `admin_cors_bootstrap_test.dart` failures as "5 pre-existing failures needing separate investigation." After Bundle 35 merged, the orchestrator spawned a background investigation agent (task `a2d2f5ac88d28ae26`) which produced two key findings:

1. **The "5 failures" framing was wrong.** Only **one** test case fails (`FeatureFlagsTableAdminCorsOriginsExtraFlag — query shape`). The "5" referred to five stacked `expect()` calls inside that single test; the first failing `expect` halts the test, so the four siblings never execute — they're not additional failures.

2. **Root cause is NOT B10.1.** The failure has existed on master since commit **`0dde9314`** (2026-05-07) — six days before B10.1 landed. That commit (`fix(code-health.ff-policy-fold): feature_flags sentinel operator_id`) intentionally rewrote the CORS feature-flag SQL from `operator_id IS NULL` to `operator_id = public.feature_flag_system_wide_operator_id()` per `phase_9_scalability_decisions_2026-04-27.md` item 4 (RLS predicates must fold into the operator-leading partial unique index). The companion migration is `db/migrations/202605072000_feature_flags_sentinel_operator.sql`. The source-grep snapshot in this test never got updated to mirror the new shape. PR #581 (A3.4)'s worker happened to re-run this test surface and surfaced the failure; prior PRs that didn't touch this surface never re-ran it.

This PR applies the trivial 1-line snapshot fix.

## What landed

**Single file:** `test/proxy/admin_cors_bootstrap_test.dart`

- Line 160 (old): `expect(source, contains('and operator_id is null'));`
- Line 160 (new): `expect(source, contains('and operator_id = public.feature_flag_system_wide_operator_id()'));`
- Inline comment (lines ~155–165): rewritten to cite commit `0dde9314`, migration `202605072000_feature_flags_sentinel_operator.sql`, and phase 9 scalability decisions item 4 (operator-leading partial unique index `feature_flags_operator_scope_idx`). Original intent preserved — "Global scope only — no operator/location-scoped row bleeds into the platform allow-list."

**No other file touched.** Diff scope verified.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ — `baseRefName: master`, mergeable, CLEAN |
| Single-file scope | ✓ — `gh pr view --json files` returns one entry |
| Production SQL on master matches the new test substring | ✓ — `git show origin/master:tool/advisor_proxy/proxy_bootstrap.dart` line 8798 contains `'and operator_id = public.feature_flag_system_wide_operator_id() '` |
| Migration `202605072000_feature_flags_sentinel_operator.sql` exists on master with the cited rationale | ✓ — header references operator-leading partial unique index foldability + sentinel UUID `00000000-0000-0000-0000-000000000000` |
| No production code modification | ✓ — diff is test file only |
| No migration / RLS policy modification | ✓ — diff scope confirms |
| Authority cite in test comment matches reality | ✓ — references commit `0dde9314`, the migration filename verbatim, and phase 9 scalability decisions item 4 |
| Hook discipline | ✓ — worker installed canonical hooks first (`scripts/install_git_hooks.ps1`); pre-commit + pre-push (`postgres_import_lint`) both clean |
| No `--no-verify` traces | ✓ |
| `flutter test test/proxy/admin_cors_bootstrap_test.dart` pre-fix | `+21 -1` (the expected failing test confirmed) |
| `flutter test test/proxy/admin_cors_bootstrap_test.dart` post-fix | `+22 -0` |
| `dart analyze --fatal-infos test/proxy/admin_cors_bootstrap_test.dart` | clean |

## Pattern B compliance

**✓ lightweight** — PR body carries the worker self-audit table (8 lenses focused on snapshot correctness + authority cite + no-regression risk + production-code-untouched). Executor lens table is not required for a pure source-grep snapshot fix per audit chunking playbook ("light variant" applies when <20 files and no semantic surface change).

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration changes |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — this fix closes the explicit Bundle 33 deferral |
| Worker disclosure operator should know | ❌ — worker fully transparent; investigation agent corrected the "5 failures" misframing before the work started |
| Stacked PR | ❌ — base is master |

## Cross-lane notes

- **Closes the Bundle 33 deferral** ("`admin_cors_bootstrap_test.dart` 5 pre-existing failures needing separate investigation"). The real number was 1 failure / 1 stale snapshot.
- **Production-side sentinel-UUID contract on master is unchanged and remains canonical** per phase 9 scalability decisions item 4. The test now mirrors it.
- **No interaction with current in-flight slices** (B2.2, B6, B8, B10.2, C-4, C-7) — they don't touch the CORS feature-flag surface.

## Findings

None blocking. The fix is the minimum-viable change to align the test snapshot with the live production contract.

## Authority anchors

- `db/migrations/202605072000_feature_flags_sentinel_operator.sql` — the migration that introduced the sentinel UUID pattern
- Commit `0dde9314` — `fix(code-health.ff-policy-fold): feature_flags sentinel operator_id`
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md` item 4 — RLS predicates must fold into operator-leading indexes
- `docs/_audits/post_codex_wave/orchestrator_bundle_33_b10_1_fallout.md` — Bundle 33 change-log entry that explicitly deferred this fix

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. Bundle 36 change-log entry records the merge + the corrected "1 failure (was misframed as 5)" finding.
