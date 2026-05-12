# B1+B2 Proxy Hot-Fix + Soak Harness — Execution Slice

Status: implementation committed on `claude/b1-b2-proxy-soak-fix`; awaiting human audit before merge.
Branch: `claude/b1-b2-proxy-soak-fix`
Implementation commit: `c3f1ce0d` (10 files, +2096 / -24)
Source decisions: `docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md` (B1 + B2)
Source audit: `docs/_audits/code_health/a1_proxy_bug_root_cause.md`
Source research: `docs/_research/post_codex/r3_soak_pressure_testing.md`

## Why this slice exists

Two production-observed proxy bugs:

1. **Bug 1** — sign-in returns an incomplete session record for F&F support / platform super-admin users after the support-related check path. Symptom: client surfaces `AuthLoginFailure(code: 'ledger_unavailable')`.
2. **Bug 2** — proxy crashes after some time under live multi-session load.

Per the addendum, both bugs are hot-fixable parallel to Codex's in-flight admin-UX wave because the proxy is outside that wave's scope. The fix ships together with a regression-test harness (R3 §3 quick-win subset) so recurrence trips CI, not operators.

## What landed

### B1 — Bug 1 fix: sign-in contract alignment

A1's audit found a client/proxy contract asymmetry: the client allows scope-less `super_admin` / `ff_support` claims; the proxy refused them with 403 at `requireOperatorContext` (`tool/advisor_proxy/advisor_proxy.dart:2166-2174`).

**Resolution chosen: Option A** — proxy accepts scope-less claims for `ff_support` + `super_admin` roles. Rationale: these users are inherently multi-operator; an operator-picker step at sign-in would change the auth flow for staff who don't need it. The 11A.10 impersonation lane (still in scope per `PROJECT_TRACKER.md`) is the dedicated picker UX.

Coverage: `test/advisor_proxy_test.dart` adds contract-alignment tests for scope-less claims (+109 lines).

### B1 — Bug 2 fix: runZonedGuarded wrap

A1 finding S1: `main()` at `tool/advisor_proxy/main.dart` had no top-level error handler; any unawaited future throwing inside `routeRequest` exited the process. Cloud Run restarted, operators saw intermittent outages.

`main()` body wrapped in `runZonedGuarded` (+76 lines). Uncaught errors emit `proxy.root_zone_uncaught` structured log line with error + stack + first stack frame, then exit cleanly.

### B1 — 6 instrumentation items

Per A1's recommendations:

1. `proxy.root_zone_uncaught` structured log line (covered by runZonedGuarded wrap above).
2. Postgres pool gauges (`_openConnectionCount`, idle count, waiter count) exposed via `/health`. Accessor surface added to `lib/infrastructure/persistence/postgres/package_postgres_executor.dart` (+54 lines).
3. `pubsub_subscriber.ring_buffer_keys` gauge for `_ringBuffers` map; exposed via `/health` (+10 lines in `lib/services/realtime/google_cloud_pubsub_subscriber.dart`).
4. Scope-less acceptance branch log in `requireOperatorContext` — logs `user_id`, `roles`, claim shape for Bug 1 confirmation under real load.
5. Typed-catch at `tool/advisor_proxy/advisor_proxy.dart:12392` — bare `catch (_)` replaced with `catch (e, st)` + log of `error.runtimeType` + first stack frame.
6. Typed-catch at `tool/advisor_proxy/advisor_proxy.dart:12421` — same shape.

### B2 — Soak harness (R3 quick-win subset)

Three new files in `tool/pressure/`:

- `p4_session_soak.dart` (+611 lines) — multi-session sign-in soak; concurrent operators; CLI flags for duration / concurrency / target URL; asserts session-record completeness on every login; clean shutdown on SIGINT.
- `p4_operator_day_soak.dart` (+596 lines) — synthetic operator daily workload (sign-in → schedule view → notification check → settings nav → sign-out; realistic pacing).
- `p4_session_record_predicate.dart` (+195 lines) — `SessionRecord.assertComplete()` predicate shared between harnesses and production observability gauge. Asserts `session_id`, `user_id`, `operator_id`, `location_id` are all non-empty, OR that the user is `ff_support` / `super_admin` and operator/location are explicitly empty per the new contract.

Test coverage: `test/pressure/p4_session_record_predicate_test.dart` (+192 lines) covers all predicate branches including the contract carve-out for ff_support/super_admin.

Docs: `test/load/pressure/README.md` updated with usage for the two new harnesses (+40 / -24).

## Verification status

| Check | Status | Notes |
|---|---|---|
| `dart analyze` on touched files | reported clean by agent pre-stop | re-run during audit |
| Existing advisor_proxy tests (218) | reported pass by agent pre-stop | re-run during audit |
| New predicate unit tests | not yet run | run during audit |
| Soak harness smoke (30s, concurrency=2) | not yet run | run during audit |
| Contract test for scope-less ff_support sign-in | included in commit | re-run during audit |

The agent was stopped at the smoke-run step. Audit pass (orchestrator) re-runs everything plus the two soak harness smokes before approving merge.

## Audit checklist (orchestrator)

Before approving merge of `claude/b1-b2-proxy-soak-fix` against master:

- [ ] Re-run `dart analyze` on all 10 touched files
- [ ] Re-run advisor_proxy test suite end-to-end (target: 218+ pass with new contract tests)
- [ ] Re-run `test/pressure/p4_session_record_predicate_test.dart`
- [ ] Smoke-run `tool/pressure/p4_session_soak.dart` for 30s with concurrency=2; confirm clean exit + zero assertComplete failures
- [ ] Smoke-run `tool/pressure/p4_operator_day_soak.dart` for 30s with concurrency=2; confirm clean exit + zero assertComplete failures
- [ ] Verify `runZonedGuarded` log line shape matches `proxy.root_zone_uncaught` convention
- [ ] Verify `/health` endpoint payload now contains pool gauges + ring buffer keys gauge
- [ ] Verify the two former bare-catch sites at advisor_proxy.dart:12392 / 12421 are typed-catch now
- [ ] Verify Option A (proxy accepts scope-less ff_support/super_admin) does not leak operator-scope into the response for those users
- [ ] Verify the contract change doesn't break the existing operator-scope path for normal users
- [ ] Cross-check the slice against CLAUDE.md HP #4 (RLS posture — per-operator isolation must still hold for non-support users)
- [ ] Cross-check the slice against `docs/contracts/hardening_rls_and_repository_pattern_contract.md`

## Out of scope (do not expand)

- Full forensic kit (heap snapshot upload to GCS, glados state-machine tests) — that's the +6-day durable capability extension queued for the code-health wave (A11 in the addendum).
- Resolving Bug 2 hypothesis S2 (Postgres pool defaults of 4) — only the gauge is added here; raising the env var is a runbook decision deferred to the code-health wave.
- Resolving Bug 2 hypothesis S3 (unbounded `_ringBuffers` map eviction) — only the gauge is added; actual eviction policy is a follow-up.

## Merge gate

NO AUTO-MERGE. Auth-critical surface. Human audit required against this checklist + the source contracts. If any item fails, send back to a follow-up agent (or fix inline) before merge.
