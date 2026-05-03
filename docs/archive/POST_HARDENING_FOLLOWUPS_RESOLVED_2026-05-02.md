# POST_HARDENING_FOLLOWUPS — Resolved Items (Archived 2026-05-02)

These are the items from `docs/POST_HARDENING_FOLLOWUPS.md` that were
fully resolved during the 2026-05-02 sprints (PRs #50–66) and are
archived here so the live tracker stays focused on open work.

Resolution evidence is preserved verbatim. Refer back here when
auditing the slices that closed each item.

| Item | Resolved by | PR |
|---|---|---|
| P1 — `proxy_requests` / `feature_flags` RLS depth | slice `9.0Σ.l` (migration `202605021500`) | #51 |
| P1 — Migration cutoff lint + runbook companion | scripts/postgres_staging_setup.ps1 + runbook refresh | #51 + #55 |
| P2 — `11A.3a` operator-picker | new `/operator-picker` modal | #50 |
| P2 — Admin idempotency-key on three gateways | shared `_runAdminIdempotent` over `admin_request_idempotency` | #53 |
| P2 — MFA test coverage (test/mfa parcel + adapter parcel) | 47 + 12 + 3→15 tests | #52 + #56 |
| P2 — Postgres repository tests (10 of 29 surfaces) | L2 (5) + L4 batch 2 (5) | #57 + #62 |
| P3 — Phase 11b retrieval assumption | corrected inline | n/a |

The current live tracker is at `docs/POST_HARDENING_FOLLOWUPS.md`.

---

## 2026-05-03 Follow-up Cleanup

These resolved items were removed from the live follow-up file during the
2026-05-03 docs/code audit so the next execution sees only open work.

| Item | Resolved by | Evidence |
|---|---|---|
| P1 - Corpus graph candidates 503 | Sanitized candidate artifacts packaged into the advisor proxy runtime path | `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md` |
| P1 - Staging `audit_chain_lag_seconds` red | Action-approved staging audit-anchor run `forge-flow-audit-anchor-zmsvj` anchored the 2026-05-02 chain | `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md` |
| P2 - MFA test coverage row | MFA test parcels had already closed and were archived in the 2026-05-02 batch | this archive, P2 MFA sections |
| P3 - HARD-D `admin_idempotency_cache` name drift | `docs/contracts/hardening_feature_flag_idempotency_contract.md` now names HARD-H `admin_request_idempotency` as the shipped durable backstop | `db/migrations/202605021000_phase_hardh_admin_idempotency.sql` |

---

## P1 — `proxy_requests` and `feature_flags` lack RLS enable — RESOLVED 2026-05-02 (slice 9.0Σ.l)

Both tables (created in `202604250005_advisor_cloud_foundation.sql`) carry
operator scope. The original audit prose said RLS was never enabled, but
re-reading the cloud-foundation migration shows RLS *was* enabled —
both tables carried permissive `*_service_role_all using (true)` stubs
that did not assert tenant isolation. Today's posture was therefore
application-layer only — `OperatorScopedRepository` injects the tenant
predicate, and the database-side policies allowed everything for the
service_role grant. The actual gap was the policy bodies, not the
RLS enable.

Resolution: `db/migrations/202605021500_phase_9_0sigma_l_rls_depth.sql`
re-asserts RLS on both tables (idempotent on top of 202604250005),
drops the permissive stubs, and adds wrapper-based per-tenant policies
that fold into the tenant-leading PK / partial unique indexes:

- `proxy_requests_tenant_isolation`: `(operator_id, location_id) =
  (wrapper, wrapper)` — folds into the `(operator_id, location_id, …)`
  PK from `202604250007_advisor_rls_index_hardening.sql`. No index
  changes were needed; `proxy_requests` already had tenant-leading PK
  + the `(operator_id, location_id, idempotency_key)` UNIQUE +
  `(operator_id, location_id, created_at)` index from 11a.11c.6.
- `feature_flags_global_or_tenant`: `op IS NULL OR op = wrapper` for
  USING (so launch-wide kill switches stay readable from every tenant
  context); `op IS NOT NULL AND op = wrapper` for WITH CHECK (tenants
  cannot mutate global rows; super_admin paths elevate to forge_admin).

Index posture compliance: both tables already lead every B-tree index
with `operator_id` (or with the partial-index pattern for
`feature_flags`); this slice ships zero new index DDL. The original
"no indexes on proxy_requests" claim in the audit was incorrect —
that index audit was settled in 11a.11c.6.

Test coverage:
- `test/migrations/202605021500_rls_depth_test.dart` — local-framework
  shape coverage (RLS enabled, stubs dropped, wrapper-based policies
  present, no bare GUC reads).
- `test/phase_9_0sigma_rls_isolation_sweep_test.dart` — extended to
  include both tables in the live cross-tenant SELECT/INSERT/UPDATE/
  DELETE sweep (passive-by-default; runs only with
  `FORGE_FLOW_RUN_STAGING_RLS_SWEEP=true`).

## P1 — Migration cutoff lint bumped, runbook companion updated — RESOLVED 2026-05-02

`scripts/postgres_staging_setup.ps1` line 49 cutoff bumped to
`202605021500_phase_9_0sigma_l_rls_depth.sql` (slice 9.0Σ.l).
`runbooks/phase_9_production1_migration_apply_runbook.md` was refreshed in
the same window: the `Updated` header now reads 2026-05-02; the Scope and
Apply Order blocks list the 22 pending migrations (lex order, matching the
P0 inventory above); dependency notes call out the same-timestamp lex pairs
(`...010000_3a_corpus` before `...010000_4_provider`; `...020001_3b_graphify`
before `...020001_4b_gemini`), the `4 → 4b/4c` provider_credentials
ordering, and the wrapper-foundation / RLS-depth dependencies on the prior
batch. The 2026-04-29 historical block was preserved under a new
`Apply History` section but rephrased to reference slice names rather than
the prior numeric cutoff so a grep for stale sentinels comes back clean.

## P2 — Phase 11A.3a operator-picker — RESOLVED 2026-05-02 (PR #50)

`11A.3a` corpus upload / diff / rollback shipped earlier. The Graph
candidate commit button has been unblocked by the operator-picker
modal at `/operator-picker`: cascading operator → location dropdowns
over `OperatorLocationAdminGateway`, session-scoped state hold, and a
green "Targeting <X>" indicator once a pair is resolved.
`targetOperatorId` / `targetLocationId` now thread into corpus gateway
calls. Corpus admin is launch-grade.

## P2 — Admin idempotency-key gap on three gateways — RESOLVED (L4, 2026-05-02)

`operator_location_admin_gateway.dart`, `pricing_tier_admin_gateway.dart`,
`integration_admin_gateway.dart` now thread an `idempotencyKey` field
through every mutating command shape (POST/PATCH/PUT/DELETE) and forward
it as the `Idempotency-Key` request header. The screens mint a fresh key
per user action (UUID-shaped via the screen state, with a
`idempotencyKeyFactory` injection point for widget tests). Proxy side,
`_routeOperatorLocationAdmin`, `_routePricingAdmin`, and
`_routeIntegrationsAdmin` now wrap each mutating arm in a shared
`_runAdminIdempotent` helper that reserves → runs → completes against
`public.admin_request_idempotency` (HARD-H table). The shared helper
mirrors the inlined toggle handler envelope at
`tool/advisor_proxy/advisor_proxy.dart:_routeFeatureFlagsAdmin`.

The header is OPTIONAL on the wire for back-compat with the existing
test surface; when present + the store is wired, dedup engages. Empty
keys bypass dedup. Keys longer than 200 characters get a 400
`idempotency_key_too_long` envelope at the dispatch site (matches the
toggle contract).

**MFA — partially resolved 2026-05-02 (L5).** New `test/mfa/` parcel
adds:

- `test/mfa/firebase_mfa_enrollment_service_test.dart` — boundary
  contract: arg forwarding, payload projection, factor-id resolution
  (firebase_factor_uid wins; non-string / empty / missing falls back),
  failure verbatim, replay rejection, adapter-error rethrow.
- `test/mfa/mfa_recovery_request_attempts_test.dart` — gateway email
  normalization, invalid_email/400, rate-limit 429 with retryAfter,
  silent (queued=false) responses for unknown / no-admins / no-location
  targets, happy-path outbox enqueue, scaffold-failing 503, plus
  in-memory rate-limiter rolloff + blank-IP collapse + email-cooldown
  retryAfter.
- `test/mfa/mfa_removal_worker_test.dart` — empty batch, multiple due,
  Firebase admin failure isolated to one row, `markCompleted=0` race
  skips audit/outbox, `workerOwner` propagation, optional outbox
  graceful-degrade, `batchSize` plumbing.
- `test/mfa/mfa_factor_verifier_test.dart` — Sha256RecoveryCodeHasher
  output length / determinism / symmetric verify / JSON round-trip /
  degenerate inputs / mismatched-length short-circuit; consumer
  lowercase+dashed match, whitespace-Invalid burns budget, multi-factor
  single-match, malformed-metadata silently skipped; limiter 59/61s
  per-minute boundary + 4/5 daily-budget boundary + resetsAt formula.

47 tests, `flutter analyze --fatal-infos` clean.

**MFA adapter parcel — RESOLVED 2026-05-02.** Closes the proxy +
identity-toolkit gap left over from L5:

- `test/mfa/proxy_mfa_recovery_request_gateway_test.dart` (NEW, 12
  tests) — 202 envelope (queued / request_id with non-string +
  whitespace edge cases), non-202 error envelope (default +
  populated), URL composition, header isolation (no Authorization),
  reason/email forwarding verbatim.
- `test/identity_toolkit_firebase_mfa_client_test.dart` (extended
  3 → 15 tests) — 4xx/5xx error envelope, INVALID_ID_TOKEN /
  SECOND_FACTOR_EXISTS / TOO_MANY_ATTEMPTS_TRY_LATER stable code
  paths, mfa_finalize_missing_id_token / mfa_lookup_missing_totp
  failure paths, single-attempt no-retry posture on 5xx,
  listTotpFactors / unenrollFactor coverage, Content-Type pinning.

Both adapters now boundary-tested locally; live contract drift remains
covered by `mfa_live_binding_test.dart` / `auth_live_binding_test.dart`.

**Remaining MFA gaps:** none locally testable after this parcel; live
Identity Toolkit / proxy contract drift is owned by the live-binding
suites above. No production code changed; no bugs surfaced.

**Postgres repositories — partially resolved 2026-05-02 (L2 + L4
batch 2).** Two parcels under
`test/infrastructure/persistence/postgres/repositories/` now cover
10 high-priority surfaces (chosen by tenant-isolation / audit-chain
criticality). L2 (PR #57) shipped the first 5; L4 batch 2 ships the
next 5 (locations, roles, role_permissions, mfa_factors,
mfa_factor_removal_requests — 79 tests across 5 new files,
`flutter analyze` clean, no production code changed). 149 tests
across 11 files in the directory total; previous parcels regression-
free.

- `audit_logs_repository_test.dart` (341 lines) — SHA-256 chain
  inputs (no client-side `prev_row_hash` / `row_hash` — the BEFORE
  INSERT trigger computes both), `actor_kind` never-NULL guard at
  the API surface AND in the SQL column list, `operator_id` RLS
  posture (`writeRow` runs in caller's tx, no SET LOCAL emitted by
  the repo), and `AuditLogsCutoverFlag` resolver shapes — pinning
  the **default-ON** behavior of the production resolver vs the
  KMS rollout flag's default-OFF so a future refactor cannot
  silently flip them. Companion to the existing
  `test/repositories/audit_logs_repository_test.dart` (`writeRow`
  parameter shape).
- `event_outbox_repository_test.dart` (452 lines) — `markDelivered`
  shape (HARD-H backlog drain seal: `delivered_at IS NULL`
  idempotency guard, affected-row reporting), `claimBatch(topic:)`
  filter (HARD-H consumer isolation — filter inside the inner CTE
  so single-topic consumers don't lock other-topic rows), payload
  normalization edges (`Map<dynamic, dynamic>`, empty-string,
  malformed → `StateError`), defensive RETURNING-id guards
  (non-string / empty → `StateError`). Companion to
  `test/phase_9_0sigma_e_event_outbox_test.dart` (core enqueue +
  claim SQL contract).
- `operators_repository_test.dart` (668 lines) — `listOperators`
  cross-tenant sweep (no `where operator_id` predicate, ordered by
  `business_name` for stable admin grouping), `suspendOperator`
  idempotency (`coalesce(suspended_at, now())`), `reactivateOperator`
  unconditional `null`, `onboardOperatorAtomically` 3-statement
  ordering (insert operator → insert location → UPDATE operator
  with primary_location_id) and rollback semantics for each step's
  empty-RETURNING failure mode, plus `withSystem` audit-marker
  shape (`system:<reason>`) and `set local role forge_admin`
  elevation pinning. First canonical-path coverage for this repo.
- `user_roles_repository_test.dart` (648 lines) — scope-payload
  CHECK enforcement (six rejection paths covering every illegal
  combination across `operator_wide` / `org_unit` / `location` ×
  null-vs-non-null `grantLocationId` / `grantOrgUnitId`, plus three
  happy paths), `roles_version` bump atomicity (insert success →
  bump runs, RLS-denied insert → bump skipped, revoke
  affected-row > 0 → bump runs, revoke affected-row = 0 → bump
  skipped), `bumpActiveGrantHoldersForRole` EXISTS-subquery shape
  (active-grant filter so revoked / expired grants don't trigger
  bump fan-out), tenant predicate folding via observed SET LOCAL
  ordering, and `UserRoleScope` value-object conversions
  (`sqlKey` round-trip, unknown rejection, legacy
  `fromGrantLocationId` convention). First canonical-path coverage
  for this repo.
- `usage_caps_repository_test.dart` (422 lines) — two-slot UNIQUE
  NULLS NOT DISTINCT upsert targeting the named constraint
  (`usage_caps_two_slot_uq` — by name, not column list, so a
  migration rename surfaces as a hard test failure); `DO UPDATE`
  preserves `created_by` while rewriting `updated_by` (audit
  trail keeps original creator); NULLS NOT DISTINCT collision
  relies on the literal `null` reaching the bind (no sentinel
  coercion that would defeat the constraint dedup); `withSystem`
  audit-marker pinning. First canonical-path coverage for this repo.

L4 batch 2 (2026-05-02) added 5 more surfaces; all run through
`OperatorScopedRepository` so the SET LOCAL ordering / withSystem
posture is pinned per file:

- `locations_repository_test.dart` (620 lines) — IANA `business_timezone`
  round-trip parametric on INSERT + UPDATE (no concatenation, no
  normalization); `business_day_rollover_hour` 0/23 boundary
  preserved through coalesce; cross-operator isolation via
  `withSystem` + `set local role forge_admin` + canonical
  `system:<reason>` audit marker; `listForOperator` filters
  `operator_id`, `listAllLocations` carries no predicate;
  `deleteLocation` requires BOTH location_id + operator_id so a
  stale id cannot land on the wrong tenant. First canonical-path
  coverage for this repo.
- `roles_repository_test.dart` (687 lines) — per-row monotonicity
  (`updated_at = now()` + `updated_by` rewrite on every UPDATE);
  tenant SET LOCAL ordering precedes every read/write (no admin
  BYPASSRLS path); visibility split (`listVisibleRoles` orders
  globals first, operator-scoped second); operator-scoped role-key
  precedence over global on `roleIdForVisibleKey`; `is_seeded` SQL
  literal in `insertOperatorRole` so the bind cannot lift a custom
  role to seeded posture; `updateOperatorRole` guards
  (`is_seeded=false AND is_editable=true AND deleted_at is null`);
  `softDeleteOperatorRole` active-grants probe in the SAME
  transaction (race with concurrent grant insert rolls back
  cleanly). First canonical-path coverage for this repo.
- `role_permissions_repository_test.dart` (581 lines) — `effect`
  allowlist (synchronous ArgumentError on
  `'neutral'` / empty / mixed-case `'Allow'` before tx open);
  permission_key catalog round-trip parametric for representative
  keys from each category (product/forgeflow/admin/team) plus a
  catalog-count smoke test (96 keys today — drift from
  `auth_permission_key_catalog.md` surfaces here);
  cross-tenant denial via tenant SET LOCAL (no forge_admin
  escalation path); INSERT ON CONFLICT (role_id, permission_key)
  DO UPDATE preserves `created_by` while rewriting effect /
  updated_by / updated_at. First canonical-path coverage for this
  repo.
- `mfa_factors_repository_test.dart` (785 lines) — factor_type
  allowlist (`'totp'` / `'recovery_code'` bound as SQL literals so
  the schema CHECK admits exactly the supported values);
  operator + user double-scope SET LOCAL ordering on every method;
  `insertTotpEnrollment` metadata `firebase_factor_uid` + `issuer`
  jsonEncode round-trip; `ensureTotpFactorForFirebaseUid` repair
  path (idempotent reuse + `firebase_inventory_repair` source
  marker); `markRecoveryCodeUsed` single-use seal (BOTH
  `last_used_at` AND `revoked_at` advance under the
  `factor_type='recovery_code'` guard); `revokeTotpFactor` does
  NOT advance `last_used_at` (revoke is removal, not verify);
  `revokeActiveRecoveryCodeFactorsForUser` idempotent via
  `coalesce(revoked_at, now())`; metadata projection handles
  String / Map / malformed-JSON inputs. First canonical-path
  coverage for this repo.
- `mfa_factor_removal_requests_repository_test.dart` (864 lines)
  — state transitions (pending → completed / cancelled /
  pending-with-last_error retryable); `insertPending` upsert
  idempotency on `(operator_id, user_id, factor_id)` partial
  unique while pending; expiry contract on TWO axes
  (`execute_after <= @now` for the 24h delay window;
  `staleAfter` lease for stuck workers, bound as
  `@stale_seconds * interval '1 second'`);
  `claimDuePending` CTE uses `for update skip locked` under
  `withSystem` with the canonical
  `system:system.mfa_factor_removal_worker_claim` audit marker
  (Cloud Tasks-equivalent locking pattern, since pgmq is not
  available on Azure DB Flexible Server); `markCompleted`
  clears last_error + processing_*; `markFailed` clears
  processing_* but never advances completed_at / cancelled_at
  (failures stay in pending so the worker re-claims); workerOwner
  ArgumentError on blank/whitespace; limit ArgumentError on
  non-positive. First canonical-path coverage for this repo.

**Remaining postgres-repository gaps:** 18 of 29 surfaces still
without canonical-path unit tests when counted strictly by
`test/infrastructure/persistence/postgres/repositories/` location.
Most have non-canonical unit tests at `test/repositories/` or
`test/<repo_name>_test.dart` (`corpus`, `feature_flags`, `graph`,
`provider_credentials`, `recovery_code_attempt_store`,
`service_principals`, `users`, `auth_login_attempts`) or
phase-prefix tests (`auth_events_audit` via cutover test); a smaller
set (`auth_invites`, `auth_sessions`, `invited_user_activation`,
`password_history`, `advisor_conversation_log`,
`mfa_recovery_request_attempts`, `operator_admins`, `org_units`)
appears only inside larger live-binding / gateway test files as
fixtures, not under direct unit-test coverage.
`user_scoped_repository.dart` is a base class covered indirectly by
`test/operator_scoped_repository_test.dart`. Chip away the
canonical-path migration during routine slices that touch each repo;
treat the indirect-only group as the highest priority for direct
unit-test coverage.

## P3 — Phase 11b retrieval assumption fixed inline

The Phase 11b plan referenced direct pgvector retrieval; corrected in this
audit to point at the Modular Adaptive Agentic RAG stack from
`phase_11a_decision_register.md`. No code follow-up needed.
