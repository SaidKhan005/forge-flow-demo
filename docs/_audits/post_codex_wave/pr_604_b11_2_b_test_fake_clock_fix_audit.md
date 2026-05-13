# PR #604 Audit — B11.2.b Test Fake Wall-Clock Leak Fix

**Slice:** Housekeeping (not a ledger row — closes the cross-lane finding escalated by C-5's worker in PR #600 / Bundle 42)
**Owner:** Claude lane sub-agent (delegated from orchestrator)
**Branch:** `claude/b11-2-b-test-fake-clock-fix`
**Base:** `master`
**Gate:** `auto` — pure test-fake fix, no auth/RLS/schema/proxy semantic change
**Risk:** **Zero** — test file only; production code untouched
**Size:** 1 file / +15 / -11

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Pure test-fake clock-injection fix mirroring the PR #588 pattern (admin_cors_bootstrap_test fix). Production code in `tool/advisor_proxy/auth_step_up_gate.dart` and `tool/advisor_proxy/auth_step_up_routes.dart` is correct and untouched. The failing test surfaced by Codex's C-5 worker (PR #600) was a wall-clock time bomb in the test fake, not a production regression.

## Background — investigation chain

1. **Codex's C-5 worker (PR #600) disclosed** a failing test at `test/proxy/b11_2_b_step_up_wiring_test.dart:175` while running the test suite during their own audit. Codex correctly respected cross-lane ownership and did NOT attempt a fix.
2. **Orchestrator bundle 42 (PR #602)** escalated the finding via change-log entry; my PR #586 (B11.2.b) audit claim that "67 pre-existing sibling tests pass" was technically true at audit time but missed the time-bomb pattern.
3. **Background investigation agent (task `abe2185e0b6b14891`)** diagnosed root cause: **hypothesis (c)** — a real B11.2.b regression that PR #586's audit missed because the test was a wall-clock time bomb. Production code is correct; bug is in the test fake.
4. **This PR (#604, delegated to sub-agent)** applies the test-only fix.

## Root cause

`_RecordingStepUpGateway` test fake at `test/proxy/b11_2_b_step_up_wiring_test.dart:444+` compared seeded `expiresAt` to real wall-clock UTC via `DateTime.now().toUtc()`, while the rest of the test gate ran on an INJECTED `now` clock (`() => DateTime.utc(2026, 5, 13, 10)`).

The seeded expiry for `CHAL_PASSWORD` was `expiresAt: DateTime.utc(2026, 5, 13, 10, 10)`. Once real-world UTC crossed `10:10Z`, the fake's `consume` returned `null` (treating the challenge as expired) → router fell through to reject → `wrote=true` → test failed (expected `false`).

The test passed during PR #586 CI (authored before 10:10Z on 2026-05-13) and began failing once real-world UTC crossed 10:10Z. Pure time-bomb pattern.

## What landed

**Single file:** `test/proxy/b11_2_b_step_up_wiring_test.dart`

- **Constructor injection** (lines 446–450): `_RecordingStepUpGateway({DateTime Function() now = DateTime.now}) : _now = now;` with `final DateTime Function() _now` field
- **`emit` method** (line 500): replaced `DateTime.now().toUtc()` → `_now().toUtc()`
- **`consume` method** (lines 521–522): replaced both wall-clock calls (`isBefore` check + `consumedAt` assignment) → `_now().toUtc()`
- **8 call sites updated** (lines 76, 132, 180, 220, 259, 295, 324, 346): each `_RecordingStepUpGateway()` → `_RecordingStepUpGateway(now: () => DateTime.utc(2026, 5, 13, 10))` — matches the clock already threaded into `runStepUpGate`

Production code in `tool/advisor_proxy/auth_step_up_gate.dart` and `auth_step_up_routes.dart` is correct by design and remains untouched on master.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ — `baseRefName: master`, MERGEABLE CLEAN |
| Single-file scope | ✓ — `git diff --stat` returns one entry, +15/-11 |
| Production code untouched | ✓ — diff is test file only; verified no `tool/advisor_proxy/auth_step_up_*` change |
| Constructor injection present | ✓ — verified at lines 446–450 of diff |
| `emit` wall-clock fixed | ✓ — verified at line 500 |
| `consume` both wall-clock sites fixed | ✓ — verified at lines 521–522 |
| All 8 instantiations updated | ✓ — diff shows 8 `(now: () => DateTime.utc(2026, 5, 13, 10))` insertions |
| Test passes after fix | `flutter test test/proxy/b11_2_b_step_up_wiring_test.dart` → `+8 -0` (was `+7 -1`) |
| `dart analyze --fatal-infos` clean | ✓ disclosed |
| Hook discipline | ✓ — worker installed canonical hooks first; no `--no-verify` |
| No `--no-verify` traces | ✓ |
| Authority cite in PR body matches reality | ✓ — investigation agent task ID + PR #586 + PR #600 + master tip all correctly referenced |

## Pattern B compliance

**✓ lightweight** — PR body carries the worker self-audit table (8 lenses focused on snapshot correctness + authority cite + no-regression risk + production-code-untouched). Executor lens table is not required for a pure test-fake fix per audit chunking playbook ("light variant" applies when <20 files and no semantic surface change). Same shape as PR #588's admin_cors_bootstrap_test fix.

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — this fix closes the cross-lane finding escalated in Bundle 42's change-log |
| Worker disclosure operator should know | ❌ — worker fully transparent; investigation agent had already diagnosed root cause |
| Stacked PR | ❌ — base is master |

## Cross-lane notes

- **Closes the cross-lane finding** escalated in Bundle 42 (PR #602)
- **Production code on master is correct and unchanged** — `auth_step_up_gate.dart` + `auth_step_up_routes.dart` remain canonical
- **Pattern lesson for future audits**: my PR #586 audit should have flagged any seeded-`expiresAt`/`DateTime.now()` mismatch in test fakes. Same class as PR #588's admin_cors_bootstrap_test snapshot drift, but caused by time rather than code. **Worth adding to the test-fake checklist** — flagged for closeout-phase doc-audit doctrine update.

## Findings

None blocking. The fix is the minimum-viable change to inject the test clock into the gateway fake so future re-runs are deterministic regardless of when they execute.

## Authority anchors

- Investigation agent task `abe2185e0b6b14891` (read-only diagnosis)
- `docs/_audits/post_codex_wave/pr_600_c_5_mobile_handoff_deeplink_audit.md` — escalation source (C-5 worker disclosure)
- `docs/_audits/post_codex_wave/pr_586_b11_2_b_step_up_wiring_audit.md` — the B11.2.b audit that missed the time bomb
- PR #588 (`pr_588_admin_cors_bootstrap_test_fix_audit.md`) — precedent for orchestrator delegating test-only fixes to a sub-agent

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. Bundle 43 change-log entry records the merge + closes the B11.2.b test-failure investigation loop.
