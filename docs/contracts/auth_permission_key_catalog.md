# Auth Permission Key Catalog

**Status:** Active. Lands with Phase 9.0.
**Authority order:** This contract documents the frozen catalog. The
canonical sources are the SQL seed in
`db/migrations/202604250008_auth_schema_foundation.sql`, additive catalog
migrations in `db/migrations/`, and the constants in
`lib/auth/permission_keys.dart`. This doc must stay in sync with those.

## Why a frozen catalog

Permission keys are app-defined. Operators may not invent new keys at
runtime. Custom roles introduced via the 9.6 admin endpoints choose
which existing keys they grant or deny — they cannot extend the
universe of keys. Freezing the catalog at code level keeps:

- Permission resolution deterministic across the proxy + Flutter
  surfaces.
- The audit trail (`role_audit_log`, `auth_events_audit`) intelligible
  to F&F support and ops.
- The MFA-required set (`requires_mfa = true`) auditable: changing it
  requires a code change + migration, not a runtime row update.

## Keep in sync

When adding, renaming, or removing a key, update all three together:

1. `db/migrations/` - either the foundation `insert into
   public.permission_keys` block or an additive follow-up migration.
2. `lib/auth/permission_keys.dart` — add the constant + add to
   `PermissionKeys.all` (and `requiresMfa` if applicable).
3. This document — add the row to the table for the right category.

The 9.0 test group (`Phase 9 auth schema foundation migration (9.0)`)
in `test/advisor_proxy_test.dart` asserts that the migration seeds at
least the keys exposed by `PermissionKeys.all`; if you add a key in
the constants without seeding it, the test catches that.

## Categories

The catalog carries 84 keys across 7 categories in the core catalog
(81 original + 2 admin keys added after baseline +
`admin.users.reset_mfa_factors` added in 11A.14). The 14 `team.*` keys
added across 9.0a, the MFA hardening slice, and 11W.5 live in their own
section below; the Phase 8.0 single `integrations.configure` key adds a
9th category. B5.b adds `account.*` and `business_timing.*` settings
categories. The running total across all 11 categories is 103 keys.

### `product.*` (2)

Product-shell access gates. A user without the matching `product.*`
key cannot enter the product shell at all. `product.forgeflow.access`
is required for both standalone Forge & Flow and the Forge & Flow
surfaces inside Barrio. `product.barrio.access` is required for
Barrio surfaces. The Barrio admin pattern (Hard Promise: superset)
holds both.

| Key | Description | MFA |
|---|---|---|
| `product.forgeflow.access` | Access to Forge & Flow surfaces in either product shell. | — |
| `product.barrio.access` | Access to Barrio surfaces in the Barrio product shell. | — |

### `forgeflow.*` (20)

Forge & Flow surface views and actions. Splitting `view` from `edit`
allows the Phase 9 RBAC plan to seat read-only operators
(`operator_supervisor`) below editors (`operator_manager`,
`operator_owner`).

| Key | Description | MFA |
|---|---|---|
| `forgeflow.shift.view` | View shift surface. | — |
| `forgeflow.shift.edit` | Edit shift assignments. | — |
| `forgeflow.variance.view` | View variance surface. | — |
| `forgeflow.variance.edit` | Edit variance reasons and notes. | — |
| `forgeflow.schedule.view` | View schedule surface. | — |
| `forgeflow.schedule.edit` | Edit upcoming schedule assignments. | — |
| `forgeflow.baseline.view` | View baseline benchmark. | — |
| `forgeflow.baseline.override` | Override baseline values for a service period. | — |
| `forgeflow.history.view` | View historical service-period results. | — |
| `forgeflow.benchmark.view` | View 60-day benchmark snapshot. | — |
| `forgeflow.benchmark.edit` | Edit 60-day benchmark snapshot inputs. | — |
| `forgeflow.target_profile.view` | View active target profile. | — |
| `forgeflow.target_profile.manage` | Manage target-profile parameters. | — |
| `forgeflow.target_cycle.view` | View target cycle. | — |
| `forgeflow.target_cycle.unlock` | Unlock the active target cycle for early replacement. | — |
| `forgeflow.target_cycle.replace` | Replace the active target cycle. | — |
| `forgeflow.weekly_plan.view` | View locked weekly plan snapshot. | — |
| `forgeflow.weekly_plan.lock` | Lock the in-force weekly plan snapshot. | — |
| `forgeflow.settings.view` | View Forge & Flow settings. | — |
| `forgeflow.settings.manage` | Manage Forge & Flow settings. | — |

