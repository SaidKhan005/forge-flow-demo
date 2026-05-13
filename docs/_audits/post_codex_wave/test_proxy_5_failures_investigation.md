# test/proxy/ Stale-Snapshot Failures — Investigation Report

**Date:** 2026-05-13
**Trigger:** Post-Codex wave closeout deep audit (`wave_completion_deep_audit_2026_05_13.md`) ran a full `test/proxy/` sweep against master HEAD `0a6311cb` and disclosed a small set of red tests that the orchestrator's per-PR slice audits had not surfaced (because those slice audits scoped tests to the slice's own files).
**Scope:** Identify each red test, trace to its production-side root cause, and decide fix-or-defer. Production code is presumed contract-correct at HEAD; tests with stale fakes must catch up.

## Failure roster (master @ `0a6311cb`)

The sweep showed `+664 -3` for the two slice files and `+0 -1` for one further file, plus a small number of timeout/env-dependent flakes that did not have a stable repro. The three stable, contract-drift failures are:

### F1 — `test/proxy/audit_chain_anchors_routes_test.dart:209` — "rejects a token without operator scope with 403"

**Symptom:** `expect(response.statusCode, 403)` but actual is `200`.

**Production root cause:** B1 sign-in contract commit `c3f1ce0d` (2026-05-12, "fix(proxy): runZonedGuarded + sign-in contract + soak harness (B1+B2)") intentionally aligned `requireOperatorContext` at `tool/advisor_proxy/advisor_proxy.dart` so that `super_admin` / `ff_support` sessions are NOT refused with 403 when `operator_id` is intentionally absent. The test's fake JWT (`roles: ['super_admin']`, `operatorId: null`) hits this acceptance branch in production and correctly returns 200. The 403 assertion is stale.

**Fix:** Switch the test's role from `super_admin` to `operator_owner`. An `operator_owner` claim without operator scope IS genuinely unauthorized, so the test continues to exercise the reject-path; only the role label changes. Preserves test coverage exactly.

**Alternative considered:** Flip the assertion to 200. Rejected because the test's stated intent (per docstring at line 209) is to verify the reject path, not the new scope-less acceptance branch — which is already covered elsewhere by `scope_missing_rejected` log assertions in B1's own test surface.

### F2 — `test/proxy/registry_proxy_health_check_store_test.dart:211` — "AGE thrown error projects ageOk → false"

**Symptom:** test throws uncaught `StateError('AGE not loaded')`; expected the probe to swallow it and project `ageOk: false`.

**Production root cause:** A3.3 commit `bb88f82b` (2026-05-13, "refactor(proxy): bare-catch typing chunk 2/3 in advisor_proxy.dart") narrowed the catch site at `tool/advisor_proxy/advisor_proxy.dart:5605` from `catch (_)` to `on Exception catch (_)`. The inline comment explains the rationale: "Narrowed to `Exception` so genuine `Error`s (assertion failures, OOM, type errors) keep propagating instead of being silently masked behind a green health envelope." `StateError extends Error` (not `Exception`), so it now escapes uncaught.

**Fix:** Change `StateError(...)` → `Exception(...)` in the test fake. The test's intent — exercise the swallow-and-project-false path — requires an `Exception` subtype post-A3.3. Production is contract-correct (errors should propagate); the test fake was the seam that drifted.

### F3 — `test/proxy/registry_proxy_health_check_store_test.dart:233` — "pgvector distance error projects pgvectorOk → false"

Same root cause as F2. Same fix: `StateError(...)` → `Exception(...)` at line 239.

## Out-of-scope failures observed in the same sweep

- `test/proxy/auth_location_integrations_route_test.dart:476` ("returns 503 with integrations_projection_unavailable when the projection throws") — same root cause as F2/F3 (test fake throws `StateError('boom')` at line 48). The catch site that previously swallowed this was also narrowed by A3.3. Filed for a separate orchestrator follow-up — not bundled into the present 2-file fix because (a) it lives in a different production seam, (b) needs separate verification, and (c) the brief explicitly scoped this slice to the two files above.
- A handful of timeout/env-dependent flakes (Postgres pool acquire timeouts, KMS stub warnings) — environmental, not contract drift.

## Decision

Apply the 2 fixes above (3 test cases, 2 files). Production code is contract-correct in both root causes (B1 sign-in widened acceptance for scope-less platform admins, A3.3 narrowed catches to let genuine `Error`s propagate); the test fakes were the snapshot-drift seam that needed to catch up.

## Authority anchors

- B1 sign-in commit `c3f1ce0d` — `fix(proxy): runZonedGuarded + sign-in contract + soak harness (B1+B2)`
- A3.3 commit `bb88f82b` — `refactor(proxy): bare-catch typing chunk 2/3 in advisor_proxy.dart (A3.3)`
- `tool/advisor_proxy/advisor_proxy.dart:5605` — typed catch site with inline rationale comment
- Precedents (same shape): `docs/_audits/post_codex_wave/pr_588_admin_cors_bootstrap_test_fix_audit.md`, `docs/_audits/post_codex_wave/pr_604_b11_2_b_test_fake_clock_fix_audit.md`
