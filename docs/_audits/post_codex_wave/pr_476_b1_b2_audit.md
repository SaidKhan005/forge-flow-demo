# PR #476 — B1+B2 Proxy Hot-Fix + Soak Harness — Audit

Auditor: orchestrator on `claude/nifty-clarke-d3ec25` (this worktree).
Audited worktree: `C:/Git Local Repos/forge_flow_demo/.claude/worktrees/b1-b2-proxy-soak-fix`.
Branch under audit: `claude/b1-b2-proxy-soak-fix` (commits `c3f1ce0d` impl + `fc1a3f80` slice plan).
Diff vs `origin/master`: **11 files, +2191 / -24** (1 file more than the PR's stated "10 files" — the slice plan doc was added in `fc1a3f80` after the implementation commit; cosmetic, non-blocking).
Audit date: 2026-05-12.
Smoke-run evidence: `pr_476_smoke_run_evidence.txt` (same directory).

---

## Verdict

**approve-for-merge** (re-audit on 2026-05-12 after follow-up commit `e26e53af`).

Original verdict was **material-gaps-send-back**. The merge-blocker — client-side response parser at `lib/services/auth/proxy_auth_session_ledger_writer.dart:373-400` rejecting the proxy's new global-admin response shape — was resolved by follow-up commit `e26e53af` on the same branch. Both `_recordFromLoginResponse` and `_validateLoginScopeEcho` now apply a role-aware branch (accepts empty `operator_id`/`location_id` only when caller's roles include `ff_support` or `super_admin`; rejects for everyone else). DTO + notifier wire `result.session.roles` through. Four new tests cover global-admin happy paths and regression-protect the normal-user rejection.