### `barrio.*` (12)

Barrio learning surfaces. Most are scoped reads; `*.edit` keys exist
where operator owners or F&F may curate Barrio content per operator.

| Key | Description | MFA |
|---|---|---|
| `barrio.handbook.view` | View Barrio handbook. | — |
| `barrio.interview_playbook.view` | View interview playbook. | — |
| `barrio.jim_taylor.view` | View Jim Taylor course. | — |
| `barrio.preston_lee.view` | View Preston Lee course. | — |
| `barrio.supervisor_content.view` | View supervisor learning content. | — |
| `barrio.el_podio.view` | View El Podio leaderboard surfaces. | — |
| `barrio.handbook.edit` | Edit Barrio handbook content (operator owner / F&F only). | — |
| `barrio.interview_playbook.edit` | Edit interview-playbook content. | — |
| `barrio.preston_lee.edit` | Edit Preston Lee course content. | — |
| `barrio.supervisor_content.edit` | Edit supervisor learning content. | — |
| `barrio.learning.complete_unit` | Mark a learning unit complete for the current user. | — |
| `barrio.streak.view` | View own streak / leaderboard standing. | — |

### `admin.*` (28)

F&F admin actions. Mostly mounted under `/v1/admin/auth/*` (9.6, 9.8).
Sensitive keys carry `requires_mfa = true`. The 9.0Σ.h2 slice
(2026-04-28) added `admin.audit_privacy.read` to gate the audit-read
path on `advisor_conversation_log`; that key is seeded by
`db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`,
not by the 9.0 foundation seed. The 11A.14 slice (2026-05-06) added
`admin.users.reset_mfa_factors` to gate the support-side MFA-reset
escalation; that key is seeded by
`db/migrations/202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql`,
also not by the 9.0 foundation seed.

| Key | Description | MFA |
|---|---|---|
| `admin.users.view` | View users in admin console. | — |
| `admin.users.create` | Create users programmatically (rare path). | — |
| `admin.users.deactivate` | Suspend a user account. | — |
| `admin.users.reactivate` | Reactivate a suspended user account. | — |
| `admin.users.soft_delete` | Soft-delete a user (status -> deleted; data retained). | — |
| `admin.users.erase_pii` | GDPR right-to-erasure: redact PII for a user. Paired-approval + MFA required. | yes |
| `admin.users.reset_password` | Trigger admin-initiated password reset for a user. | — |
| `admin.users.reset_mfa_factors` | Reset a member's MFA factors from the F&F admin support path. Required for support-side account recovery when the member has lost access to their second factor. Paired with admin_reason on every call. MFA required. | yes |
| `admin.invites.create` | Create user invites. | — |
| `admin.invites.revoke` | Revoke pending user invites. | — |
| `admin.roles.view` | View roles in admin console. | — |
| `admin.roles.edit_seeded` | Edit permissions on seeded roles (super_admin only). | yes |
| `admin.roles.create_custom` | Create custom operator-scoped roles. | — |
| `admin.roles.delete_custom` | Delete custom operator-scoped roles (after revoking grants). | — |
| `admin.roles.assign` | Grant a role to a user. | — |
| `admin.roles.revoke` | Revoke a role from a user. | — |
| `admin.audit_log.view` | View auth event audit log. | — |
| `admin.audit_log.export` | Export audit log to CSV. | — |
| `admin.target_cycle.unlock` | Admin-side override of target-cycle lock. | — |
| `admin.pricing_tier.view` | View operator pricing tier. | — |
| `admin.pricing_tier.edit` | Edit operator pricing tier (F&F super_admin only). | yes |
| `admin.feature_flag.view` | View feature flags. | — |
| `admin.feature_flag.toggle` | Toggle feature flag value. | — |
| `admin.status_page.publish` | Publish a status-page incident or recovery. | — |
| `admin.debug_console.view` | View internal debug console. | — |
| `admin.session.force_logout` | Force-revoke all sessions for a user. | — |
| `admin.service_principal.issue_token` | Issue short-lived service-principal JWTs for automation identities. MFA required. | yes |
| `admin.audit_privacy.read` | Read raw advisor conversation content (encrypted columns) under the audit-privacy access path. Every call writes an `audit_logs` provenance row capturing reader, reason, target, and records-read count. MFA required. | yes |

