# PR #610 Audit — test/proxy Stale-Snapshot Fix (B1 super_admin contract + A3.3 typed catch)

**Slice:** Housekeeping (not a ledger row — closes 2 stale-snapshot failures surfaced by the post-Codex wave closeout deep audit)
**Owner:** Claude lane sub-agent (delegated from orchestrator)
**Branch:** `claude/test-proxy-stale-snapshot-fix-2026-05-13`
**Base:** `master` @ `0a6311cb`
**Gate:** `auto` — pure test-fake snapshot catch-up, no auth/RLS/schema/proxy semantic change
**Risk:** **Zero** — test files only + audit doc; production code untouched
**Size:** 3 files / +62 / -3

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Same shape as PR #588 (admin_cors_bootstrap_test) and PR #604 (b11_2_b step-up wiring). Two test fakes drifted behind two intentional production-contract tightenings; the fix is the minimum-viable snapshot catch-up. Production code on master is correct and unchanged.

## Background — investigation chain

1. **PR #603 (B2.3 blast-radius) full-sweep run** disclosed 5 "test failures in `test/proxy/`" — flagged as closeout-phase investigation candidate.
2. **Investigation agent (`d4e8…`)** diagnosed: the headline of "5 failures" was inflated (test files counted, not cases). Real picture: 2 stale snapshots across 3 test cases in 2 files, plus 1 same-class out-of-scope failure for a separate seam.
3. **This PR (#610, delegated to sub-agent)** applies the test-only fix. Production code in `tool/advisor_proxy/advisor_proxy.dart` is correct by design and remains untouched on master.

## Root causes

### Fix 1 — `test/proxy/audit_chain_anchors_routes_test.dart:216`

**Test:** "rejects a token without operator scope with 403"

**Production root cause:** B1 sign-in contract commit `c3f1ce0d` (2026-05-12) intentionally aligned `requireOperatorContext` so `super_admin` / `ff_support` sessions are NOT refused with 403 when `operator_id` is intentionally absent. That is now a contract-correct **acceptance** branch.

**Fix:** Switch the test's role from `super_admin` → `operator_owner`. `operator_owner` without operator scope IS genuinely unauthorized, so the test continues to exercise the reject-path; only the role label changes. The 403 assertion stays. **Reject-path coverage preserved exactly.**

### Fix 2 — `test/proxy/registry_proxy_health_check_store_test.dart:217` and `:239`

**Tests:**
- "AGE thrown error projects ageOk → false"
- "pgvector distance error projects pgvectorOk → false"

**Production root cause:** A3.3 commit `bb88f82b` (2026-05-13 02:03 UTC) narrowed the catch site at `tool/advisor_proxy/advisor_proxy.dart:5605` from `catch (_)` to `on Exception catch (_)`. Inline rationale on master: "Narrowed to `Exception` so genuine `Error`s (assertion failures, OOM, type errors) keep propagating instead of being silently masked behind a green health envelope." `StateError extends Error` (not `Exception`), so it escapes uncaught — contract-correct for production.

**Fix:** Change `StateError(...)` → `Exception(...)` at both line 217 and line 239. Test intent (exercise the swallow-and-project-false path) requires an `Exception` subtype post-A3.3.

## What landed

**3 files / +62 / -3:**

- `test/proxy/audit_chain_anchors_routes_test.dart` (+5 / -1) — role switch + inline rationale comment citing `c3f1ce0d`
- `test/proxy/registry_proxy_health_check_store_test.dart` (+10 / -2) — two `StateError` → `Exception` swaps + inline rationale comments citing `bb88f82b`
- `docs/_audits/post_codex_wave/test_proxy_5_failures_investigation.md` (+47 / -0, NEW) — investigation report the agent had to author in this PR because the brief referenced it but the file did not exist on master

Production code in `tool/advisor_proxy/auth_step_up_*`, `advisor_proxy.dart`, and any `lib/**` remains untouched.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `0a6311cb` | ✓ — `gh pr view` confirms `baseRefName: master`, `mergeable: MERGEABLE`, `mergeStateStatus: CLEAN` |
| Production root cause verified on master | ✓ — `tool/advisor_proxy/advisor_proxy.dart:5605` shows `} on Exception catch (_) {` (independent Grep) |
| Test-only scope | ✓ — `gh pr view --json files` shows 2 test files + 1 audit doc. Zero `lib/**`, `tool/**`, `db/**` touched |
| Fix 1 — role label swap, assertion unchanged | ✓ — diff at `audit_chain_anchors_routes_test.dart:216-220` confirms `super_admin` → `operator_owner`; 403 assertion preserved |
| Fix 2 — both `StateError(...)` → `Exception(...)` sites swapped | ✓ — diff at lines 217 and 239 confirms both swaps with cited rationale |
| Authority anchors in PR body | ✓ — investigation report path + PR #588 + PR #604 + B1 commit `c3f1ce0d` + A3.3 commit `bb88f82b` all cited |
| Inline comments cite root-cause commits | ✓ — both test files carry `// B1 sign-in contract (c3f1ce0d, 2026-05-12)` / `// A3.3 (bb88f82b) narrowed catch site...` inline |
| Worker self-audit Pattern B 8-lens table present | ✓ — PR body carries the table with file:line citations |
| Pre-fix sweep reproduced on master pre-fix | ✓ — worker disclosed `git stash` + re-run on `0a6311cb` to confirm pre-fix state |
| Targeted tests pass post-fix | ✓ — `+9 -0` on audit_chain_anchors, `+15 -0` on registry_proxy_health_check_store, combined `+24 -0` vs master `+21 -3` |
| Two-file delta = +3 cases recovered, 0 regressions | ✓ — disclosed |
| Hook discipline | ✓ — worker installed canonical hooks first; no `--no-verify` traces |
| `dart analyze --fatal-infos` clean on touched files | ✓ disclosed ("No issues found!") |
| No tracker / ledger / lane-index touches | ✓ — `gh pr view --json files` confirms no `PROJECT_TRACKER.md`, `WAVE_EXECUTION_LEDGER.md`, `POST_HARDENING_FOLLOWUPS.md`, `KNOWN_FAILING_TESTS.md` |
| No Codex-owned conflict | ✓ — Claude lane test-fake fix territory; no Codex slice owns these files |

## Pattern B compliance

**✓ lightweight** — PR body carries the worker self-audit table (8 lenses focused on snapshot correctness + authority cites + production-code-untouched + no-regression). Executor lens table is not required for a pure test-fake fix per audit chunking playbook ("light variant" applies when <20 files and no semantic surface change). Same shape as PR #588 and PR #604.

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — housekeeping (not a ledger row); closes the cross-PR-#603 finding |
| Worker disclosure operator should know | ⚠ TWO non-blocking disclosures: **(a)** investigation report was authored in this PR (didn't exist on master) — minor brief deviation, reviewed and reasonable (the report needs to be on master to anchor the diff). **(b)** Same-class failure at `test/proxy/auth_location_integrations_route_test.dart:476` reproduces on master (verified by worker via `git stash` + re-run) — same A3.3 root cause, different seam. **Out of scope per brief**, filed for separate orchestrator follow-up. Both are forward-looking transparency, not regressions. |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. Test-only diff with two well-bounded fixes mirroring PR #588 + PR #604 playbook exactly. Production is contract-correct; tests catch up.

## Cross-lane notes

- **Closes 2 of 5** "test/proxy/ failures" disclosed by PR #603's full sweep. The other 3 in the original "5" were not actually failing on master HEAD — investigation report documents this Bundle-33-style inflation pattern (count failing CASES, not files).
- **One residual same-class failure** at `test/proxy/auth_location_integrations_route_test.dart:476` — same A3.3 root cause, different production seam (`integrations_projection_unavailable` 503 path). Flagged for a separate orchestrator follow-up; same one-line fix shape (`StateError('boom')` → `Exception('boom')`).
- **Doctrine signals** for closeout retro:
  - "Count failing test CASES, not files" — fold into audit-disclosure standard
  - "A3.3 verification command list omitted `registry_proxy_health_check_store_test.dart`" — A3.4 checklist should include every test that hits touched catch sites

## Findings

None blocking. Two honest disclosures are forward-looking transparency, not slice defects. The fix is the minimum-viable change to align two test fakes with two intentional production contract tightenings.

## Authority anchors

- Investigation report at `docs/_audits/post_codex_wave/test_proxy_5_failures_investigation.md` (added in this PR)
- PR #588 (`pr_588_admin_cors_bootstrap_test_fix_audit.md`) — precedent for orchestrator delegating test-only fixes to a sub-agent
- PR #604 (`pr_604_b11_2_b_test_fake_clock_fix_audit.md`) — same-shape precedent (test fake using real-clock instead of injected clock)
- B1 sign-in commit `c3f1ce0d` (`fix(proxy): runZonedGuarded + sign-in contract + soak harness (B1+B2)`, 2026-05-12) — production root cause for Fix 1
- A3.3 commit `bb88f82b` (`refactor(proxy): bare-catch typing chunk 2/3 in advisor_proxy.dart (A3.3)`, 2026-05-13) — production root cause for Fix 2
- `tool/advisor_proxy/advisor_proxy.dart:5605` — typed catch site with inline rationale comment

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. Residual same-class failure (`auth_location_integrations_route_test.dart:476`) tracked for separate orchestrator follow-up.
