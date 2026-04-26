# Auth Permission Key Catalog

**Status:** Active. Lands with Phase 9.0.
**Authority order:** This contract documents the frozen catalog. The
canonical sources are the SQL seed in
`db/migrations/202604250008_auth_schema_foundation.sql` and the constants
in `lib/auth/permission_keys.dart`. This doc must stay in sync with both.

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

1. `db/migrations/202604250008_auth_schema_foundation.sql` — the
   `insert into public.permission_keys` block.
2. `lib/auth/permission_keys.dart` — add the constant + add to
   `PermissionKeys.all` (and `requiresMfa` if applicable).
3. This document — add the row to the table for the right category.

The 9.0 test group (`Phase 9 auth schema foundation migration (9.0)`)
in `test/advisor_proxy_test.dart` asserts that the migration seeds at
least the keys exposed by `PermissionKeys.all`; if you add a key in
the constants without seeding it, the test catches that.

## Categories

The catalog currently carries 81 keys across 7 categories.

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

### `admin.*` (25)

F&F admin actions. Mostly mounted under `/v1/admin/auth/*` (9.6, 9.8).
Sensitive keys carry `requires_mfa = true`.

| Key | Description | MFA |
|---|---|---|
| `admin.users.view` | View users in admin console. | — |
| `admin.users.create` | Create users programmatically (rare path). | — |
| `admin.users.deactivate` | Suspend a user account. | — |
| `admin.users.reactivate` | Reactivate a suspended user account. | — |
| `admin.users.soft_delete` | Soft-delete a user (status -> deleted; data retained). | — |
| `admin.users.erase_pii` | GDPR right-to-erasure: redact PII for a user. Paired-approval + MFA required. | yes |
| `admin.users.reset_password` | Trigger admin-initiated password reset for a user. | — |
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

## Out of catalog scope

- Vendor-specific operator-scoped permissions (e.g., overriding a
  third-party integration credential at row level) are handled by
  RLS, not the catalog.
- Time-bound and location-scoped grants are dimensions of `user_roles`,
  not the catalog. The catalog defines what is grantable; `user_roles`
  defines who, where, and for how long.
- Step-up MFA challenges beyond `requires_mfa` (e.g., re-prompt after
  N minutes of inactivity) are session policy, not catalog.
