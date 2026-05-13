# PR #625 Audit — auth_location_integrations Test StateError → Exception (Claude)

**Slice:** Residual test cleanup (A3.3 fallout — mirror of PR #610)
**Owner:** Claude (orchestrator-dispatched, isolated worktree agent)
**Branch:** `claude/auth-location-integrations-test-stateerror-fix`
**Base:** `master` @ `f9bc84fd` (post-Bundle 48)
**Gate:** auto — test-only fix; production code 0 lines
**Risk:** **Zero** — single `StateError` → `Exception` swap + 4-line inline rationale comment; mirrors landed PR #610 verbatim
**Size:** 5 additions / 1 deletion / 1 file (light variant audit)

## Verdict

**approve-for-merge** — auto-merging per expanded delegation. Exact mirror of PR #610 pattern applied to the third surviving test fake from the `test_proxy_5_failures_investigation.md` triage list. A3.3 production catch-site (`tool/advisor_proxy/advisor_proxy.dart:5605`) untouched; only the test fake catches up. Worker disclosed pre-fix repro (`FormatException: Unexpected end of input`) + post-fix pass (7/7) + clean analyze.

## Pattern B compliance

**✓ EXEMPLARY** — worker shipped Pattern B lightweight 8-lens table in PR body (test-only fixes use the lightweight variant per PR #588 / #604 precedent). Citations to A3.3 commit `bb88f82b`, production catch-site `advisor_proxy.dart:5605`, and canonical rationale-comment shape at `registry_proxy_health_check_store_test.dart:217-221`.

## What landed

| File | LoC | Kind |
|---|---|---|
| `test/proxy/auth_location_integrations_route_test.dart` | +5 / -1 | FIX — `StateError('boom')` → `Exception('boom')` at line 48 of the `_failingProjection()` fake + 4-line inline rationale comment explaining the A3.3 narrowing (PR #610 precedent shape) |

**Net effect:** swallow-and-project-503 path on `GET /v1/auth/locations/{location_id}/integrations` is exercised correctly again. Pre-A3.3 (bare `catch (_)`) caught `StateError`; post-A3.3 (`on Exception catch (_)`) lets `StateError` escape uncaught because `StateError extends Error`. The test fake now throws `Exception` to hit the documented swallow path.

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `tool/advisor_proxy/` untouched | `git diff origin/master -- tool/advisor_proxy/` returns 0 lines | Independent diff confirms; A3.3 production contract preserved |
| `lib/auth/` untouched | diff scope | Zero changes |
| `db/migrations/` untouched | diff scope | Zero changes |
| No other test files touched | `git diff --stat` shows 1 file | Diff narrowly scoped to the failing fake |
| Pre-fix repro reproduces FormatException | `auth_location_integrations_route_test.dart:488:13` | Worker disclosed exact pre-fix output (empty body because StateError escaped before 503 JSON could project) |
| Post-fix all 7 tests pass | `flutter test test/proxy/auth_location_integrations_route_test.dart` | Worker disclosed `+7: All tests passed!` |
| `dart analyze --fatal-infos` clean | disclosed | `No issues found!` |
| Pre-push hook clean | disclosed | `postgres_import_lint` clean |
| Inline rationale shape matches canonical | line 46-50 vs `registry_proxy_health_check_store_test.dart:217-221` | Three-comment-line preamble explaining the A3.3 narrowing |

## Executor 8-lens audit (re-verified)

| # | Lens | Verdict | Re-verification |
|---|---|---|---|
| L1 Authority alignment | OK | Direct mirror of PR #610; same investigation doc cited; same production root cause (A3.3 `bb88f82b`) |
| L2 Scope discipline | OK | 1 file, 1 logical change (with documenting comment); no incidental edits |
| L3 Hard Promises | OK | HP #3 honored — no production logic changed pre-7.58 |
| L4 Time / RLS guardrails | N/A | Test-only fix |
| L5 Migration / drift | N/A | No `db/migrations/**` touch |
| L6 Runtime acceptance | OK | Pre-fix + post-fix outputs both disclosed; failure → pass transition documented |
| L7 Tests + analyze | OK | 7/7 pass; `dart analyze --fatal-infos` clean; pre-push hook clean |
| L8 Trackers / docs | OK | None touched (orchestrator's job at merge — bundle entry below) |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `f9bc84fd` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B 8-lens table present | ✓ |
| 1 file matches PR body declaration | ✓ — `git diff --stat`: 1 file, +5 / -1 |
| `tool/advisor_proxy/` diff = 0 lines | ✓ — independent `git diff` |
| `lib/auth/` diff = 0 lines | ✓ |
| `db/migrations/` diff = 0 lines | ✓ |
| `pubspec.yaml` diff = 0 lines | ✓ |
| `StateError('boom')` → `Exception('boom')` swap | ✓ — confirmed in diff at line 48-52 |
| Inline rationale comment present | ✓ — 4-line preamble explaining A3.3 narrowing |
| 7/7 tests pass | ✓ disclosed |
| `dart analyze` clean | ✓ disclosed |
| No `--no-verify` traces | ✓ |
| No tracker / ledger touches | ✓ — diff scope confirms |
| No Claude-Codex conflict | ✓ — test-only file, no in-flight worker on this file |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — residual cleanup; no ledger row required (orphan investigation residual) |
| Worker disclosure operator should know | ❌ — none |
| Stacked PR | ❌ — base is master |

**Decision**: auto-merging per expanded delegation. Identical pattern to merged PR #610.

## Cross-lane notes

- **Closes residual fallout** from `test_proxy_5_failures_investigation.md` — third surviving test fake catches up to A3.3 catch-site narrowing.
- **No Codex-owned files touched** — pure test-side fix on Claude-adjacent territory.
- **C-2 group + C-7a wires** running in parallel (5 other background agents). No file overlap with this PR.

## Findings

None.

## Authority anchors

- `docs/_audits/post_codex_wave/pr_610_test_proxy_stale_snapshot_fix_audit.md` — same-shape precedent (B1 + A3.3 fallout, 2 test fakes)
- `docs/_audits/post_codex_wave/test_proxy_5_failures_investigation.md` — investigation listing this exact failure
- `docs/_audits/post_codex_wave/pr_588_admin_cors_bootstrap_test_fix_audit.md` — original test-only-fix precedent
- `docs/_audits/post_codex_wave/pr_604_b11_2_b_test_fake_clock_fix_audit.md` — second test-only-fix precedent
- A3.3 commit `bb88f82b` — production root cause
- `tool/advisor_proxy/advisor_proxy.dart:5605` — typed catch site (untouched on master)

## Status

**Auto-merging** per expanded delegation.
