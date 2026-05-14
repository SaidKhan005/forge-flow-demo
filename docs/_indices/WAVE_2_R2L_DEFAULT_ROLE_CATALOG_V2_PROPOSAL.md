# Wave 2 R-2L — Default Role Catalog v2 proposal

**Status:** operator-approved 2026-05-14. Ready for worker dispatch.
**Slice:** Wave 2 R-2L (ledger Lane R, prereq R-1L merged at `c92ba2e8`).
**Authority:** `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` RP-3, RP-6, RP-14; `docs/_indices/NEXT_WAVE_PLAN.md` line 488; `docs/_indices/WAVE_2_LEDGER.md` Lane R row R-2L.

This doc captures the operator's locked-in decisions for the Default Role Catalog v2 redesign so a worker (Claude main lane, Claude #2, or any future agent) can pick the slice up cold without re-asking the catalog design questions.

---

## Why v2 exists

The original Default Role Catalog (seeded by `db/migrations/202604250008_auth_schema_foundation.sql` lines 914–1083) shipped six roles with mostly correct intentions but three audit gaps:

- **RP-3** — "Suggest seeded roles based on audit" was never done; the catalog was authored from first principles, not from observed operator needs.
- **RP-6** — "Differentiate location vs business roles; no overlap unless seeded" was never wired. All custom roles are operator-wide today; the schema can support location-scoped grants but the catalog doesn't surface the distinction.
- **RP-14** — "Roles categorized by product → functionality, with dependency auto-add" — the existing permission picker is a flat checklist with no product grouping and no transitive auto-select.