### `team.*` (17)

Operator self-service team management. Distinct from `admin.*` —
`team.*` keys gate the operator-facing Settings → Team UX (lands in
9.10) and let an `operator_owner` manage their own users / roles
without touching F&F-side admin paths.

Added 2026-04-27 by the 9.0a multi-location scale-flow extensions
slice, with `team.users.reset_mfa` added by the 2026-04-30 MFA
hardening migration, `team.audit_log.export` added by the 2026-05-06
11W.5 catalog reconciliation slice, `team.users.self_update` added
by the 2026-05-14 Wave 2 W-3 self-service profile slice, and the two
`team.roles.default_catalog.*` keys added by the 2026-05-14 Wave 2
RP-9 slice for the F&F-internal Default Role Catalog admin surface.
None require MFA at the catalog level; the launch tier avoids
mandatory MFA enforcement for admin-tier accounts until post-launch
stability. The reset-MFA routes still require fresh sign-in through
route logic because removing a second factor is sensitive.

| Key | Description | MFA |
|---|---|---|
| `team.users.view` | View the operator's user list. | — |
| `team.users.invite` | Create invites for users in own operator. | — |
| `team.users.deactivate` | Suspend a user in own operator. | — |
| `team.users.reactivate` | Reactivate a suspended user. | — |
| `team.users.soft_delete` | Soft-delete a user in own operator. | — |
| `team.users.reset_password` | Admin-initiated password reset for a team member. | — |
| `team.users.reset_mfa` | Start or cancel delayed authenticator-app removal for a team member after fresh authentication. | — |
| `team.users.self_update` | Change your own display name or email from My Account. Distinct from `team.users.invite` which gates editing someone else; every signed-in operator role is granted this key by default. | — |
| `team.roles.view` | View the operator's role list. | — |
| `team.roles.create_custom` | Create operator-scoped custom role. | — |
| `team.roles.assign` | Grant role to user within own operator. | — |
| `team.roles.revoke` | Revoke role from user within own operator. | — |
| `team.roles.default_catalog.view` | View the F&F Default Role Catalog template — read-only access to the seeded role set every new operator begins with. F&F super_admin + ff_support only. | — |
| `team.roles.default_catalog.edit` | Edits the F&F Default Role Catalog template — adds, renames, or removes seeded roles for new operators. F&F super_admin only. | — |
| `team.hierarchy.suspend` | Suspend or reactivate locations and hierarchy levels. | — |
| `team.hierarchy.delete` | Delete locations and empty hierarchy levels. | — |
| `team.audit_log.view` | View audit log scoped to own operator. | — |
| `team.audit_log.export` | View and export team audit log entries (CSV). | — |
| `team.session.force_logout` | Force-logout a user's sessions within own operator. | — |

Baseline grants seeded by 9.0a:

- `super_admin` gets every key in the catalog. The 9.0 seed grants all
  original keys, and the 9.0a audit-fix migration grants the later `team.*`
  keys. The MFA hardening migration grants `team.users.reset_mfa`. The
  11W.5 reconciliation migration grants `team.audit_log.export`. The
  W-3 self-service migration grants `team.users.self_update`.
- `operator_owner` gets ALL `team.*` keys, including
  `team.users.reset_mfa`, `team.audit_log.export`, hierarchy lifecycle
  keys, and `team.users.self_update`.
- `operator_admin` (when seeded) gets `team.audit_log.export` so the
  Operator Web Audit Log CSV export action carries an honest gate,
  plus `team.users.self_update` for the self-service profile editor.
- `operator_manager` gets the manager-tier subset:
  `team.users.view`, `team.users.invite`, `team.users.reactivate`,
  `team.users.reset_password`, `team.users.self_update`,
  `team.roles.view`, `team.roles.assign`, `team.roles.revoke`,
  `team.audit_log.view`, `team.session.force_logout`. Manager **cannot**
  create custom roles, suspend/delete hierarchy levels, soft-delete
  users, reset MFA, or export audit logs by default (locked); pulling
  a full audit trail to CSV is a senior-role action.
