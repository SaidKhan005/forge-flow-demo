# PR #490 Audit — Harden admin audit target attribution

**Verdict: approve-for-merge**
**Light playbook** (16 files / 1343 LoC under the 20-file / 5K-LoC threshold)

**Audited HEAD**: `b462798e0be220dc62dae8d3aad69a7f2a70d238`
**Master HEAD at audit time**: `2cf37475`
**PR stack**: PR #490 is the third in the 3-PR plan (after PR C #484 — audit-log contract schema, and PR B #488 — admin hierarchy lifecycle access hardening). Base reported by GitHub is `codex/admin-hierarchy-lifecycle-access-hardening` (PR #488, already merged); effective diff vs master is the 16-file delta below.

## Scope

PR #490's own stated scope:

1. Require `Idempotency-Key` + non-empty `admin_reason` on admin / operator-location `POST` / `PATCH` / `DELETE` before mutation routing.
2. Add explicit `targetKind` / `targetId` audit attribution for role, grant, org-unit, location, operator, and operator-location admin actions.
3. Preserve PR C (#484) audit-log contract: canonical `team_member` / `forge_admin` / `service_principal` actor labels, `business_date` denormalization, required `admin_reason` for forge-admin fan-out.
4. Correlate MFA dead-letter outbox payloads by including `request_id` alongside `event_id`.
5. Reconcile `advisor_proxy.dart` + `proxy_bootstrap.dart` against PR #481 / PR #484 (rebase preservation, not regression).

## Per-chunk findings

### Chunk 1 — proxy entry (`tool/advisor_proxy/advisor_proxy.dart` +42/-20, `proxy_bootstrap.dart` +18/-0)

| Finding | file:line | Authority anchor | Status | Recommendation |
|---|---|---|---|---|
| `Idempotency-Key` + `admin_reason` guard placed BEFORE route dispatch; only `GET` exempt | `tool/advisor_proxy/advisor_proxy.dart:14086-14122` | `docs/contracts/team_roles_hierarchy_console_parity_contract.md:55` (Idempotency-Key on every mutation); `:69` (admin_reason REQUIRED for forge_admin) | PASS | No action |
| Stale `$reasonPrefix:onboard` synthesized `admin_reason` replaced by caller-supplied `adminReason!` across 7 mutation paths | `advisor_proxy.dart:14748,14782,14826,14831,14879,14922,14961` | Parity contract `:69,:234` | PASS | No action |
| `_routeOperatorLocationAdmin` signature extended with `String? adminReason` and force-unwrapped at mutation sites — guard at route entry ensures non-null for non-GET so the `!` is safe | `advisor_proxy.dart:14697` | Same as above | PASS | No action |
| `proxy_bootstrap.dart` `_audit` helper threads new `targetKind` / `targetId` into `insertSystemEvent` | `tool/advisor_proxy/proxy_bootstrap.dart:3627-3648` | Parity contract `:67` (`audit_logs.target_kind` + `target_id`) | PASS | No action |
| All 6 admin operator-location event types tagged with explicit `targetKind` / `targetId` (`operator` / `operator_id`, `location` / `location_id`) | `proxy_bootstrap.dart:3402,3446,3479,3503,3536,3571,3617` | Parity contract `:67` | PASS | No action |
| Rebase preservation: `b462798e` is the only commit touching `advisor_proxy.dart` from master → PR (verified `git log 2cf37475..b462798e -- tool/advisor_proxy/advisor_proxy.dart`); diff is purely additive — no PR #481 / #484 regression | `advisor_proxy.dart` (whole file) | `docs/_audits/post_codex_wave/pr_484_audit.md`, `pr_488_audit.md` | PASS | No action |

### Chunk 2 — auth gateway (`lib/services/auth/repository_auth_operations_gateway.dart` +18/-0)

| Finding | file:line | Authority anchor | Status | Recommendation |
|---|---|---|---|---|
| 18-line change is purely additive — 7 audit call sites tagged with `targetKind` / `targetId`; `_audit` helper signature extended | `lib/services/auth/repository_auth_operations_gateway.dart:225-1758` | Parity contract `:67` | PASS | No action |
| Target labels chosen are stable strings — `role`, `user_role`, `org_unit`, `location` — align with parity-contract target_kind enum | `repository_auth_operations_gateway.dart:9,18,27,36,45,54,63` | Parity contract `:141` (`target_kind ∈ enum`) | PASS | No action |
| Auth semantics unchanged — `actorKind: 'user'` preserved; no permission keys mutated; frozen permission catalog untouched | `repository_auth_operations_gateway.dart:1751` | `lib/auth/permission_key_catalog.dart` (frozen), `docs/contracts/auth_permission_key_catalog.md` | PASS | No action |
| New params correctly threaded through `AuthEventsAuditRepository.insertEvent` (`auth_events_audit_repository.dart:143,151-152,218-219`) — override the user-inferred fallback | (cross-file) | Parity contract `:67` | PASS | No action |

### Chunk 3 — MFA worker (`lib/services/mfa/mfa_removal_worker.dart` +1/-0)

| Finding | file:line | Authority anchor | Status | Recommendation |
|---|---|---|---|---|
| Dead-letter outbox payload now carries `request_id` alongside `event_id` (both = `request.requestId`) | `lib/services/mfa/mfa_removal_worker.dart:383-384` | `docs/contracts/core_app_architecture.md` MFA worker / outbox correlation; PR-stated scope #4 | PASS | No action |
| `event_id` is set to `request.requestId` (same as `request_id`) — intentional collapse for dead-letter correlation | `mfa_removal_worker.dart:383-384` | n/a | INFO | No action — matches stated scope |

### Chunk 4 — tests (12 files, +593/-7)

| Finding | file:line | Authority anchor | Status | Recommendation |
|---|---|---|---|---|
| New 400-guard coverage: `POST /v1/admin/operators` → `missing_idempotency_key`; `PATCH /v1/admin/locations/{id}` → `missing_admin_reason` | `test/advisor_proxy_test.dart:5285-5380` | Parity contract `:55,:69` | PASS | No action |
| Existing admin-route tests updated to send `idempotencyKey` + `admin_reason` body across 7 mutation paths | `test/advisor_proxy_test.dart:5183,5381,5421,5481,5544,5583,5621,5661,5712,5762,5810,5847,5887` | Parity contract `:55,:69` | PASS | No action |
| Bootstrap-gateway tests assert `targetKind` / `targetId` propagation on `patchOperator` and `addLocation` | `test/advisor_proxy_bootstrap_test.dart:299-364` | Parity contract `:67` | PASS | No action |
| Cutover test asserts explicit `targetKind` / `targetId` flow into `audit_logs.target_kind` / `target_id` columns instead of user-only inference | `test/repositories/auth_events_audit_cutover_test.dart:58-82` | Parity contract `:67`; PR-stated scope #3 | PASS | No action |
| Org-unit live binding covers `org_unit_created` (`target_kind=org_unit`) and `location_org_unit_moved` (`target_kind=location`) | `test/org_units_repository_live_binding_test.dart:181-241,305-317` | Parity contract `:67` | PASS | No action |
| Role admin live binding covers `custom_role_created` (`target_kind=role`) audit-fan-out | `test/role_admin_live_binding_test.dart:533-562` | Parity contract `:67` | PASS | No action |
| 4 smaller +3-each test files (`admin_audit_extensions_test.dart`, `feature_flags_concurrency_test.dart`, `feature_flags_idempotency_test.dart`, `repository_graph_candidates_proxy_gateway_test.dart`) + 3 audit-fake updates (`mfa_removal_worker_test.dart`, `mfa_operations_gateway_test.dart`, `integration_admin_proxy_gateway_kms_revision_test.dart`) — mechanical signature backfills extending `_AuditFake.insertEvent` / `insertSystemEvent` overrides with new params; necessary to compile | Multiple files | Parity contract `:67` | PASS | No action |
| `_RecordingAuthEventsAuditRepository` in `role_admin_live_binding_test.dart:1064` only records `eventType` / `targetKind` / `targetId` — narrow but consistent with assertions | `role_admin_live_binding_test.dart:1052-1062` | n/a | INFO | No action |

### Chunk 5 — cross-cutting contract verification

| Finding | file:line | Authority anchor | Status | Recommendation |
|---|---|---|---|---|
| `_fanOutToAuditLogs` actor-kind mapping unchanged: `user` / `team_member` → `team_member`, `forge_admin` → `forge_admin`, `service_principal` / `service` → `service_principal` — legacy aliases coexist | `lib/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart:318-323` | Parity contract `:51`; PR-stated scope #3; CLAUDE.md service-principals hard promise | PASS | No action |
| `admin_reason` required for `forge_admin` actor_kind — fan-out throws `ArgumentError` if missing | `auth_events_audit_repository.dart:350-358` | Parity contract `:69`; CLAUDE.md hash-chain hard promise | PASS | No action |
| `business_date` denormalization is owned by the `audit_logs` BEFORE INSERT trigger server-side; `writeRow` does NOT supply `business_date` directly; PR adds no overrides | `audit_logs_repository.dart:97-145` | CLAUDE.md "Time Guardrails" — `business_date` denormalized | PASS | No action |
| Hash chain field order: `audit_logs` columns are stable (`prev_row_hash` / `row_hash` computed server-side by BEFORE INSERT trigger). PR populates existing `target_kind` / `target_id` columns — does NOT add columns or reorder. Chain integrity preserved | `audit_logs_repository.dart:109,132,143-144` | CLAUDE.md "Service principals" — hash-chained audit log SHA-256 via `pgcrypto` | PASS | No action |
| New `targetKind` / `targetId` explicit param falls back to `targetUserId`-inferred `'user'` shape when not supplied — non-breaking for legacy `insertEvent` callers | `auth_events_audit_repository.dart:358-360` | n/a | PASS | No action |

## Drift-from-master observations

- **Pre-existing pattern carry-over (NOT introduced by PR #490)**: `proxy_bootstrap.dart:3640` passes `actorKind: 'user'` for the operator-location admin path. The canonical PR C label for F&F admin actions should be `'forge_admin'` (parity contract `:51`). The fan-out helper then maps `'user'` → `'team_member'` instead of `'forge_admin'`, which means operator-location admin events currently land in `audit_logs.actor_kind = 'team_member'` rather than `'forge_admin'`. **Out of scope for PR #490** (this is PR B / earlier territory) — PR #490's stated scope #3 explicitly says *preserve* PR C contract, not fix this. Tracking suggestion: add to `docs/POST_HARDENING_FOLLOWUPS.md` if not already captured.
- The PR diff against master shows 31 files changed; the 16-file scope here is the PR-only delta against base `01c48921` (PR B head, merged separately). The diff dump matches the scope. The extra 15 files in the master comparison belong to PR B (#488) and were already audited in `pr_488_audit.md`.

## Operator approval gates check

- **Auth**: PASS — no `permission_key_catalog` mutation; no role-grant semantics changed; auth gateway changes are pure audit-attribution pass-through. Anchor: `auth_permission_key_catalog.md` (frozen catalog).
- **Audit log**: PASS — canonical PR C labels preserved; `admin_reason` required for `forge_admin`; hash chain field order immutable; new `targetKind` / `targetId` are populations of existing columns. Anchors: parity contract `:51,:67,:69`; CLAUDE.md hash-chain promise.
- **Proxy contract**: PASS — `Idempotency-Key` + `admin_reason` guards land at route entry before mutation routing; idempotency store handoff (`_runAdminIdempotent`) unchanged; HARD-H pattern matches other admin route guards (`missing_idempotency_key` precedent at `advisor_proxy.dart:9226, 9971, 10065, 10172, 10624`). Anchor: parity contract `:55`; CLAUDE.md "Every proxy write is idempotent."

## Final verdict + reasoning

**approve-for-merge.** Every PR-stated scope item lands cleanly:

1. **Idempotency-Key + admin_reason guard at route entry** — verified at `advisor_proxy.dart:14086-14122`, with stale synthesized prefixes replaced across 7 mutation sites.
2. **Target attribution for role / grant / org-unit / location / operator / operator-location actions** — 7 sites in `repository_auth_operations_gateway.dart` + 7 sites in `proxy_bootstrap.dart`.
3. **PR C contract preserved** — canonical actor labels, `business_date` trigger-side denormalization, `admin_reason` required for `forge_admin`; `targetKind` / `targetId` falls back to legacy user-inference when not supplied.
4. **MFA dead-letter outbox correlates by `request_id` alongside `event_id`.**
5. **Rebase non-destructive** — verified via `git log 2cf37475..b462798e -- tool/advisor_proxy/advisor_proxy.dart` showing PR HEAD is the only commit touching the file from master forward.

Test coverage is comprehensive: new 400-guard tests, target-attribution propagation tests, cutover-flag tests, and signature-backfill plumbing across 8 `_AuditFake` overrides. No authority-anchor violations detected. The one drift observation (operator-location admin path uses `actor_kind = 'user'` instead of `'forge_admin'`) is pre-existing and explicitly out of PR #490's scope.

No findings warrant orchestrator-fix or send-back. Per the 2026-05-13 auto-merge doctrine, this PR is eligible for merge once Codex flips it from Draft → Ready.