R-1L (PR #699, merged) shipped the schema backbone for v2:
- `permission_keys.product_label` / `category_label` / `scope_kind` / `implies[]` columns (nullable in this slice; NOT NULL flip parked as R-1L-FU)
- `lib/auth/permission_key_metadata.dart` — Dart-side mirror with `PermissionKeyMetadataCatalog.byKey`
- METADATA pass in `tool/permission_key_lint.dart` blocks future drift
- `tool/advisor_proxy/proxy_bootstrap.dart` already threads the `implies` graph through the snapshot resolver + admin guard

R-2L plugs the v2 catalog into that backbone and ships the migration that retires the ambiguous v1 roles.

---

## v1 catalog (what exists today)

| Role Key | Display Name | Scope | Permission Count | Editable | Migration Path |
|---|---|---|---|---|---|
| `super_admin` | F&F Super Admin | global | 104 (all) | No | KEEP — no change |
| `ff_support` | F&F Support | global | 27 read-only | No | KEEP — no change |
| `operator_owner` | Operator Owner | operator-wide | 52 | Yes | KEEP under new display name "Owner" |
| `operator_manager` | Operator Manager | operator-wide | 28 | Yes | RETIRE → `operator_general_manager` |
| `operator_supervisor` | Operator Supervisor | operator-wide | 14 | Yes | RETIRE → `location_manager` (location-scoped at each user's existing location grants) |
| `operator_staff` | Operator Staff | operator-wide | 7 (Barrio only) | Yes | RETIRE → `shift_lead` (location-scoped) |

Source: `db/migrations/202604250008_auth_schema_foundation.sql:914-1083`.

---

## v2 catalog (operator-approved)

**10 seeded roles.** Operator approval logged 2026-05-14.

| Role Key | Display Name | Scope | Description (reads-as-training) | MFA-gated? |
|---|---|---|---|---|
| `super_admin` | F&F Super Admin | global | F&F internal. Full platform access; bypasses tenant isolation for support and ops. | Yes |
| `ff_support` | F&F Support | global | F&F support staff. Read-only diagnostic access to assigned operators; can see audit trails but cannot change data. | Yes |
| `operator_owner` | Owner | Business | Owns the business. Full operational access plus billing, integrations, and team admin. | Yes |
| `operator_general_manager` | General Manager | Business | Runs all locations and staff. Operational edit access plus staff admin and audit view; no billing or subscription mutations. | Yes |
| `location_manager` | Location Manager | Location | Runs one location. Invites and removes staff, edits schedules, sees variance and benchmarks at that location. | Yes |
| `shift_lead` | Shift Lead | Location | Leads shifts at one location. Edits short-term schedule, marks shift covers, sees variance for shifts they ran. | No |
| `finance_analyst` | Finance Analyst | Business | Reviews invoices and usage, adjusts usage caps. Cannot change the subscription plan or connect billing integrations. | Yes |
| `auditor_compliance` | Auditor / Compliance | Business | Read-only audit trail and PII oversight. Sees who did what and when, exports the audit log, cannot mutate data. | Yes |
| `barrio_instructor` | Barrio Instructor | Either | Edits the operator's Barrio supervisor content and interview playbook. Does not edit the F&F handbook. | No |
| `team_admin` | Team Admin | Either | Manages the team roster, role assignments, MFA, and password resets. Does not see operational dashboards. | Yes |

**Locked decisions (2026-05-14):**
1. **Retire v1 + auto-migrate** — `operator_manager` → `operator_general_manager`; `operator_supervisor` → `location_manager` at each existing location grant; `operator_staff` → `shift_lead` at each existing location grant.
2. **Finance Analyst is read-only on billing** — `billing.subscription.manage` stays Owner-only. Finance has `billing.invoice.view`, `billing.usage.view`, `billing.usage_caps.edit`.
3. **Auditor / Compliance and Team Admin both ship as seeded core roles.** Operators don't have to mint them as custom.
4. **Barrio Instructor scope** — supervisor content + interview playbook only; F&F handbook stays Owner-only.

---

## Permission grant matrix (proposal — refine in slice)

The exact permission-key list per role belongs in the migration. The category-level summary below is the design intent that the slice translates into per-key INSERTs.

Categories use R-1L's `product_label` / `category_label` from `lib/auth/permission_key_metadata.dart`.

### `operator_owner` (Owner) — Business scope, ~65 keys

- **product**: forgeflow access, barrio access
- **forgeflow**: all 20 keys (shift edit/view, variance edit/view, plan edit/view, benchmark edit/view, schedule edit/view, etc.)
- **barrio**: all 12 keys (handbook edit + supervisor content edit + interview playbook edit + preston_lee + view-all)
- **team**: all 17 keys (users invite/edit/deactivate/reset_password/reset_mfa, roles view/create/assign/revoke, audit_log view/export, session force_logout)
- **account**: account.settings.edit
- **billing**: all 5 keys (invoice.view, usage.view, usage_caps.edit, subscription.manage, payment_method.manage)
- **integration**: all 10 keys (every vendor connect/disconnect/view)
- **workflow**: all 8 keys
- **admin** (operator-scope subset): admin.users.view + admin.users.invite + admin.audit_log.view + admin.audit_log.export (no PII erase, no pricing_tier.edit — those are F&F-side)

### `operator_general_manager` (General Manager) — Business scope, ~50 keys

- **product**: forgeflow access, barrio access
- **forgeflow**: all 20 keys
- **barrio**: 8 keys (view-all + supervisor_content edit + preston_lee view, no handbook edit)
- **team**: 13 keys (users invite/edit/deactivate/reset_password/reset_mfa, roles view/assign/revoke, audit_log view, no roles create_custom, no audit_log export)
- **workflow**: all 8 keys
- **admin** (operator-scope subset): admin.users.view + admin.audit_log.view
- **NO billing**, **NO integration connect/disconnect**

### `location_manager` (Location Manager) — Location scope, ~25 keys

- **product**: forgeflow access, barrio access
- **forgeflow** (location-scoped): shift edit/view, variance view, plan view, benchmark view, schedule edit/view (no benchmark.override — that's Owner/GM)
- **barrio**: view-all + supervisor_content view (no edits)
- **team** (location-scoped): users view + users invite (location-grant) + users deactivate (own location) + roles view + roles assign (location-grants only)
- **workflow**: workflow.view (no edits)

All `team.*` and `forgeflow.*` keys carrying `scope_kind = either` are granted at the location dimension; `org_wide` keys are excluded.

### `shift_lead` (Shift Lead) — Location scope, ~12 keys

- **product**: forgeflow access, barrio access
- **forgeflow** (location-scoped): shift edit (own shifts only — needs runtime gate or new shift-author guard), shift view, variance view, schedule view
- **barrio**: view-all (read-only training)

This is the smallest role; deliberately read-mostly except for shift edit.

### `finance_analyst` (Finance Analyst) — Business scope, ~4 keys + MFA

- **billing**: invoice.view, usage.view, usage_caps.edit
- **admin**: admin.audit_log.view (so they can see what was paid)

MFA-required. No `billing.subscription.manage`, no `billing.payment_method.manage`, no `integration.qbo.connect` etc.

### `auditor_compliance` (Auditor / Compliance) — Business scope, ~5 keys + MFA

- **admin**: admin.audit_log.view, admin.audit_log.export, admin.users.view, admin.audit_privacy.read
- **team**: team.audit_log.view, team.audit_log.export

MFA-required. Strictly read-only.

### `barrio_instructor` (Barrio Instructor) — Either scope, ~5 keys

- **product**: barrio access
- **barrio**: barrio.supervisor_content.edit, barrio.interview_playbook.edit, barrio.preston_lee.view (no handbook edit per locked decision 4)

### `team_admin` (Team Admin) — Either scope, ~10 keys + MFA

- **team**: users view, users invite, users deactivate, users reactivate, users reset_password, users reset_mfa, roles view, roles assign, roles revoke, audit_log view
- **admin**: admin.users.view

MFA-required. No operational dashboard access.

### `ff_support` (F&F Support) — global, 27 read-only keys

Keep current grant. No change.

### `super_admin` (F&F Super Admin) — global, 104 keys

Keep current grant. No change.

---

## Migration plan

**File:** `db/migrations/2026051500NN_phase_r2l_default_role_catalog_v2.sql` (pick the next free `NN` after R-1L's `202605142100`).

**Pattern:**

1. **Insert new role rows** with `is_seeded = true`, `operator_id = null`, populated `display_name` + `description` (reads-as-training plain English).
2. **Insert role_permissions rows** per the matrix above. Use `permission_keys.scope_kind` to verify each grant is compatible with the role's scope (CHECK constraint or migration-time assertion).
3. **Auto-migrate v1 user_roles grants** in a single transaction:
   - `operator_manager` user_roles → flip `role_id` to `operator_general_manager`
   - `operator_supervisor` user_roles → flip `role_id` to `location_manager`, preserving `location_id` per grant (if `location_id` is NULL in the v1 grant, set it to each location the user had any visibility into — fall back to the first location in `restaurant_locations` if ambiguous, flag for operator review)
   - `operator_staff` user_roles → flip `role_id` to `shift_lead`, same location-preservation logic
4. **Soft-delete v1 roles** by setting `deleted_at = now()` on the three retired role rows. Do NOT hard-delete; keep the audit trail.
5. **Backfill `permission_keys.product_label` / `category_label` / `scope_kind` / `implies`** for any keys that landed since R-1L (none expected, but the migration should be defensive).
6. **Emit audit rows** (`auth.role.seeded_catalog_v2_published`) per migrated user_role + per retired seeded role.

**Idempotent re-run:** wrap the entire migration in a single transaction with `ON CONFLICT DO NOTHING` on role inserts and a guard that skips the user_roles flip if the v2 role IDs are already in place.

**Out of scope for R-2L:**
- The editor UX changes (product+category grouping, implies auto-select) — that's S-3.
- The blast-radius preview update — already shipped by B2.3.
- The location-scoped permission enforcement in the runtime resolver — already shipped by R-1L (`scope_kind` exists; the dispatcher just needs the catalog to use it).

---

## Worker contract

Same as every Wave 2 slice:

1. Branch: `claude/wave-2-r-2l-default-role-catalog-v2` off current `origin/master`.
2. Step 0: `pwsh scripts/install_git_hooks.ps1` (canonical hooks).
3. Implement the migration + Dart-side catalog reference if needed.
4. Self-audit Pattern B (14 lenses, file:line citations).
5. Tests + `dart analyze --fatal-infos` clean.
6. Verifications:
   - `dart run tool/migration_cutoff_lint.dart`
   - `dart run tool/migration_drift_scanner.dart --strict-docs`
   - `dart run tool/permission_key_lint.dart`
   - `dart run tool/rls_policy_lint.dart`
   - `flutter test test/auth/`
   - New test: `test/auth/r2l_default_role_catalog_v2_migration_test.dart` — assert v1 roles soft-deleted, v2 roles present with expected `display_name` + `scope_kind`, user_roles auto-migrated, no orphaned grants.
7. Commit + push + open PR. Base = `master`. Pattern B audit table in PR body.
8. STOP. Orchestrator audits + merges.

**Constraints:**
- Auth-touching + schema-touching — operator pre-approval logged here. Orchestrator can merge once Pattern B audit is clean.
- DO NOT raise `kAdvisorProxyMaxLines`. No proxy edits expected.
- DO NOT widen permission gates beyond what this doc specifies.
- DO NOT touch `docs/_indices/WAVE_2_LEDGER.md` or any tracker.
- Cutoff-mirror docs (`docs/POST_HARDENING_FOLLOWUPS.md`, runbook, phase docs, `scripts/postgres_staging_setup.ps1`) are mechanical updates allowed (see C-2-D / W-3 / R-1L precedent — `migration_drift_scanner --fix` handles this).

---

## Authority anchors

- `db/migrations/202604250008_auth_schema_foundation.sql:914-1083` — v1 seeded role catalog and permission grants.
- `db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql` — R-1L schema additions (product_label, category_label, scope_kind, implies).
- `lib/auth/permission_key_metadata.dart` — 104 permission keys with full metadata; canonical source for the v2 grant matrix.
- `lib/auth/permission_keys.dart` — permission key constants (104 keys post-W-3 + R-1L).
- `tool/permission_key_lint.dart` — METADATA pass; will fail if v2 introduces any key without a metadata row.
- `tool/advisor_proxy/proxy_bootstrap.dart` — `_cachedImpliesMap` already threads `implies` through the resolver.
- `lib/admin/screens/default_role_catalog_admin_screen.dart` — existing admin editor (no changes needed for R-2L; S-3 redesigns the picker UX).
- `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` lines 118–129 — RP-3, RP-4, RP-6, RP-7, RP-9, RP-12, RP-14 audit context.
- `memory/project_ux_writing_standard.md` — every `display_name` and `description` reads as training, plain English, no engineering jargon.

---

## Open questions deferred to S-3

These don't block R-2L but should be picked up by S-3 (Roles screen UX simplification):

- Should `forgeflow.shift.edit` at `shift_lead` scope have a runtime "own shifts only" guard, or grant globally within the location?
- Should `team.users.invite` at `location_manager` scope let them invite users at OTHER locations, or only their own?
- Should the editor surface a "scope conflict" warning when an operator picks a key whose `scope_kind = org_wide` for a location-scoped grant (instead of silently filtering)?

---

## Operator approval log

| Decision | Value | Date |
|---|---|---|
| Retire v1 + auto-migrate | Approved | 2026-05-14 |
| Finance read-only on billing | Approved | 2026-05-14 |
| Include Auditor + Team Admin | Approved | 2026-05-14 |
| Barrio Instructor: no handbook edit | Approved | 2026-05-14 |