- `operator_supervisor` and `operator_staff` get `team.users.self_update`
  only — every signed-in operator user can update their own profile
  from the My Account surface, regardless of other team-management
  authority.
- `team.roles.default_catalog.view` is granted to `super_admin` and
  `ff_support` only — the F&F-internal Default Role Catalog admin
  surface (`default_role_catalog_admin_screen.dart`) is the only
  consumer. Operator-tier roles never receive the grant by default
  because the default catalog template is global to the F&F
  deployment.
- `team.roles.default_catalog.edit` is granted to `super_admin` ONLY.
  Publishing a new default catalog version affects every operator in
  the F&F deployment, so the write gate is F&F super-admin-only by
  design. `ff_support` lands on the read-only branch via the view
  grant above. Do NOT widen this grant to `operator_owner` or any
  other operator-scoped role.

### `account.*` (1)

Operator business-account settings. `account.configure` gates writes to
the Operator Web Account screen for business identity, region, business
week, rollover-hour, and logo settings. Grant intent is senior
operator ownership: `operator_owner` and `operator_admin` (when seeded)
can configure the account; manager-tier and below remain read-only.
`super_admin` is granted explicitly so the seeded super-admin role keeps
the "every catalog key" invariant. No MFA is required at the catalog
level; route-level freshness can be added later without changing the
grantable key.

| Key | Description | MFA |
|---|---|---|
| `account.configure` | Configure operator business account identity, locale, currency, business-week, rollover-hour, and logo settings. | — |

### `business_timing.*` (1)

Operator business-timing settings. `business_timing.configure` gates
writes to the Operator Web Business setup and Business timing editor
screens. Grant intent mirrors the current operator write route and
screen posture: `operator_owner` and `operator_admin` (when seeded) own
timing configuration; manager-tier and below do not receive the default
grant. `super_admin` is granted explicitly for catalog completeness.
No MFA is required at the catalog level; closed-day timing authority
and write validation stay in the business-timing route/service layer.

| Key | Description | MFA |
|---|---|---|
| `business_timing.configure` | Configure effective-dated business timing profiles, rollover-hour, week-start, and service periods. | — |

### `billing.*` (5)

Operator billing actions. All money-moving keys require MFA.

| Key | Description | MFA |
|---|---|---|
| `billing.invoice.view` | View operator invoices. | — |
| `billing.subscription.manage` | Manage subscription tier + payment terms. | yes |
| `billing.payment_method.manage` | Add or remove operator payment methods. | yes |
| `billing.usage.view` | View per-class usage and cost rollups. | — |
| `billing.usage_caps.edit` | Edit per-class monthly cap. | yes |

### `integration.*` (9)

Third-party integration management. `integration.key_rotate` is the
catch-all rotate-secret action used by Phase 11A.4. Vendor-specific
`*.connect` keys are split per-vendor for finer control.

| Key | Description | MFA |
|---|---|---|
| `integration.toast.connect` | Connect or rotate Toast POS credentials. | — |
| `integration.toast.view` | View Toast integration status. | — |
| `integration.7shifts.connect` | Connect or rotate 7shifts labor credentials. | — |
| `integration.7shifts.view` | View 7shifts integration status. | — |
| `integration.opentable.connect` | Connect or rotate OpenTable reservation credentials. | — |
| `integration.opentable.view` | View OpenTable integration status. | — |
| `integration.qbo.connect` | Connect or rotate QuickBooks Online credentials. | — |
| `integration.xero.connect` | Connect or rotate Xero credentials. | — |
| `integration.key_rotate` | Rotate any integration secret. | yes |

### `integrations.*` (1)

Phase 8.0 single-category gate for the Vendor Connections admin
surface (POS / labor / reservation). Distinct from the per-vendor
`integration.*` keys above which gate F&F-internal provider-key
rotation in 11A.4. Granted to `forge_admin` and operator senior
roles (`operator_owner` / `operator_admin`); read-only for
`ff_support` (no mutate routes wired); denied to `location_manager`
because misconfigured vendor credentials cascade into broken
cost / labor data and senior roles own that risk.

| Key | Description | MFA |
|---|---|---|
| `integrations.configure` | Configure inbound vendor connections (POS / labor / reservation) on the per-(operator, location) Vendor Connections admin surface. | — |

