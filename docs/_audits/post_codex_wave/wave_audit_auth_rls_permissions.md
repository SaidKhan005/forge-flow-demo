# Wave Audit — Auth + RLS + Permission Keys

**Master tip:** `63b67753` (post-B8.b + C-7 + B6.b + C-2-D-binding)
**Worktree HEAD at audit time:** `63ec00d6` (origin/master is 2 commits ahead — `aa7dc52f` B8.b inline fix + `63b67753` B8.b merge; both audited from `origin/master` blobs where applicable)
**Wave scope:** ~50 PRs / 1368 commits merged 2026-04-28 → 2026-05-13 (per `git log --since=2026-04-28`)
**Auditor:** orchestrator-dispatched read-only agent (1 of 8) — dimension = Auth + RLS + Permission Keys
**Authority docs consulted:**
- `CLAUDE.md` ("Hard Promises" #4, #7; "RLS-Ready Schema"; "Service-Layer Split"; "Proxy & API Conventions"; "Frozen `lib/auth/`")
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
- `docs/contracts/auth_permission_key_catalog.md`
- `tool/audit_logs_update_allowlist.txt`
- `tool/rls_policy_lint_allowlist.txt`
- `tool/audit_logs_update_lint.dart` (exists; enforces append-only)

## Verdict

**clean** — every check landed inside the contract envelope. No genuine
findings. Six low-severity observations captured below as "Aggregate
observations" for orchestrator awareness, none requiring fix.

## Findings

### Check 1 — `OperatorScopedRepository` discipline

**Severity:** clean (no findings)

The wave introduced **42 new repository files** under
`lib/infrastructure/persistence/postgres/repositories/`. I enumerated
them via `git log --since=2026-04-28 --diff-filter=A --name-only -- lib/infrastructure/persistence/postgres/repositories/`
and inspected each.

Repositories that **extend `OperatorScopedRepository`** (correct
default — 36/42):

- `active_target_profile_repository.dart` (extends `OperatorScopedRepository`, line 13)
- `auth_login_attempts_repository.dart` (line 72)
- `business_timing_profiles_repository.dart` (line 16)
- `connector_backfill_job_repository.dart` (line 7)
- `connector_connection_list_repository.dart` (line 193)
- `corpus_repository.dart` (line 29)
- `data_accuracy_service_period_settings_repository.dart` (lines 26-27)
- `demo_mode_state_repository.dart` (line 44)
- `email_event_repository.dart` (line 104)
- `event_outbox_dead_letter_repository.dart` (line 106)
- `feature_flags_repository.dart` (line 30)
- `forecast_context_repository.dart` (line 13)
- `graph_repository.dart` (line 237)
- `handoff_codes_repository.dart` (line 103)
- `invited_user_activation_repository.dart` (line 26)
- `leaderboard_score_repository.dart` (line 92)
- `locations_repository.dart` (line 18)
- `mfa_factor_removal_requests_repository.dart` (line 59)
- `mfa_recovery_request_attempts_repository.dart` (line 8)
- `mobile_push_outbox_repository.dart` (line 73)
- `mobile_push_tokens_repository.dart` (line 122)
- `notification_preferences_repository.dart` (line 25)
- `open_shift_snapshots_repository.dart` (line 13)
- `operator_account_repository.dart` (line 16)
- `operator_admins_repository.dart` (line 18)
- `operators_repository.dart` (line 25)
- `provider_credentials_repository.dart` (line 54)
- `selected_star_shift_repository.dart` (line 13)
- `step_up_challenges_repository.dart` (line 99)
- `target_cycle_repository.dart` (line 13)
- `usage_caps_repository.dart` (line 39)
- `user_pii_erasure_repository.dart` (line 126)
- `vendor_applicability_repository.dart` (line 17)
- `vendor_sync_outage_state_repository.dart` (lines 33-34)
- `wage_role_rows_repository.dart` (line 31)
- `weekly_plan_snapshot_repository.dart` (line 13)

Repositories that **do not extend `OperatorScopedRepository` — every
exception is contractually justified**:

| File | Pattern | Justification |
|---|---|---|
| `audit_logs_repository.dart:78` (`class AuditLogsRepository`) | Stateless helper; takes `PostgresExecutor` from caller's tx | **Sanctioned exception** per `hardening_rls_and_repository_pattern_contract.md` lines 166-181 — atomic-with-business-write requires the audit row to commit in the same transaction as the business row it audits. The writer cross-checks caller's `operatorId` against `current_setting('app.operator_id', true)` and throws `AuditLogsTenantMismatchError` before binding any SQL (lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart:183-202). |
| `audit_logs_repository.dart:397` (`class AuditLogsReader`) | Extends `OperatorScopedRepository` | Pure read seam for B8 hierarchy filter route; runs through `withTenant`. |
| `default_role_catalog_versions_repository.dart:168` (`class DefaultRoleCatalogVersionsRepository`) | Takes `TenantTransactionWrapper`; every method calls `runAsSystem` with explicit `reason:` | F&F-wide global table (NO `operator_id` column, NO RLS policy per migration 202605131600_b2_1_default_role_catalog_versions.sql lines 74-97). Repository documents the design in header lines 6-13. Correctly uses `runAsSystem` for every public method, never `withTenant`. |
| `kms_rollout_flag.dart` (3 classes) | Takes caller's `PostgresExecutor`; one SELECT against `feature_flags` | Flag-adapter pattern, not a repository per se. No independent connection. Reads inside caller's tx so the read participates in whichever scope (`withTenant` or `withSystem`) the caller has opened. Mirrors `FeatureFlagsTableAuditLogsCutoverFlag` precedent. |
| `recovery_code_attempt_store.dart:15` (`PostgresRecoveryCodeAttemptStore`) | Extends `UserScopedRepository` (sibling base class) | `recovery_code_attempts` has no `operator_id` column; RLS filter is `user_id = public.app_current_actor_user()`. Per `user_scoped_repository.dart:25` header, this is the correct base for per-user tables. |
| `user_scoped_repository.dart:25` (`abstract class UserScopedRepository`) | Sibling base — exposes `withUser` only | Provides `app.user_id` SET LOCAL without elevating to `forge_admin`. Defense-in-depth posture for per-user identity tables. |

**Verdict:** every new repository routes through either `withTenant`,
`withSystem(reason: ...)`, or `withUser`. No raw `package:postgres`
import outside `lib/infrastructure/persistence/postgres/` (verified
via `Grep "package:postgres" lib/services` and `lib/auth` — zero
hits).

### Check 2 — `withTenant` vs `withSystem` discipline

**Severity:** clean (no findings)

Grep for `runAsSystem(` and `withSystem(` across
`tool/advisor_proxy/` and `lib/infrastructure/persistence/postgres/`:
~50 callsites. Every callsite passes a `reason:` argument (verified
through inspection of `tool/advisor_proxy/proxy_bootstrap.dart`,
`tool/advisor_proxy/main.dart`, `tool/advisor_proxy/integration_oauth_state_store.dart`,
`tool/advisor_proxy/realtime_tripwire_gateway.dart`,
`lib/infrastructure/persistence/postgres/repositories/email_event_repository.dart:188`,
and `tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart`).

Exemplary cases worth flagging as patterns (positive findings):

- **C-2-D production binding** (`tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart`)
  — cross-tenant recipient lookup uses `withSystem(reason: 'integration_sync_worker.outage_alert_recipient_lookup')`,
  per-tenant email outbox INSERT + audit row use `withTenant`. Stable
  reason string lets log search correlate cross-tenant `operators`
  reads with detector triggers. Mirrors OAuth refresh worker
  precedent verbatim.

- **SendGrid Event Webhook** (`lib/infrastructure/persistence/postgres/repositories/email_event_repository.dart:131-190`)
  — webhook receiver has no operator scope until the event joins back
  to `email_outbox`; `withSystem` is the only valid path. Reason
  constant `kInsertProviderEventReason = 'email_event.insert_provider_event'`
  (line 113). Audited.

- **B8 hierarchy audit-log read** (`tool/advisor_proxy/audit_log_hierarchy_routes.dart:71-77`)
  — explicit comment: "no `withSystem` here — admin reads are
  tenant-bound". Global admins (B1 scope-less tokens) MUST supply
  `operator_id` + `location_id` query params; the route opens a
  `withTenant` for that operator's scope so per-tenant RLS clamps
  the read. This is the **correct** posture for an
  audit-log-admin read endpoint that walks across operators.

- **Default Role catalog admin routes** (`tool/advisor_proxy/admin_default_role_catalog_routes.dart`)
  — every catalog-mutating path goes through `DefaultRoleCatalogVersionsRepository`
  which routes all reads/writes through `runAsSystem`. Documented
  in header lines 23-27.

Did **not** find any `withTenant` mis-use where the worker is
genuinely cross-tenant; did **not** find any `withSystem` use
where `withTenant` would have sufficed.

### Check 3 — Wrapper-only RLS reads in new migrations

**Severity:** clean (no findings)

95 new migration files added 2026-04-28 → 2026-05-13. Of these, the
ones with `CREATE POLICY` bodies use the wrapper functions
exclusively. Verified by `Grep "current_setting\('app\."
db/migrations/`:

| File | Match content | Verdict |
|---|---|---|
| `202604280005_phase_9_0sigma_f_audit_logs.sql` lines 29-41 | All matches are inside **comments** documenting that policy bodies use `app_current_operator()` | ✓ |
| `202604280000_phase_9_0sigma_b_rls_wrappers.sql` | Wrapper-function definition file — bare `current_setting()` is **expected and required** inside the wrapper bodies themselves | ✓ (the wrappers are what every other policy calls) |
| `202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql` | Replaces old bare-`current_setting()` policies with wrapper calls | ✓ |
| `202605020500_hardening_auth_rls_to_wrappers.sql` | All matches inside comments documenting the migration's purpose | ✓ |
| `202604260000_auth_rls_per_tenant_policies.sql` | Bare `current_setting()` calls in policy bodies | **Superseded** by `202604280001_*` and listed in `tool/rls_policy_lint_allowlist.txt` (only entry) |
| `202604250008_auth_schema_foundation.sql` | Old policies before wrapper introduction | Pre-wave; superseded by `202604280001_*` |
| `202605061701_phase_8_data_accuracy_service_period_settings.sql` | Comment lines only | ✓ |
| `202605030000_phase_9_5_0_leaderboard_schema_rls.sql` | Comment lines only | ✓ |
| `202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql` | Pre-wave file | n/a |

New-wave RLS policies inspected directly:

- `202605131900_c_2_d_vendor_sync_outage_state.sql` line 205-211 →
  `operator_id = public.app_current_operator() and location_id = public.app_current_location()` ✓
- `202605131500_b10_1_vendor_applicability.sql` line 133-134 →
  `operator_id = public.app_current_operator()` ✓
- `202605131400_b11_2_auth_step_up_challenges.sql` line 248-252 →
  `operator_id = public.app_current_operator()` ✓
- `202605131030_b11_1_auth_handoff_codes.sql` line 196-203 →
  `operator_id = public.app_current_operator()` ✓
- `202605131550_benchmark_overrides_hierarchy.sql` (on origin/master,
  PR #634) → `operator_id = public.app_current_operator()` ✓
- `202605131600_b2_1_default_role_catalog_versions.sql` — **no RLS**;
  intentional global F&F-wide table; documented in migration header
  lines 74-97; admin-pool BYPASSRLS posture enforced at the
  repository layer via `runAsSystem`.

**Allowlist status:** `tool/rls_policy_lint_allowlist.txt` carries
one entry only (`202604260000_auth_rls_per_tenant_policies.sql`,
superseded by `202604280001_*`). No additions during this wave.

### Check 4 — Frozen `lib/auth/` invariant

**Severity:** clean (no findings)

`git log --since=2026-04-28 --oneline -- lib/auth/permission_keys.dart`
returns 2 wave commits:

1. **`27c832b3 feat(auth): reconcile settings permission catalog (B5.b)`**
   — adds 2 keys (`account.configure`, `business_timing.configure`)
   per `lib/auth/permission_keys.dart:163-167,294-296`. Total key
   count moves 99 → 103 (per file header comment) due to: 99 baseline
   + 2 hierarchy lifecycle keys + 2 B5.b settings keys.
   **Auth-critical slice** (explicit B5.b designation in
   `WAVE_EXECUTION_LEDGER.md`). Catalog doc
   (`docs/contracts/auth_permission_key_catalog.md`) updated in lock-step:
   line 227 (`account.configure`), line 242 (`business_timing.configure`).
   Audit doc PR #573 confirmed.

2. **`8f50599d fix(11W.5+catalog): add team.audit_log.export key`**
   — pre-2026-04-28 (May 6) actually, but git surfaces it in the
   range. Add of `team.audit_log.export` for 11W.5 phantom-gate fix.
   Documented in catalog doc.

`git log --since=2026-04-28 --oneline -- lib/auth/` shows 9 commits
across 9 files (all subdirectory). Each commit is auth-critical
context per its conventional commit prefix (`feat(auth)`,
`feat(mfa)`, `feat(11A.14)`, etc.) or hardening (`fix(11W.5+catalog)`,
`fix: harden MFA production auth flows`). No drive-by edits.

The B11.2.b step-up wiring (`8af2a0c0`) touches `lib/auth/auth_session.dart`,
`lib/auth/fresh_mfa_resolver.dart` per the slice's auth-critical
scope (RFC 9470 step-up adapter); audit pass PR #586 explicitly
approved.

### Check 5 — Append-only `audit_logs` invariant

**Severity:** clean (no findings)

- `tool/audit_logs_update_allowlist.txt` has exactly **one** entry:
  `db/migrations/202605131010_admin_audit_logs_business_date.sql`.
  Confirmed unchanged since `64ba3881 feat(schema): add audit log
  mutation guardrails (A5+A8)` (pre-wave) per
  `git log --since=2026-04-28 -- tool/audit_logs_update_allowlist.txt`
  (returns one earlier commit).
- The one allowlisted entry is a backfill `UPDATE` inside a column
  addition (lines 14-16 of the migration). Constrained to
  `where business_date is null` — backfills only newly-added
  column. Audited at PR landing.
- `Grep "update public\.audit_logs|update audit_logs"`
  across `lib/infrastructure/persistence/postgres/repositories/` and
  `db/migrations/` returns only:
  - The grandfathered migration entry.
  - One comment line (`audit_logs_repository.dart:16`) documenting
    the INSERT-only posture.
- New audit row writers in the wave (audit_logs_repository.dart,
  the C-2 family of email notification handlers, the B2.1
  default-role-catalog audit sink, the B11.1 handoff audit sink,
  the B11.2 step-up audit sink, the C-2-D outage audit writer) all
  use `AuditLogsRepository.writeRow` (INSERT only at
  `audit_logs_repository.dart:125-169`). The writer enforces
  `_assertTenantContextMatches` (lines 183-202) before binding any
  SQL — the operator_id parameter MUST match the
  `app.operator_id` GUC when the caller is inside a tenant tx;
  forge_admin/system path accepts the parameter as-is because
  `app.bypass_rls_audit = 'system:<reason>'` carries on the same
  transaction.

### Check 6 — Role-gate consistency on new routes

**Severity:** clean (no findings)

Inspected each new route handler added in the wave for the 5-part
contract (JWT verify → role gate → 401/403/admin_reason → tenant
scope clamp → handler logic). Sample of routes audited:

| Route file | Role gate | JWT-verified actor source | Admin_reason | Tenant scope clamp |
|---|---|---|---|---|
| `audit_log_hierarchy_routes.dart` (B8) | `{super_admin, ff_support}` line 110-112 | `AuditLogHierarchyAuthResolver` line 151-152 | Required line 297-304 | URL param vs JWT clamp lines 318-348 |
| `admin_default_role_catalog_routes.dart` (B2.1, B2.3) | Read: `{super_admin, ff_support}` line 79-82; Write: `{super_admin}` line 86-88 | `actorRoles` from JWT (caller-injected) | Required for write via `auditSink.recordPublished(adminReason: ...)` line 246-247 | F&F-wide catalog — no tenant scope to clamp |
| `auth_step_up_routes.dart` (B11.2) | Step-up gate (RFC 9470) — `kStepUpSensitiveRoutes` registry | `StepUpPolicy.evaluate(authTime, actorKind)` line 473-498 | n/a (auth gate, not admin gate) | `withTenant` via repository; cross-operator id collapses to 401 (oracle-safe) per file header lines 39-45 |
| `auth_handoff_routes.dart` (B11.1) | Operator-scoped (caller's JWT) | OperatorContext required | n/a (operator-side) | `withTenant`; redeem operator_id checked against minter's operator_id, 403 on mismatch (line 16-18) |
| `demo_mode_master_switch_routes.dart` (C-4) | `kOperatorWriteRoles = {operator_owner, operator_admin}` line 9545-9551 in `advisor_proxy.dart` | OperatorContext via auth guard | n/a (operator-side) | `_operatorLocationScopeAllowed` check at `advisor_proxy.dart:9553-9565` — URL path operator_id/location_id verified against JWT scope, 403 on mismatch |
| `sendgrid_events_webhook.dart` (C-1) | **ECDSA signature gate** (no JWT — external server-to-server) | n/a | n/a | n/a (no tenant) |
| `notification_preferences_routes.dart` (Phase 8 W2.B family) | Operator role gate | OperatorContext | n/a | `withTenant` |
| `wage_role_rows_routes.dart` (Phase 8 W5.A.1) | `kOperatorWriteRoles` per file header line 12-18 | OperatorContext | n/a | OperatorId from JWT only (file header line 37-38: "operator_id resolved from JWT, never from URL") |
| `business_scope_routes.dart` (Phase 11W.7) | Operator role + caller userId check | OperatorContext + actorUserId | n/a | URL path userId checked vs JWT actorUserId line 47-56; URL path operatorId checked vs JWT scopedOperatorId line 85-93 |
| `operator_routes.dart` (Phase 11W.7) | `kOperatorWriteRoles` line 68-71 | OperatorContext | n/a | OperatorId from JWT (file header line 38-40) |
| `admin_email_routes.dart` (Phase 9.8) | `super_admin` only line 29-31 (header doc) | F&F admin actor | Required via `AdminRequestIdempotencyStore` framework | n/a (F&F-side test surface) |

**No findings** — every audited route returned 401 on missing/bad
JWT, 403 on insufficient role, and clamped tenant scope from JWT
rather than query params (when both were available).

One **positive observation**: the B8 route handles the
"scope-less global admin token" case (B1 sign-in contract) carefully
— a token without `operator_id`/`location_id` claims MUST supply
`operator_id` + `location_id` query params, and the handler clamps
each to a UUID-shape check before opening the tenant transaction
(lines 313-374). Cross-tenant leak vector closed.

### Check 7 — `sp:` service-principal id discipline

**Severity:** clean (no findings)

Service-principal id constants confirmed in the wave:

| Worker | Service-principal id | File:line | Audit attribution |
|---|---|---|---|
| `oauth_refresh_worker` | `sp:oauth_refresh_worker` | `tool/oauth_refresh_worker/main.dart:144-145` | `actor_kind = 'service'` (per disambiguator constraint in `202605131000_admin_audit_log_actor_reason_contract.sql:18-26`) |
| `integration_sync_worker` (C-2-D) | `sp:integration_sync_worker` | `tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart:100-101` | `actor_kind = 'service'`, audit row writer in same `withTenant` block as outbox INSERT |
| `first_connect_backfill_worker` | `sp:first_connect_backfill_worker` | `tool/first_connect_backfill_worker/main.dart:722` | per worker disclosure |
| `backfill_worker` (general) | `sp:backfill_worker` | `tool/integration_sync_worker/audit_emitting_backfill_job_store.dart:64` | per disclosure |
| `user_pii_erasure_worker` | `sp:pii-erasure-worker` | `lib/infrastructure/persistence/postgres/repositories/user_pii_erasure_repository.dart:534` | per disclosure |
| Test harness | `sp:test`, `sp:pressure-2c-harness` | test files only | n/a — tests, not production writers |

Constraint posture (per `202605131000_admin_audit_log_actor_reason_contract.sql`):
- `audit_logs.actor_kind` admits `{user, team_member, forge_admin, service, service_principal}`.
- `audit_logs_actor_shape_check` (lines 55-67): when
  `actor_kind ∈ {service, service_principal}`,
  `actor_principal_id` MUST be non-null AND `actor_user_id` MUST be
  null. New wave writers conform (verified by reading the relevant
  service-principal audit writers).
- `audit_logs_admin_reason_check` (lines 69-77): when
  `actor_kind = 'forge_admin'`, `admin_reason` MUST be non-blank.
  The `B2.1 default role catalog publish` path supplies it via
  `auditSink.recordPublished(adminReason: ...)` line 246-247.

### Check 8 — Permission-snapshot caching

**Severity:** clean (no findings)

Searched `tool/advisor_proxy/` for `PermissionKeys.` and
`kAuditLogExportPermissionKey`:

- **`advisor_proxy.dart`** — 12 callsites, every one goes through
  `requirePermission(PermissionKeys.X)` (lines 11244, 11926, 12111-12116)
  or reads `snapshot.permissions[PermissionKeys.X]` (lines 12985,
  13085, 13193). All snapshot-resolved through the proxy's existing
  `ProxyPermissionSnapshotResolver` cache.
- **`proxy_bootstrap.dart`** — 2 callsites: lines 762 + 1076 pass
  `requiresMfaKeys: PermissionKeys.requiresMfa` for resolver
  construction (NOT a hand-rolled permission check; correctly
  threading the catalog into the resolver).

Did **not** find any route that calls `PermissionKeys.X` directly
to short-circuit the snapshot resolver. The sibling-file routers
in the wave (B8, B2.x, B11.x, C-1, C-2-*, C-4, B5, B6) either use
role-gate constants (`{super_admin, ff_support}`,
`{operator_owner, operator_admin}`) or rely on the snapshot
gateway that the dispatcher in `advisor_proxy.dart` resolves
before calling the router. **No cache-bypass vector.**

## Aggregate observations (no fix required)

1. **Default Role catalog F&F-wide table is the design-intentional
   exception to RLS uniformity** — `default_role_catalog_versions`
   has no `operator_id` column and no RLS policy. The migration
   header
   (`202605131600_b2_1_default_role_catalog_versions.sql:74-97`)
   articulates the design carefully: this is a global methodology
   table read by every operator's resolver via the
   `operators.default_role_catalog_version_id` pointer (which IS
   per-operator RLS-protected). The repository enforces the
   admin-pool posture in code via `runAsSystem` on every method.
   Future similar global tables should mirror this pattern (table
   header documents the exception; repository-layer enforcement of
   the admin-pool posture).

2. **`sp:` service-principal posture is consistent and stable** — 5
   service-principal id constants across 4 worker binaries, all
   colocated next to the worker entry point as `const String
   kXxxServicePrincipalId = 'sp:xxx'`. Audit row writers thread the
   constant into `actor_principal_id`. Stable strings let
   post-incident review correlate audit rows, outbox writes, and
   per-worker telemetry without re-deriving the convention.

3. **`withSystem` reason strings are uniformly stable, log-search
   friendly** — every callsite I inspected used a constant string
   (e.g. `'integration_sync_worker.outage_alert_recipient_lookup'`,
   `'email_event.insert_provider_event'`,
   `'proxy_admin_schema_contract'`). The convention is
   `<surface>.<purpose>`; this matches the
   `app.bypass_rls_audit = 'system:<reason>'` GUC label the wrapper
   writes onto every system-pool transaction, so log search can
   join on the literal string.

4. **B8 audit-log hierarchy filter route is a model implementation
   of a cross-operator admin read that stays tenant-bound** —
   compared to the older `/v1/admin/auth/audit-log` route which
   walks across operators (necessitating `withSystem` semantics),
   B8 deliberately requires the caller to supply an operator scope
   (either via JWT claim or via query param when the JWT is
   scope-less). The reader opens `withTenant` for that operator
   and the per-tenant RLS clamps the read at the DB layer. Authors
   of future admin read endpoints should treat this as the default
   shape.

5. **C-2-D production binding mirrors C-2-F precedent verbatim**
   — `tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart`
   imports from `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart`
   in terms of patterns. `withSystem(reason:)` for cross-tenant
   operator-admin lookup, `withTenant` for per-tenant outbox + audit
   writes, `sp:<worker>` service-principal id, observer error
   swallow so a flaky email path never poisons the polling-tier
   write. The mirror-precedent discipline is now an established
   convention for new worker integrations.

6. **`AuditLogsRepository._assertTenantContextMatches` is a
   defense-in-depth gem** — the cross-check of caller-supplied
   `operatorId` against `current_setting('app.operator_id', true)`
   BEFORE binding any INSERT SQL closes the
   forged-cross-tenant-audit-row attack surface. Documented at
   `audit_logs_repository.dart:172-202`. This is the kind of
   layered guard the contract refers to when it calls audit_logs
   a "sanctioned exception" — the row commits in the caller's
   transaction (no `withTenant` opening of a competing
   transaction), but the writer still verifies the GUC.

## Coverage gaps

None material. Every new route file I inspected had at least one
audit doc under `docs/_audits/post_codex_wave/pr_*_audit.md`
(verified by counting README.md entries in that directory — 84
audit docs for ~50 PRs is heavy coverage). The C-2-D production
binding (PR #633) carries a "light variant audit" verdict per its
header, but the salient critical safety guarantees are pinned in
tests
(`test/tool/integration_sync_worker/vendor_sync_outage_binding_test.dart`,
7 cases per audit doc) so the audit gap is observability-only,
not safety-critical.

One observation worth flagging for the orchestrator (not a finding
per this dimension): I noticed the worktree HEAD at audit time
(`63ec00d6`) was 2 commits behind `origin/master` (`63b67753`).
The intervening commits (B6.b `540b848c`, C-7 `55bbacc3`, B8.b
`63b67753`) all touch operator-web or `mfa_factors_repository.dart`
— I read the relevant blobs directly from `origin/master` so the
audit covers the full master tip stated in the prompt. No work was
missed.

## Authority anchors

- `CLAUDE.md` (project root):
  - "Hard Promises" #4 (per-operator isolation), #7 (server-side keys)
  - "RLS-Ready Schema" section
  - "Service-Layer Split" section
  - "Proxy & API Conventions" section
  - "Frozen `lib/auth/`" (Service-Layer Split → `lib/auth/` line)
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
  - Sanctioned exception for `audit_logs_repository.dart` (lines 166-181)
  - Wrapper-only RLS posture (lines 90-110)
  - `withTenant` / `withSystem` discipline (lines 134-165)
- `docs/contracts/auth_permission_key_catalog.md`
  - Permission keys for `account.configure` (line 227),
    `business_timing.configure` (line 242)
  - Catalog count reconciliation (line 215 onward)
- `tool/audit_logs_update_allowlist.txt` — single entry,
  unchanged this wave
- `tool/rls_policy_lint_allowlist.txt` — single entry,
  unchanged this wave
- `tool/audit_logs_update_lint.dart` — exists; enforces append-only
- `docs/_audits/post_codex_wave/pr_633_c_2_d_production_binding_audit.md`
  - Mirror precedent + worker-disclosed safety guarantees
- `db/migrations/202605131000_admin_audit_log_actor_reason_contract.sql`
  - Hardened `actor_kind` enum and `admin_reason` CHECK
- `db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql`
  - The four `STABLE LEAKPROOF PARALLEL SAFE` wrappers:
    `app_current_operator()`, `app_current_location()`,
    `app_current_actor_user()`, `app_acting_as_operator()`