Re-audit cross-checks:
- Proxy site `_hasGlobalAdminRole` at `tool/advisor_proxy/advisor_proxy.dart:2260-2265` accepts exactly `{ff_support, super_admin}` — client `_globalAdminRoles` mirrors precisely.
- Pre-existing failures in `advisor_proxy_bootstrap_test` and `auth_live_binding_test` confirmed unrelated to B1+B2 (reproduces with B1 client fix stashed). **Provenance correction (2026-05-12):** the B1 follow-up agent's initial report attributed these failures to B3 PR #473's email-pipeline slice; a subsequent regression-triage agent (PR #477) traced the actual cause to commit `17ce0391` (2026-05-07 auth hardening pack — B1.A6 session-cap LRU enforcement added an unconditional BYPASSRLS `countActiveSessions` transaction before `insertLogin`). The hardening pack added new cap-behavior tests but didn't update the two pre-existing single-transaction assertions; the failures sat latent on master for 5 days before PR #476's re-audit surfaced them. PR #473 (B3) only touched email renderer + fanout and did not introduce or worsen this regression.
- Slice plan now carries a `## Follow-up: client parser alignment` section documenting both sites + the three-mirror discipline (proxy / soak predicate / client).
- Addendum B1 row updated with the Option-A two-side clarification.

Everything else from the original audit stays as written below: B1 proxy contract, B2 runZonedGuarded, 6 instrumentation items, soak harnesses, tests, `dart analyze`, scope discipline are clean and ship as designed.

---

## Per-section findings

### 1. B1 — sign-in contract alignment (Option A) — MATERIAL GAP

**Proxy side: clean.**
- `tool/advisor_proxy/advisor_proxy.dart:2168-2266` (`requireOperatorContext`) replaces the unconditional 403 at `:2174-2178` with a branch keyed on `_hasGlobalAdminRole(roles)` (`:2256-2266`). The carve-out is tight — only `ff_support` or `super_admin` get the accept branch (`:2263-2264`). Every other role still 403s.
- The accept branch returns an `OperatorContext` with empty-string `operatorId` / `locationId` for the missing fields (`:2224-2233`). Per-operator isolation (HP #4) is preserved for normal users — the carve-out is keyed on the explicit role check, not on a generic "any token" path.
- The accept branch logs `proxy.auth.scope_missing_accepted_global_admin` (info-level) with `user_id`, `roles`, `has_operator_id`, `has_location_id`, `claim_shape` — matches A1 §1.5 item #1.
- The reject branch logs `proxy.auth.scope_missing_rejected` (warn-level) with the same fields plus `status_code: 403` — extra observability beyond what A1 asked for, helpful for triage.
- The 11A.10 impersonation lane is not pre-empted. `_effectiveAdminAuthScope` (`:16864-16893`) lets a global admin override the empty scope with `body['operator_id']` / `body['location_id']` per-request, which is exactly the slice plan's promise that "downstream routes that need a concrete tenant must call the impersonation flow."
- Four new contract tests in `test/advisor_proxy_test.dart` (`:701-815`) positively cover: scope-less `ff_support` accepted, scope-less `super_admin` accepted, non-admin scope-less still 403, partial scope (`operator_id` set, `location_id` null) for a global admin still accepted. All four pass. No existing test was deleted; existing 403 tests still pass because the contract for non-admin roles is unchanged.

**Client side: GAP.**

The PR does not modify `lib/services/auth/proxy_auth_session_ledger_writer.dart` or `lib/state/auth_session_notifier.dart`. With the new proxy contract, a successful `ff_support` sign-in flow goes:

1. Client posts to `/v1/auth/session/login` with the verified JWT. Proxy now correctly returns 200 with `{session_id: ..., user_id: ..., operator_id: "", location_id: ""}`.
2. Client parses the response in `_recordFromLoginResponse` at `proxy_auth_session_ledger_writer.dart:373-400`:
   ```dart
   final operatorId = _readNonBlankString(response.body['operator_id']);
   final locationId = _readNonBlankString(response.body['location_id']);
   ...
   if (userId == null || operatorId == null || locationId == null) {
     throw ProxyAuthSessionLedgerError(
       code: 'malformed_response',
       message: 'proxy /v1/auth/session/login returned incomplete scope',
       statusCode: response.statusCode,
     );
   }
   ```
   `_readNonBlankString` (at `:427+`) returns `null` for empty strings, so the empty-string scope from the global-admin contract trips this exact throw.
3. `auth_session_notifier.dart:308-348` catches and maps it to `AuthLoginFailure(code: 'ledger_unavailable')` — the exact operator-visible symptom A1 was tracking.

The new harness predicate `SessionRecordCompleteness.assertComplete` knows that empty operator/location is OK for global admins (`p4_session_record_predicate.dart:86-96`), but **the production client does not** — there's no equivalent role-aware branch in `_recordFromLoginResponse`. The harness will say "complete," the real client will reject the same body as "incomplete."

Same hole exists in `_validateLoginScopeEcho` at `proxy_auth_session_ledger_writer.dart:402-425` (also rejects empty echoed scope as `malformed_response`).

**A1 §1.1 already flagged this asymmetry** ("client allows the missing id ... defaults to ''... locationId = ''"). The proxy fix landed; the client fix did not.

**To unblock this PR**, the client needs an analogous role-aware branch — either:
- Skip the empty-string check on the role-projected `AuthSession.roles` when the roles contain `ff_support` or `super_admin`, OR
- Tolerate empty `operator_id` / `location_id` in `_readNonBlankString` callers when the verified JWT signaled global admin.

The same shape applies to `_validateLoginScopeEcho`. Same change.

This is **merge-blocking**. The whole point of the B1 lock was to stop the operator-observed `ledger_unavailable` failure; that symptom persists after this PR lands.

### 2. B1 — runZonedGuarded wrap — CLEAN

`tool/advisor_proxy/main.dart:84-130`. Verified:
- `main()` body is the zone callback. Inner work is refactored into `_runProxy(args)` (`:135+`) so the entire serve loop runs inside the guarded zone, not just a partial wrap.
- The uncaught error handler (`:104-128`) emits `proxy.root_zone_uncaught` at `LogSeverity.error` with `error_type` (`runtimeType`), `error_message`, `stack_first_frame` (uses the existing `firstStackFrame` helper), and the full `stack_trace`. Matches A1 §2.4 item #2.
- Belt-and-braces fallback at `:121-127` writes to `stderr` if `log()` itself throws, so the diagnostic line is never silently lost.
- A `Completer<void>()` is used to keep `main()` awaiting until the zone's inner future resolves (`:96-103` + `:131`). Without it, `main` would return as soon as `runZonedGuarded` registered the inner future, which is a common gotcha. The implementation is correct.
- Clean shutdown path: the handler does NOT call `exit()` (intentional — comment at `:108-113` explains the reasoning). The existing SIGTERM/SIGINT handlers at `_runProxy` are still wired and emit `shutdown.complete`. Cloud Run will tear the isolate down on truly fatal errors regardless. This is consistent with the `S1` recommendation in A1 §2.1 ("we just want the diagnostic trail to be available first").
- No new top-level state introduced that would survive zone teardown — the only new global is `proxyRuntimeGauges` (a single field on `tool/advisor_proxy/advisor_proxy.dart:3727`), which is reset on each new isolate (and is null-tolerant).

### 3. B1 — 6 instrumentation items — ALL PRESENT

| A1 item | File:line | Status |
|---|---|---|
| `proxy.root_zone_uncaught` log line | `tool/advisor_proxy/main.dart:104-128` | Present (Section 2). |
| Postgres pool gauges on `/health` | `lib/infrastructure/persistence/postgres/package_postgres_executor.dart:50-77` (`PostgresPoolGaugeSnapshot`) + `:141-150` (`gaugeSnapshot` getter) + `:276-289` (`_snapshotForGauges`) + `tool/advisor_proxy/advisor_proxy.dart:8602-8654` (`/health` envelope inclusion). Wired in `main.dart:625-636`. Payload includes `open_connection_count`, `idle_count`, `waiter_count`, `max_connection_count`. | Present. |
| `pubsub_subscriber.ring_buffer_keys` gauge | `lib/services/realtime/google_cloud_pubsub_subscriber.dart:491-500` (`ringBufferKeyCount` getter) + `tool/advisor_proxy/advisor_proxy.dart:3719-3729` (wiring through `ProxyRuntimeGauges.ringBufferKeyCountGauge`) + envelope inclusion in `/health` payload. | Present. |
| 403 / scope-less acceptance log in `requireOperatorContext` | `tool/advisor_proxy/advisor_proxy.dart:2184-2204` (rejected) + `:2206-2216` (accepted). | Present (Section 1). |
| Typed-catch at the 12392 site | New location after additions: `tool/advisor_proxy/advisor_proxy.dart:12558-12576`. Bare `catch (_)` replaced with `catch (error, stack)` + structured log `proxy.auth.session_ledger_record_login_failed` (error_type, stack_first_frame, user_id, operator/location id presence flags). | Present. |
| Typed-catch at the 12421 site | New location: `tool/advisor_proxy/advisor_proxy.dart:12601-12620`. Bare `catch (_)` replaced with `catch (error, stack)` + structured log `proxy.auth.lockout_record_success_failed`. | Present. |

All six items match A1 §2.4 / §1.5 to the letter. The `/health` envelope correctly emits the new `runtime_gauges` field only when at least one collector is wired (`advisor_proxy.dart:3704-3717`) — keeps existing test assertions green.

One observation, not a finding: the `ProxyRuntimeGauges` cast to `PackagePostgresPool` (`main.dart:632-635`) is null-tolerant — if a future bootstrap rework swaps in a different `PostgresPool` implementation, the gauge silently returns null and `/health` omits the section. Comment at `:619-626` documents this. Good defensive shape.

### 4. B2 — soak harness files — CLEAN

`tool/pressure/p4_session_soak.dart` (+611 lines):
- CLI flags: `--proxy-url`, `--ops`, `--concurrency`, `--duration`, `--output-dir`, `--think-ms`. Defaults: ops=5, concurrency=5, duration=60s. Matches the existing `p3*` parsing pattern (`_parseArgs` at `:115-166`).
- `--duration` accepts `s` / `sec` / `min` / `m` / `h` via shared `parseSoakDurationSeconds` (`p4_session_record_predicate.dart:152-170`).
- SIGINT shutdown via `SoakShutdownSignal` (shared helper at `p4_session_record_predicate.dart:187-195`) wired at `p4_session_soak.dart:462-467`. Workers drain via `Future.any(...)` at `:546-551`.
- `SessionRecordCompleteness.assertComplete` invoked on every 200 response (`:331-345`); incomplete records produce a `SoakFinding` at `:486-500` and exit code 3 at `:601-604`. Every 7th synthetic operator is `ff_support` to exercise the new contract branch (`:434-448`).
- Shape mirrors `p3a_webhook_flood.dart` (JSONL raw + findings + Markdown summary, preview-URL guard via `kSoakAllowedHostSubstrings`).

`tool/pressure/p4_operator_day_soak.dart` (+596 lines):
- Same CLI flag shape, same SIGINT shutdown, same finding sink.
- Full workload: sign_in → dashboard (`GET /v1/auth/account`) → notifications (`GET /v1/operator/notification-preferences`) → settings_nav (`GET /healthz` stand-in) → sign_out (`POST /v1/auth/session/refresh`). See `:404-491`.
- Multi-step integrity guard at `:436` — downstream steps execute only if sign_in returned 200. Prevents harness from amplifying garbage traffic on broken auth.
- Realistic ±25% jittered think-time at `:494-501`. Default 1500 ms (vs session-soak's 500 ms) reflects the heavier journey shape.
- Predicate assertion on sign_in step at `:418-428`. Other steps record latency + status but don't run the session-record predicate (they're not sign-in responses).

`tool/pressure/p4_session_record_predicate.dart` (+195 lines):
- `SessionRecordCompleteness.assertComplete` (`:70-103`) correctly enforces the two-mode contract: tenant-scoped (all four non-empty) vs global-admin (`session_id` + `user_id` non-empty, `operator_id` + `location_id` MUST be empty strings; non-empty triggers `unexpectedFields`).
- Mixed-role tokens (`{'ff_support', 'advisor.read'}`) light up the global-admin branch — defensive contract pin in the test (`p4_session_record_predicate_test.dart:108-124`).
- `kSoakAllowedHostSubstrings` (`:175-180`) covers `forge-flow-preview-`, `forge-flow-staging-`, `localhost`, `127.0.0.1`. Refuses anything else. Test coverage at `p4_session_record_predicate_test.dart:166-191`.
- No false positives observed in either smoke run.

`test/pressure/p4_session_record_predicate_test.dart` (+192 lines):
- 8 predicate tests + 2 duration-parse tests + 2 URL-guard tests. All 12 pass (smoke evidence file).
- Predicate tests cover: tenant happy path, tenant missing operator, tenant missing user+location, ff_support happy path, ff_support unexpected operator, super_admin happy path, mixed-role admin, missing session_id in both modes.
- Branch coverage: tenant-scoped + global-admin × {happy, missing required, unexpected populated}. Complete.

### 5. B2 — smoke runs — CLEAN (no target URL, harness loop exercised)

No target proxy was available, so smoke runs hit `http://localhost:8080` (in the allow-list) with no listener. Both harnesses exercised the request loop without crashing and returned `EXIT_CODE=0`. Detail in `pr_476_smoke_run_evidence.txt`.

| Run | Duration | Total requests | 2xx | 5xx | Network errors | Incomplete 200 | Exit |
|---|---|---|---|---|---|---|---|
| `p4_session_soak` | 30s | 24 | 0 | 0 | 24 | 0 | 0 |
| `p4_operator_day_soak` | 30s | 18 (step requests) | 0 | 0 | (n/a) | 0 | 0 |

The harnesses don't emit p50/p95 latency in the summary — improvement opportunity, not blocking. The shape matches `p3*` output style (plan banner → checkpoint lines on long runs → final summary table). For a real validation, the operator needs to supply a preview-env URL; the harness will refuse anything not on the allow-list (verified by URL-guard tests).

Recommendation: **before final merge**, run both harnesses for ≥5 minutes against a live preview proxy with a synthetic verifier wired (per the comment at `p4_session_soak.dart:43-52`). Today's local smoke proves the harness shape; the contract assertion needs a real 200 to fire.

### 6. `dart analyze` — CLEAN

`dart analyze` on all 10 source/test files (`tool/advisor_proxy/main.dart`, `tool/advisor_proxy/advisor_proxy.dart`, `lib/infrastructure/persistence/postgres/package_postgres_executor.dart`, `lib/services/realtime/google_cloud_pubsub_subscriber.dart`, 3 × `tool/pressure/p4_*.dart`, 2 × `test/...` files):

```
No issues found!
```

Detail in evidence file.

### 7. Existing test suite — CLEAN

- `test/advisor_proxy_test.dart`: 218 / 218 pass (including the 4 new B1 contract tests). Evidence in smoke-run log.
- `test/pressure/p4_session_record_predicate_test.dart`: 12 / 12 pass.

### 8. Out-of-scope creep — CLEAN

`git diff --name-only origin/master...HEAD` shows exactly 11 files:

```
docs/_execution/b1_b2_proxy_soak_fix/01_execution_slice.md
lib/infrastructure/persistence/postgres/package_postgres_executor.dart
lib/services/realtime/google_cloud_pubsub_subscriber.dart
test/advisor_proxy_test.dart
test/load/pressure/README.md
test/pressure/p4_session_record_predicate_test.dart
tool/advisor_proxy/advisor_proxy.dart
tool/advisor_proxy/main.dart
tool/pressure/p4_operator_day_soak.dart
tool/pressure/p4_session_record_predicate.dart
tool/pressure/p4_session_soak.dart
```

Verified:
- No files outside the named scope (no admin UX, mobile, schema, RLS migrations, vendor connectors).
- No `.githooks/` edits in this PR (the earlier `f58362ab` / `aac1a3d2` `.githooks` commits in the branch's ancestry have already been merged to `origin/master` via PRs #474/#475 — they don't appear in this PR's diff).
- No auto-generated Flutter files (`windows/flutter/generated_*`).
- No unrelated cleanup or refactor — every change has a documented A1/R3 anchor.

PR description's stated stat ("10 files, +2096/-24") is off by one file (+95 lines) because the slice plan doc landed in the second commit (`fc1a3f80`). Cosmetic.

### 9. HP #4 spot-check — CLEAN

Sampled non-support routes that call `requireOperatorContext`:

- `tool/advisor_proxy/advisor_proxy.dart:9008-9028` (audit chain anchors). Receives `scope` (potentially with empty operatorId/locationId for a global admin) and passes to `AuditChainAnchorsRouter.handle(operatorId, locationId, userId)`. Empty strings would not authorize a write — the downstream router uses operator_id in the WHERE clause; empty would match no rows, not all rows. Per-operator isolation preserved.
- `tool/advisor_proxy/advisor_proxy.dart:11929` (operator surface). Same pattern. The carve-out only widens "who can pass the JWT gate"; it does not widen "what tenant a request can touch." Downstream routes that require a real tenant either:
  1. Fail closed when `scope.operatorId.isEmpty` (because the DB layer's `WHERE operator_id = $1` matches nothing), or
  2. Use `_effectiveAdminAuthScope` (`:16864`) to require an explicit override from request body/query.

This is the right shape. A global admin without picking a tenant cannot execute writes against a real operator's data. The carve-out is tight to `ff_support` + `super_admin` (`advisor_proxy.dart:2261-2266`). HP #4 holds.

Aligned with `docs/contracts/hardening_rls_and_repository_pattern_contract.md`'s repository-pattern guardrail (operator scope must reach the repository as the first filter): the carve-out widens entry-side authentication only; the data-access path still depends on a non-empty `operator_id` from either the JWT OR the explicit admin override.

### 10. Slice plan accuracy — CLEAN (minor doc gap)

The slice plan at `docs/_execution/b1_b2_proxy_soak_fix/01_execution_slice.md` matches the implementation:
- All file counts and line counts line up with the diff.
- All A1 instrumentation items are claimed and present.
- Audit checklist (`:74-85`) accurately mirrors the contract reads done here.

**Doc gap (non-blocking but recommended):** the slice plan does NOT mention the client-side `proxy_auth_session_ledger_writer.dart` parser. A1 §1.1 cited it as the symmetric half of the contract bug. The slice plan asserts "Option A" closes Bug 1, but Option A is incomplete without the client-side change. The slice plan would benefit from one of:
- A "deferred follow-up" note acknowledging the client-side parser still needs the same role-aware contract update, OR
- Including the client-side change in this PR's scope.

The audit checklist item "Verify the contract change doesn't break the existing operator-scope path for normal users" is satisfied (`requireOperatorContext` still 403s for non-admin scope-less tokens — Section 1 confirmed by the new tests). But the inverse — "Verify the contract change actually delivers the operator-facing fix for ff_support/super_admin users" — has no checklist item, and the client-side hole means the answer is "no, not end-to-end."

---

## Smoke-run output summary

| Harness | Duration | Exit | assertComplete failures | Unhandled exceptions |
|---|---|---|---|---|
| `p4_session_soak` | 30s @ ops=2, conc=2 | 0 | 0 | 0 |
| `p4_operator_day_soak` | 30s @ ops=2, conc=2 | 0 | 0 | 0 |
| `dart analyze` | n/a | 0 | n/a | n/a |
| `flutter test predicate` | n/a | 0 | 12/12 pass | 0 |
| `flutter test advisor_proxy` | ~2s | 0 | 218/218 pass | 0 |

Sample line from p4_session_soak summary:
```
| Total requests | 24 |
| network errors | 24 |
| **incomplete 200 records** | 0 |
| Findings: 0 |
```

Full transcript in `pr_476_smoke_run_evidence.txt`.

**Caveat:** smoke runs hit `http://localhost:8080` with no listener — the harness loop and shutdown path were exercised, but the contract assertion never fired against a real 200. A 5-minute run against a live preview proxy (with the synthetic verifier wired per `p4_session_soak.dart:43-52`) is the proper validation; today's smoke proves the harness shape but not the assertion against real traffic.

---

## Follow-up items

| Item | Blocking? | Owner |
|---|---|---|
| **Client-side parser fix in `proxy_auth_session_ledger_writer.dart`**: `_recordFromLoginResponse` (`:373-400`) and `_validateLoginScopeEcho` (`:402-425`) must accept empty `operator_id` / `location_id` when the caller's `AuthSession.roles` include `ff_support` or `super_admin`. Without this, the proxy fix doesn't deliver the operator-facing Bug 1 fix. | **MERGE-BLOCKING** | Either extend this PR or new slice. |
| Add a client-side test covering the global-admin response shape (proxy returns empty scope → client builds AuthSession with empty operator/location, no `malformed_response` throw). Goes in `test/proxy_auth_session_ledger_writer_test.dart`. | Merge-blocking (companion to the fix above) | Same slice. |
| End-to-end smoke against a live preview proxy with a synthetic verifier wired, running both p4 harnesses for ≥5 minutes. Validates that the harness's assertComplete path fires against real 200 responses and surfaces a finding if the contract is violated. | Post-merge | Operator. |
| Slice plan addendum noting the client-side hole (or its fix). | Post-merge | Same hand that fixes the client. |
| The harness output could include p50/p95 latency in the summary table. Not in R3 §3 quick-win scope; future polish. | Post-merge | Future slice. |
| Two empty `catch (_)` in `ProxyRuntimeGauges.snapshotJson` at `advisor_proxy.dart:3692, 3704` — these are deliberate ("collectors must not destabilize /health") and emit `{error: '...'}` placeholders. Acceptable for this surface but worth typed-catching in a future bare-catch sweep (consistent with the existing 16-site debt at `POST_HARDENING_FOLLOWUPS.md:430-439`). | Post-merge | Bare-catch sweep slice. |

---

## Citations

All code citations are to the worktree at `C:/Git Local Repos/forge_flow_demo/.claude/worktrees/b1-b2-proxy-soak-fix` as of `c3f1ce0d`/`fc1a3f80`. Line numbers above are post-diff (the new B1 fix shifts later line numbers; the 12392/12421 sites cited by A1 are now at 12558/12601 in this branch — verified content-side).

Source documents:
- `docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md` (B1 + B2).
- `docs/_audits/code_health/a1_proxy_bug_root_cause.md` (A1 §1, §2, §1.5, §2.4).
- `docs/_research/post_codex/r3_soak_pressure_testing.md` (R3 §2, §3, §5).
- `docs/_execution/b1_b2_proxy_soak_fix/01_execution_slice.md` (PR's slice plan).
- `CLAUDE.md` HP #4 (per-operator isolation) — Section 9 spot-check.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — Section 9.

---

## Auditor's note

This PR is high-quality engineering on the proxy half and the soak harness. The B2 instrumentation kit (runZonedGuarded + 5 other items) ships exactly as A1 specified, and the soak harness is a faithful continuation of the `p3*` shape with two harnesses + a shared predicate + comprehensive unit tests. The only material gap is that B1's stated goal — stop the operator-observed `AuthLoginFailure(code: 'ledger_unavailable')` — needs the matching client-side parser change to be delivered end-to-end. That change is small (2 sites in 1 file + a test), cleanly bounded, and naturally pairs with this PR. If extended inline, the verdict flips to `approve-for-merge`.