### `workflow.*` (8 placeholder)

Phase 12 workflow capabilities. Seeded as placeholder keys so Phase 12
slices can grant them without another permission-catalog migration.
None require MFA at the catalog level; Phase 12 may add per-workflow
MFA-required gates outside the permission catalog.

| Key | Description | MFA |
|---|---|---|
| `workflow.catalog.view` | View Phase 12 workflow catalog. | — |
| `workflow.run` | Run a Phase 12 workflow. | — |
| `workflow.approve` | Approve a Phase 12 workflow approval gate. | — |
| `workflow.reject` | Reject a Phase 12 workflow approval gate. | — |
| `workflow.create` | Create a Phase 12 workflow. | — |
| `workflow.delete` | Delete a Phase 12 workflow. | — |
| `workflow.history.view` | View Phase 12 workflow run history. | — |
| `workflow.tool.invoke` | Invoke a Phase 12 workflow tool directly. | — |

## Baseline Roles (seeded)

Six roles are seeded into `public.roles` at 9.0 apply time, all global
(`operator_id IS NULL`) and `is_seeded = true`. Custom operator-scoped
roles are created at runtime via 9.6's POST `/v1/admin/auth/roles`.

| Role key | `is_editable` | Intent |
|---|---|---|
| `super_admin` | false | F&F company. Every key in the catalog. BYPASSRLS via `forge_admin` Postgres role. |
| `ff_support` | false | F&F support. Read-only across products + admin views; scoped to assigned operators. |
| `operator_owner` | true | Operator owner / customer. Full operational + operator-scoped admin + integrations. |
| `operator_manager` | true | Manager-level operator user. Broad operational; limited admin. |
| `operator_supervisor` | true | Supervisor-level. Selected operational + supervisor learning. |
| `operator_staff` | true | Line-level. Barrio learning surfaces only by default. |

The `is_editable` flag protects `super_admin` and `ff_support` from
runtime grant edits; only super_admin can edit `super_admin` /
`ff_support` permissions, and that path requires
`admin.roles.edit_seeded` (MFA-required).

## Resolution semantics (preview, lands in 9.6)

Phase 9.6 implements the runtime resolver. The semantics are:

```
for each user_roles row WHERE user_id = X
  AND now() BETWEEN valid_from AND COALESCE(valid_until, 'infinity')
  AND revoked_at IS NULL:
  join role_permissions
  collect (permission_key, effect) tuples
if any (permission_key, 'deny') exists for permission_key, effect = deny
else if any (permission_key, 'allow') exists, effect = allow
else effect = deny (default)
```

Deny wins. Default deny. The `users.roles_version` column is the cache
invalidation key; bumping it on any role change drops the entry from
the JWT custom-claim cache and the in-process permission cache.

## B5.b catalog reconciliation

Surfaced by the 2026-05-06 CODE_HEALTH audit; flagged again by Wave 5
W5-PKEYS ([#362](https://github.com/SaidKhan005/forge-flow-demo/pull/362))
during the operator-web permission-key sweep. Historical context:
`docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`.

The B5.b follow-up resolves the two operator-web settings namespaces
that were previously flagged as pending additions:

- `lib/operator_web/screens/account_screen.dart` gates on
  `PermissionKeys.accountConfigure`.
- `lib/operator_web/screens/business_setup_screen.dart` gates on
  `PermissionKeys.businessTimingConfigure`.
- `lib/operator_web/screens/business_timing_editor_screen.dart` gates on
  `PermissionKeys.businessTimingConfigure`.

The catalog rows above, `lib/auth/permission_keys.dart`, and the
additive B5.b seed migration are the coordinated mirrors for these two
keys. No B2/B10 admin keys were added.

## Out of catalog scope

- Vendor-specific operator-scoped permissions (e.g., overriding a
  third-party integration credential at row level) are handled by
  RLS, not the catalog.
- Time-bound and location-scoped grants are dimensions of `user_roles`,
  not the catalog. The catalog defines what is grantable; `user_roles`
  defines who, where, and for how long.
- Step-up MFA challenges beyond `requires_mfa` (e.g., re-prompt after
  N minutes of inactivity) are session policy, not catalog.
