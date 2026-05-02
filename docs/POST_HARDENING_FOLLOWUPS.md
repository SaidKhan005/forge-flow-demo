# Post-Hardening Follow-ups (2026-05-02)

Audit log of items surfaced by the 2026-05-02 deep audit that were **not**
in scope of HARD-A→HARD-H but warrant attention before launch. Each item
has a single owner-suggested next-action; none are launch-blocking unless
flagged.

PRs #50–54 (`7.58.0`/`11A.3a`/`9.0Σ.l`/L4 admin idempotency/L5 MFA tests)
landed 2026-05-02 PM and resolved P1 (RLS depth), P2 (idempotency), P2
(11A.3a operator-picker), and P2 (MFA test coverage to 87.3%).

PRs #55–59 (`7.58.UX.5`/`10.5.0`/L2 postgres repo tests/L4 runbook
companion/L5 MFA adapter parcel) landed 2026-05-02 follow-up: P1 runbook
companion **RESOLVED**; P2 test coverage parcels added (5 postgres repos
+ 2 MFA adapter test files, 82 new tests across the sprint); new
walkthroughs `7.58.UX.5.md` + `10.5.0.md` shipped. Phase 7.58 has zero
DRIFT. Open items below are the remainder.

## P0 — Production1 migration apply gap

**22 migrations pending Production1 apply** (`202604280014` through
`202605021500`). HARD-B/HARD-H, all 11A admin column additions,
B41/B42/B43, the audit privacy role, and Phase 9.0Σ.l (RLS depth on
`proxy_requests` + `feature_flags`) are queued.

Files to apply (lex order):

```
202604280014_phase_9_0sigma_h2_audit_privacy_role.sql            (B46)
202604290000_phase_9_b41_service_principal_issue_permission.sql  (B41)
202604290100_phase_11A_1_operators_suspended_at.sql              (11A.1)
202604290101_phase_9_hierarchy_access_wiring.sql                 (9.0)
202604300000_phase_9_mfa_factor_removal_requests.sql             (9.0)
202604300001_phase_9_mfa_recovery_request_attempts.sql           (9.0)
202604300002_phase_9_mfa_hardening_launch_roles.sql              (9.0)
202605010000_phase_11A_3a_corpus_versions_ledger.sql             (11A.3a)
202605010000_phase_11A_4_provider_credentials.sql                (11A.4)
202605010001_phase_9_b4_role_audit_log_operator_id.sql           (9.0 B4)
202605010100_phase_9_0sigma_f_audit_logs_cutover_flag.sql        (9.0Σ.f)
202605020000_phase_11A_b42_proxy_migrations_applied.sql          (B42)
202605020001_phase_11A_3b_graphify_review_audit.sql              (11A.3b)
202605020001_phase_11A_4b_gemini_provider_kind.sql               (11A.4b)
202605020100_phase_11A_b43_cache_telemetry_v2.sql                (B43)
202605020200_phase_11A_4c_kms_rollout_flags.sql                  (11A.4c)
202605020300_phase_9_firebase_uid_text.sql                       (9.0)
202605020400_phase_11A_7_feature_flags_admin_columns.sql         (11A.7)
202605020452_hardening_auth_login_attempts.sql                   (HARD-B)
202605020500_hardening_auth_rls_to_wrappers.sql                  (HARD-F)
202605021000_phase_hardh_admin_idempotency.sql                   (HARD-H)
202605021500_phase_9_0sigma_l_rls_depth.sql                      (9.0Σ.l)
```

**Action:** schedule a Production1 apply event under existing runbook
(`runbooks/phase_9_production1_migration_apply_runbook.md`) — does NOT
require a new runbook; the lex-order pattern is the same.

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

## P2 — Test coverage gaps

| Surface | LOC | Test files | Line coverage |
|---|---|---|---|
| `lib/services/mfa/` | 2,933 | 5 (`test/mfa/`) + 4 top-level | **>90%** est. (L5+adapter parcel, 2026-05-02) |
| `lib/admin/services/operator_location_admin_gateway.dart` | 311 | 0 | 0% |
| `lib/admin/services/pricing_tier_admin_gateway.dart` | 311 | 0 | 0% |
| `lib/admin/services/integration_admin_gateway.dart` | 311 | 0 | 0% |
| 10 of 29 postgres repositories | ~7,734 | 5 (`test/infrastructure/persistence/postgres/repositories/`, L2, 2026-05-02) + scattered phase-prefix / live-binding | partial |

**Action:** chip away during routine slices; not a launch blocker because
the proxy-level live-binding tests (`mfa_live_binding_test.dart`,
`auth_live_binding_test.dart`) cover the integration paths. Add unit
coverage when modifying any of these surfaces.

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

**Postgres repositories — partially resolved 2026-05-02 (L2).** New
`test/infrastructure/persistence/postgres/repositories/` parcel adds
canonical-path unit tests for 5 high-priority surfaces (chosen by
tenant-isolation / audit-chain criticality). 70 tests across 5 new
files; `flutter analyze` clean. No production code changed.

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

**Remaining postgres-repository gaps:** 23 of 29 surfaces still
without canonical-path unit tests when counted strictly by
`test/infrastructure/persistence/postgres/repositories/` location.
Most have non-canonical unit tests at `test/repositories/` or
`test/<repo_name>_test.dart` (`corpus`, `feature_flags`, `graph`,
`provider_credentials`, `recovery_code_attempt_store`,
`service_principals`, `users`, `auth_login_attempts`) or
phase-prefix tests (`auth_events_audit` via cutover test); a smaller
set (`auth_invites`, `auth_sessions`, `invited_user_activation`,
`locations`, `password_history`, `advisor_conversation_log`,
`mfa_factor_removal_requests`, `mfa_factors`,
`mfa_recovery_request_attempts`, `operator_admins`, `org_units`,
`roles`, `role_permissions`) appears only inside larger live-binding
/ gateway test files as fixtures, not under direct unit-test
coverage. `user_scoped_repository.dart` is a base class covered
indirectly by `test/operator_scoped_repository_test.dart`. Chip away
the canonical-path migration during routine slices that touch each
repo; treat the indirect-only group as the highest priority for
direct unit-test coverage.

## P3 — Unused public classes (4)

- `AuditLogExportResult` (`lib/services/admin/audit_log_csv_export.dart`)
- `MfaOverrideChange` (`lib/services/admin/mfa_policy_editor_controller.dart`)
- `MatrixCellChange` (`lib/services/admin/role_permission_matrix_controller.dart`)
- `CorpusCloudLoadResult` (`lib/services/advisor_corpus_admin_service.dart`)

**Action:** delete on next sweep through each file, or leave in place if
they're forward-compatible API shapes that haven't been wired yet.

## P3 — `admin_request_idempotency` vs `admin_idempotency_cache` name drift

HARD-D's contract appendix referred to a future
`admin_idempotency_cache` table; HARD-H actually shipped
`admin_request_idempotency`. Functionality matches; only the name
diverges. Update the HARD-D contract appendix to use the shipped name on
the next contract refresh (low priority — both contracts are now closed
authority).

## P3 — Phase 11b retrieval assumption fixed inline

The Phase 11b plan referenced direct pgvector retrieval; corrected in this
audit to point at the Modular Adaptive Agentic RAG stack from
`phase_11a_decision_register.md`. No code follow-up needed.
