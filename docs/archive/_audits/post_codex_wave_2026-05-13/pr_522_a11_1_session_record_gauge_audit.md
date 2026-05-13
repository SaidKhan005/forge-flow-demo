# PR #522 Audit — A11.1 Production Session-Record Incomplete Gauge

**Slice:** A11.1 (Lane A — code health)
**Owner:** Claude lane executor
**Branch:** `claude/a11-1-session-record-gauge`
**Base:** `master` (no drift; rebased onto current `origin/master` including B11.1)
**Gate:** `operator` per ledger (proxy-touching → mandatory operator approval per CLAUDE.md "Agent-Led Slices")
**Size:** 681 additions / 2 deletions / 5 files
**Chunking:** light variant (small proxy-touch + observability-only behavior)
**Dependency:** A0 merged ✓

## Pattern B compliance

Both audit tables present in worker report (14-lens self-audit referenced from PR body). Worker's executor independent audit pass embedded in the worker report.

## Verdict

**approve-pending-operator** — escalating to operator for proxy-touching policy approval. Audit itself is clean; the gate is the proxy-touch trigger, not a finding.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Gauge labels carry NO PII (HP #4 isolation) | ✓ — `_counts` map keys are `route` (proxy path constant from `authSessionLoginPath`) + `missing_field` / `unexpected_<field>` strings; never tenant identifiers, never email/IP/user_id/operator_id/location_id/session_id |
| `observe()` defensive try/catch returns synthetic `complete: true` on predicate throw | ✓ — `tool/advisor_proxy/advisor_proxy.dart` new gauge class: `try { assertion = SessionRecordCompleteness.assertComplete(...); } catch (_) { return const SessionRecordAssertion(complete: true, missingFields: [], unexpectedFields: []); }` — a predicate bug literally cannot crash the response path |
| Response bytes IDENTICAL pre/post-edit | ✓ — at the `POST /v1/auth/session/login` 2xx site: worker hoisted the body literal out of `_writeJson` into `final loginResponseBody = <String, Object?>{...}`, calls `gauge?.observe(route: ..., body: loginResponseBody, roles: ...)`, then `_writeJson(response, 200, loginResponseBody)`. The dict the route ships is byte-for-byte the same dict the gauge observed |
| Gauge `route` label uses route-path constant (not raw string literal) | ✓ — call site uses `authSessionLoginPath` (the existing const), so a future route rename auto-propagates to the gauge label without code drift |
| Optional gauge param on `routeRequest` (back-compat) | ✓ — `SessionRecordIncompleteGauge? sessionRecordIncompleteGauge` (nullable); call site uses `gauge?.observe(...)` — existing tests without the gauge wired pass through untouched |
| Required gauge field on `ProxyProductionBindings` (production always has it) | ✓ — `required this.sessionRecordIncompleteGauge` in constructor; `buildProxyProductionBindings` constructs `SessionRecordIncompleteGauge()` as a single shared instance per proxy process |
| `tool/advisor_proxy/main.dart` threads the binding into `routeRequest` | ✓ — `sessionRecordIncompleteGauge: productionBindings.sessionRecordIncompleteGauge` |
| Re-export module `tool/advisor_proxy/session_record_predicate.dart` keeps proxy out of `tool/pressure/` | ✓ — new 27-LoC file is pure `export '../pressure/p4_session_record_predicate.dart' show SessionRecordAssertion, SessionRecordCompleteness;`. Pressure harnesses keep their existing import; the proxy uses the new path. No code duplication |
| B11.1 (PR #512) `tool/advisor_proxy/auth_handoff_routes.dart` UNTOUCHED | ✓ — file is NOT in PR diff (`gh pr diff 522 --name-only` returns only the 5 A11.1 files). B11.1 auth-handoff route block is in a different region of `advisor_proxy.dart` from the A11.1 sign-in 2xx handler |
| Single emission point (only `POST /v1/auth/session/login`) | ✓ — only one observe() call inserted in the diff; other session-adjacent routes (`refresh`, `revoke`, `revoke-all`, `mfa/totp/confirm`, `auth/handoff/redeem`) return different shapes and are intentionally NOT wired (per worker rationale: avoids false positives) |
| Tests cover happy + sad + global-admin + back-compat | ✓ — `test/proxy/session_record_gauge_test.dart` (493 LoC, 11 cases) covers tenant-scoped happy path, global-admin happy path (empty scope by contract), missing-operator_id, missing session_id + user_id, global-admin unexpected_operator_id violation, deep-copy snapshot, reset, defensive non-throw, and back-compat null-gauge through `routeRequest` |
| Worker verification: `dart analyze` clean, 11/11 new tests pass, 220/220 advisor_proxy_test pass, 17/17 B11.1 auth_handoff_routes_test pass | ✓ — worker disclosed `flutter test test/proxy/auth_handoff_routes_test.dart → 17/17 pass` proving B11.1 routes still work end-to-end after A11.1 rebase |

## Honesty observation (POSITIVE)

Worker disclosed a recovery note: **initial edits accidentally landed on the master tree (absolute-path mistake)**, detected mid-flight, captured edits as a patch, reverted master cleanly with `git checkout --` + `rm -f` of the new files, confirmed master clean with `git status`, then rebased the worktree branch onto current `origin/master` and re-ran all verification. Worker correctly:
- Detected the mistake before opening the PR
- Did not push the polluted master state
- Re-verified everything after the rebase
- Disclosed honestly in the PR body

This is exactly the right pattern — catching and disclosing the mistake rather than hoping it slipped through.

## Operator-decision rationale (why this needs operator sign-off)

Per CLAUDE.md "Agent-Led Slices" durable rule:
> *"Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict."*

A11.1 touches `tool/advisor_proxy/advisor_proxy.dart` (the production proxy hot path), `tool/advisor_proxy/proxy_bootstrap.dart` (production bindings), and `tool/advisor_proxy/main.dart` (production proxy entrypoint). Even though the behavior is **observability-only** and the response bytes are byte-for-byte identical, this is a proxy touch and the operator-gate doctrine applies.

Recommendation: **approve-for-merge**. The discipline is excellent (no PII, defensive try/catch, optional param for back-compat, B11.1 untouched, 11 tests including back-compat null-gauge case). If approved, I will merge and update the ledger.

## Authority anchors verified

- `docs/_execution/lane_a_code_health/03_execution_slices.md` — "Slice A11.1 — Production Session-Record Gauge" scope matches diff
- `docs/_execution/lane_a_code_health/01_product_rule_and_ia.md` R3 §2 stretch-goal recommendation #3 — promote predicate to production gauge ✓ executed
- `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` Lens 13 — observability framework anchor

## Findings

None blocking. One process-positive observation (recovery transparency), one policy escalation (proxy-touch → operator gate).

## Status

Awaiting operator approval. Will merge + update ledger on go-ahead.
