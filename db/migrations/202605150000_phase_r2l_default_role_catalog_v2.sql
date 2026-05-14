-- Wave 2 R-2L — Default Role Catalog v2 redesign.
--
-- Authority:
--   * docs/_indices/WAVE_2_R2L_DEFAULT_ROLE_CATALOG_V2_PROPOSAL.md
--     (operator-approved 2026-05-14; locks role names, scopes,
--     descriptions, MFA gating, and v1 -> v2 migration mapping).
--   * docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md RP-3 / RP-6 /
--     RP-14 (catalog gaps the v2 catalog closes).
--   * Prereq: R-1L `202605142100_phase_R_1L_roles_schema_rewrite.sql`
--     which added product_label / category_label / scope_kind /
--     implies columns.
--   * CLAUDE.md "RLS-Ready Schema" — `permission_keys`, `roles`,
--     `role_permissions`, `user_roles` are the auth catalog tables;
--     RLS posture is unchanged by this slice (service-role
--     wrapper functions only).
--   * CLAUDE.md "Time Guardrails" — every new timestamp column is
--     `timestamptz` (none added here; existing created_at /
--     updated_at columns cover audit).
--
-- What this slice does
-- --------------------
-- 1. Adds `permission_keys.human_label TEXT` (NULLABLE; expand-only
--    per the R-1L expand-contract precedent — NOT NULL flip parked
--    alongside R-1L-FU).
-- 2. Backfills every permission_key row with a Title Case English
--    human label per the UX naming standard (no underscores, no
--    engineering jargon). The R-2L editor + role explainer surfaces
--    render `human_label` instead of the raw dotted key.
-- 3. Seeds 7 new v2 role rows (Owner already exists as
--    `operator_owner` — only its `display_name` and `description`
--    flip to the v2 wording):
--      operator_general_manager  ("General Manager")
--      location_manager          ("Location Manager")
--      supervisor                ("Supervisor")
--      finance_analyst           ("Finance Analyst")
--      auditor_compliance        ("Auditor / Compliance")
--      training_lead             ("Training Lead")
--      team_admin                ("Team Admin")
--    Plus 3 carry-overs: `super_admin`, `ff_support`, `operator_owner`.
--    Total seeded v2 catalog = 10 roles.
-- 4. Seeds role_permissions for every new v2 role per the matrix in
--    the proposal doc. Owner gains additional v2 keys
--    (team.* / billing.* completeness); manager / supervisor / staff
--    do NOT get fresh grants because those roles are soft-deleted in
--    step 6.
-- 5. Auto-migrates v1 user_roles in a single transaction:
--      operator_manager     -> operator_general_manager (operator-wide).
--      operator_supervisor  -> supervisor (LOCATION-scoped; preserves
--                              v1 grant's location_id; for v1 rows with
--                              NULL location_id, fan out one supervisor
--                              grant per locations row the user has any
--                              visibility into and flag for operator
--                              review via reason text).
--      operator_staff       -> supervisor (same location-preservation
--                              logic; staff users folded into the
--                              shift-supervisor role).
-- 6. Soft-deletes v1 retired role rows (`deleted_at = now()`) —
--    operator_manager / operator_supervisor / operator_staff. Hard
--    delete is forbidden so the audit trail and any FK references
--    (role_permissions, role_audit_log) stay intact.
-- 7. Refreshes `operator_owner` display_name + description to the v2
--    wording ("Owner" / reads-as-training description) and grants the
--    v2 additions (team.* completeness, full billing) idempotently.
-- 8. Emits `auth.role.seeded_catalog_v2_published` rows to
--    `auth_events_audit` for every migrated user_role + every retired
--    seeded role.
--
-- Idempotency
-- -----------
-- The migration wraps every mutation in a single transaction and
-- uses `on conflict do nothing` for role + role_permissions inserts.
-- The user_roles auto-migrate filters on the OLD role_id so re-runs
-- after a successful pass are a no-op (no rows still carry the v1
-- role_id). The fan-out INSERT excludes already-present grants via
-- an anti-join against `user_roles_active_grant_idx`.
--
-- Reader-side mirror
-- ------------------
-- `lib/auth/permission_key_metadata.dart` is extended in the same
-- slice with a `humanLabel` field on `PermissionKeyMetadata`; every
-- entry in `PermissionKeyMetadataCatalog.byKey` carries a Title Case
-- humanLabel matching the backfill below.
-- `tool/permission_key_lint.dart`'s HUMAN_LABEL_INVALID pass fails
-- CI if any entry has an empty humanLabel or one containing
-- underscores.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── Step 0: permission_keys.human_label (NULLABLE, expand-only) ─────

alter table public.permission_keys
  add column if not exists human_label text;

-- ─── Backfill human_label for every catalog key ──────────────────────
--
-- Mirrors `lib/auth/permission_key_metadata.dart`'s `humanLabel`
-- field. Title Case English, no underscores, no engineering jargon.
-- Operator-facing copy per memory/project_ux_writing_standard.md.

update public.permission_keys set human_label = case key
  -- product.*
  when 'product.forgeflow.access'         then 'Open Forge & Flow'
  when 'product.barrio.access'            then 'Open Barrio'

  -- forgeflow.*
  when 'forgeflow.shift.view'             then 'View shift details'
  when 'forgeflow.shift.edit'             then 'Edit shift details'
  when 'forgeflow.variance.view'          then 'View variance results'
  when 'forgeflow.variance.edit'          then 'Adjust variance results'
  when 'forgeflow.schedule.view'          then 'View schedules'
  when 'forgeflow.schedule.edit'          then 'Edit schedules'
  when 'forgeflow.baseline.view'          then 'View baseline targets'
  when 'forgeflow.baseline.override'      then 'Override baseline targets'
  when 'forgeflow.history.view'           then 'View historical results'
  when 'forgeflow.benchmark.view'         then 'View benchmarks'
  when 'forgeflow.benchmark.edit'         then 'Edit benchmarks'
  when 'forgeflow.target_profile.view'    then 'View target profiles'
  when 'forgeflow.target_profile.manage'  then 'Manage target profiles'
  when 'forgeflow.target_cycle.view'      then 'View target cycles'
  when 'forgeflow.target_cycle.unlock'    then 'Unlock target cycles'
  when 'forgeflow.target_cycle.replace'   then 'Replace target cycles'
  when 'forgeflow.weekly_plan.view'       then 'View weekly plans'
  when 'forgeflow.weekly_plan.lock'       then 'Lock weekly plans'
  when 'forgeflow.settings.view'          then 'View Forge & Flow settings'
  when 'forgeflow.settings.manage'        then 'Manage Forge & Flow settings'

  -- barrio.*
  when 'barrio.handbook.view'             then 'View the Barrio handbook'
  when 'barrio.handbook.edit'             then 'Edit the Barrio handbook'
  when 'barrio.interview_playbook.view'   then 'View the interview playbook'
  when 'barrio.interview_playbook.edit'   then 'Edit the interview playbook'
  when 'barrio.jim_taylor.view'           then 'View the Jim Taylor course'
  when 'barrio.preston_lee.view'          then 'View the Preston Lee course'
  when 'barrio.preston_lee.edit'          then 'Edit the Preston Lee course'
  when 'barrio.supervisor_content.view'   then 'View supervisor content'
  when 'barrio.supervisor_content.edit'   then 'Edit supervisor content'
  when 'barrio.el_podio.view'             then 'View the El Podio course'
  when 'barrio.learning.complete_unit'    then 'Mark learning units complete'
  when 'barrio.streak.view'               then 'View learning streaks'

  -- admin.*
  when 'admin.users.view'                 then 'View users'
  when 'admin.users.create'               then 'Create users'
  when 'admin.users.deactivate'           then 'Deactivate users'
  when 'admin.users.reactivate'           then 'Reactivate users'
  when 'admin.users.soft_delete'          then 'Soft delete users'
  when 'admin.users.erase_pii'            then 'Erase user personal information'
  when 'admin.users.reset_password'       then 'Reset user passwords'
  when 'admin.users.reset_mfa_factors'    then 'Reset user MFA factors'
  when 'admin.invites.create'             then 'Send invitations'
  when 'admin.invites.revoke'             then 'Revoke invitations'
  when 'admin.roles.view'                 then 'View roles'
  when 'admin.roles.edit_seeded'          then 'Edit seeded roles'
  when 'admin.roles.create_custom'        then 'Create custom roles'
  when 'admin.roles.delete_custom'        then 'Delete custom roles'
  when 'admin.roles.assign'               then 'Assign roles'
  when 'admin.roles.revoke'               then 'Revoke roles'
  when 'admin.audit_log.view'             then 'View the audit log'
  when 'admin.audit_log.export'           then 'Export the audit log'
  when 'admin.target_cycle.unlock'        then 'Unlock locked target cycles'
  when 'admin.pricing_tier.view'          then 'View pricing tiers'
  when 'admin.pricing_tier.edit'          then 'Edit pricing tiers'
  when 'admin.feature_flag.view'          then 'View feature flags'
  when 'admin.feature_flag.toggle'        then 'Toggle feature flags'
  when 'admin.status_page.publish'        then 'Publish status page updates'
  when 'admin.debug_console.view'         then 'View the debug console'
  when 'admin.session.force_logout'       then 'Force log out sessions'
  when 'admin.service_principal.issue_token'
                                          then 'Issue service principal tokens'
  when 'admin.audit_privacy.read'         then 'Read sensitive audit details'

  -- team.*
  when 'team.users.view'                  then 'View team members'
  when 'team.users.invite'                then 'Invite team members'
  when 'team.users.deactivate'            then 'Deactivate team members'
  when 'team.users.reactivate'            then 'Reactivate team members'
  when 'team.users.soft_delete'           then 'Soft delete team members'
  when 'team.users.reset_password'        then 'Reset a team member''s password'
  when 'team.users.reset_mfa'             then 'Reset another user''s MFA'
  when 'team.users.self_update'           then 'Update your own profile'
  when 'team.roles.view'                  then 'View team roles'
  when 'team.roles.create_custom'         then 'Create custom team roles'
  when 'team.roles.assign'                then 'Assign team roles'
  when 'team.roles.revoke'                then 'Revoke team roles'
  when 'team.hierarchy.suspend'           then 'Suspend hierarchy nodes'
  when 'team.hierarchy.delete'            then 'Delete hierarchy nodes'
  when 'team.audit_log.view'              then 'View the team audit log'
  when 'team.audit_log.export'            then 'Export the team audit log'
  when 'team.session.force_logout'        then 'Force log out team sessions'

  -- account.* / business_timing.*
  when 'account.configure'                then 'Configure account settings'
  when 'business_timing.configure'        then 'Configure business timing'

  -- billing.*
  when 'billing.invoice.view'             then 'View invoices'
  when 'billing.subscription.manage'      then 'Manage the subscription plan'
  when 'billing.payment_method.manage'    then 'Manage payment methods'
  when 'billing.usage.view'               then 'View usage and costs'
  when 'billing.usage_caps.edit'          then 'Adjust usage caps'

  -- integration.* / integrations.*
  when 'integration.toast.connect'        then 'Connect Toast POS'
  when 'integration.toast.view'           then 'View Toast POS data'
  when 'integration.7shifts.connect'      then 'Connect 7shifts labor'
  when 'integration.7shifts.view'         then 'View 7shifts labor data'
  when 'integration.opentable.connect'    then 'Connect OpenTable reservations'
  when 'integration.opentable.view'       then 'View OpenTable reservation data'
  when 'integration.qbo.connect'          then 'Connect QuickBooks Online'
  when 'integration.xero.connect'         then 'Connect Xero'
  when 'integration.key_rotate'           then 'Rotate integration keys'
  when 'integrations.configure'           then 'Configure vendor connections'

  -- workflow.*
  when 'workflow.catalog.view'            then 'View the workflow catalog'
  when 'workflow.run'                     then 'Run workflows'
  when 'workflow.approve'                 then 'Approve workflow steps'
  when 'workflow.reject'                  then 'Reject workflow steps'
  when 'workflow.create'                  then 'Create workflows'
  when 'workflow.delete'                  then 'Delete workflows'
  when 'workflow.history.view'            then 'View workflow run history'
  when 'workflow.tool.invoke'             then 'Invoke a workflow tool directly'

  else null
end
where human_label is null;

-- Defense-in-depth: fail the migration if any key still has a NULL
-- human_label (signals a coverage gap in the CASE above; matches the
-- R-1L pattern for product_label / category_label / scope_kind).

do $$
declare
  missing_count integer;
begin
  select count(*) into missing_count
    from public.permission_keys
   where human_label is null;
  if missing_count > 0 then
    raise exception
      'R-2L backfill left % permission_keys rows without human_label; '
      'expected zero. Investigate the human_label CASE in this migration '
      'before retrying.',
      missing_count;
  end if;
end;
$$;

comment on column public.permission_keys.human_label is
  'R-2L per-key UX label rendered in the R-2L role editor + permission '
  'explainer surfaces. Title Case English, no underscores, no '
  'engineering jargon (per memory/project_ux_writing_standard.md). '
  'Nullable in this slice per the R-1L expand-contract precedent; the '
  'NOT NULL flip is parked alongside the R-1L-FU follow-up. The Dart '
  'mirror at lib/auth/permission_key_metadata.dart is NOT-NULL-at-source '
  'via tool/permission_key_lint.dart HUMAN_LABEL_INVALID pass.';

-- ─── Step 1: Refresh operator_owner display_name + description ───────
--
-- v1 wording: "Operator Owner / Operator owner / customer. Full
-- operator-scoped operational + admin surfaces."
-- v2 wording: "Owner / Owns the business. Full operational access
-- plus billing, integrations, and team admin." (Title Case +
-- reads-as-training plain English).

update public.roles
   set display_name = 'Owner',
       description  = 'Owns the business. Full operational access plus '
                      'billing, integrations, and team admin.',
       updated_at   = now()
 where role_key   = 'operator_owner'
   and operator_id is null;

-- ─── Step 2: Seed v2 role rows ───────────────────────────────────────
--
-- UUID slots 7..D follow the foundation migration's slot 1..6 pattern
-- (super_admin .. operator_staff). is_seeded = true; operator_id =
-- null (global catalog rows). Title Case display_name and
-- reads-as-training description per the UX naming standard.

insert into public.roles (
  role_id, operator_id, role_key, display_name, description,
  is_seeded, is_editable, created_at, updated_at
)
values
  (
    '00000000-0000-0000-0000-000000000007'::uuid, null,
    'operator_general_manager',
    'General Manager',
    'Runs all locations and staff. Operational edit access plus staff '
    'admin and audit view; no billing or subscription mutations.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000008'::uuid, null,
    'location_manager',
    'Location Manager',
    'Runs one location. Invites and removes staff, edits schedules, '
    'sees variance and benchmarks at that location.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000009'::uuid, null,
    'supervisor',
    'Supervisor',
    'Supervises shifts at one location. Edits short-term schedule, '
    'marks shift covers, sees variance for shifts they ran.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-00000000000a'::uuid, null,
    'finance_analyst',
    'Finance Analyst',
    'Reviews invoices and usage, adjusts usage caps. Cannot change '
    'the subscription plan or connect billing integrations.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-00000000000b'::uuid, null,
    'auditor_compliance',
    'Auditor / Compliance',
    'Read-only audit trail and PII oversight. Sees who did what and '
    'when, exports the audit log, cannot mutate data.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-00000000000c'::uuid, null,
    'training_lead',
    'Training Lead',
    'Manages employee training and onboarding content. Edits '
    'supervisor content and the interview playbook; does not edit '
    'the F&F handbook source.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-00000000000d'::uuid, null,
    'team_admin',
    'Team Admin',
    'Manages the team roster, role assignments, MFA, and password '
    'resets. Does not see operational dashboards.',
    true, true, now(), now()
  )
on conflict do nothing;

-- ─── Step 3: Seed role_permissions for the v2 roles ──────────────────
--
-- The matrix below mirrors `docs/_indices/WAVE_2_R2L_DEFAULT_ROLE_CATALOG_V2_PROPOSAL.md`
-- section "Permission grant matrix". Every INSERT is idempotent via
-- `on conflict do nothing` (role_permissions PK is
-- (role_id, permission_key)).

-- operator_owner v2 additions — bring up to full v2 grant set.
-- Existing v1 grants stay; the new team.* + billing.* + admin.* keys
-- complete the Owner role.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'operator_owner' and r.operator_id is null
   and pk.key in (
     -- team.* — full team management surface.
     'team.users.view', 'team.users.invite', 'team.users.deactivate',
     'team.users.reactivate', 'team.users.soft_delete',
     'team.users.reset_password', 'team.users.reset_mfa',
     'team.users.self_update',
     'team.roles.view', 'team.roles.create_custom',
     'team.roles.assign', 'team.roles.revoke',
     'team.hierarchy.suspend', 'team.hierarchy.delete',
     'team.audit_log.view', 'team.audit_log.export',
     'team.session.force_logout',
     -- billing.* — Owner-only subscription + payment management.
     'billing.subscription.manage', 'billing.payment_method.manage',
     'billing.usage_caps.edit',
     -- account.* / business_timing.* — operator-level settings.
     'account.configure', 'business_timing.configure',
     -- admin.* additions per the v2 matrix.
     'admin.users.reset_mfa_factors',
     'admin.audit_privacy.read'
   )
on conflict do nothing;

-- operator_general_manager — broad operational, no billing /
-- subscription mutation, no integration connect.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'operator_general_manager' and r.operator_id is null
   and pk.key in (
     -- product.*
     'product.forgeflow.access', 'product.barrio.access',
     -- forgeflow.* — full operational surface.
     'forgeflow.shift.view', 'forgeflow.shift.edit',
     'forgeflow.variance.view', 'forgeflow.variance.edit',
     'forgeflow.schedule.view', 'forgeflow.schedule.edit',
     'forgeflow.baseline.view', 'forgeflow.baseline.override',
     'forgeflow.history.view',
     'forgeflow.benchmark.view', 'forgeflow.benchmark.edit',
     'forgeflow.target_profile.view', 'forgeflow.target_profile.manage',
     'forgeflow.target_cycle.view', 'forgeflow.target_cycle.unlock',
     'forgeflow.target_cycle.replace',
     'forgeflow.weekly_plan.view', 'forgeflow.weekly_plan.lock',
     'forgeflow.settings.view', 'forgeflow.settings.manage',
     -- barrio.* — view-all + supervisor_content edit + preston_lee
     -- view; no handbook edit (Owner-only).
     'barrio.handbook.view', 'barrio.interview_playbook.view',
     'barrio.jim_taylor.view', 'barrio.preston_lee.view',
     'barrio.supervisor_content.view', 'barrio.supervisor_content.edit',
     'barrio.el_podio.view', 'barrio.streak.view',
     -- team.* — full member admin, no roles create_custom, no audit
     -- export.
     'team.users.view', 'team.users.invite', 'team.users.deactivate',
     'team.users.reactivate', 'team.users.reset_password',
     'team.users.reset_mfa', 'team.users.self_update',
     'team.roles.view', 'team.roles.assign', 'team.roles.revoke',
     'team.audit_log.view',
     -- admin.* — view-only on members + audit; no PII erase, no
     -- pricing_tier.edit.
     'admin.users.view', 'admin.audit_log.view',
     -- workflow.* — Phase 12 placeholder; granted to operate workflows.
     'workflow.catalog.view', 'workflow.run', 'workflow.history.view'
   )
on conflict do nothing;

-- location_manager — single-location scope; the runtime resolver
-- enforces scope (R-1L's scope_kind / R-2L editor blocks org_wide
-- keys at location scope). The role_permissions row grants the key
-- universally; the resolver scopes the grant via user_roles.location_id.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'location_manager' and r.operator_id is null
   and pk.key in (
     -- product.*
     'product.forgeflow.access', 'product.barrio.access',
     -- forgeflow.* — operational surface excluding org-wide tools.
     'forgeflow.shift.view', 'forgeflow.shift.edit',
     'forgeflow.variance.view',
     'forgeflow.schedule.view', 'forgeflow.schedule.edit',
     'forgeflow.baseline.view',
     'forgeflow.history.view',
     'forgeflow.benchmark.view',
     'forgeflow.target_profile.view',
     'forgeflow.target_cycle.view',
     'forgeflow.weekly_plan.view',
     'forgeflow.settings.view',
     -- barrio.* — view-only at the location.
     'barrio.handbook.view', 'barrio.interview_playbook.view',
     'barrio.jim_taylor.view', 'barrio.preston_lee.view',
     'barrio.supervisor_content.view', 'barrio.el_podio.view',
     'barrio.streak.view',
     -- team.* — invite + view, location-scoped via user_roles.location_id.
     'team.users.view', 'team.users.invite', 'team.users.deactivate',
     'team.users.self_update',
     'team.roles.view', 'team.roles.assign',
     -- workflow.* — view-only at launch.
     'workflow.catalog.view'
   )
on conflict do nothing;

-- supervisor — shift-floor role. forgeflow.shift.edit at this scope
-- requires an "own shifts only" runtime guard (operator decision
-- deferred to S-3); the catalog grant is the same dotted key,
-- scope-narrowed at the resolver layer.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'supervisor' and r.operator_id is null
   and pk.key in (
     -- product.*
     'product.forgeflow.access', 'product.barrio.access',
     -- forgeflow.* — minimal supervisor surface.
     'forgeflow.shift.view', 'forgeflow.shift.edit',
     'forgeflow.variance.view',
     'forgeflow.schedule.view',
     'forgeflow.history.view',
     'forgeflow.weekly_plan.view',
     -- barrio.* — read-only training surface.
     'barrio.handbook.view', 'barrio.interview_playbook.view',
     'barrio.jim_taylor.view', 'barrio.preston_lee.view',
     'barrio.supervisor_content.view', 'barrio.el_podio.view',
     'barrio.learning.complete_unit', 'barrio.streak.view',
     -- team.* — self profile update only.
     'team.users.self_update'
   )
on conflict do nothing;

-- finance_analyst — billing read + usage caps edit; no subscription
-- or payment method mutations.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'finance_analyst' and r.operator_id is null
   and pk.key in (
     'billing.invoice.view', 'billing.usage.view',
     'billing.usage_caps.edit',
     'admin.audit_log.view',
     'team.users.self_update'
   )
on conflict do nothing;

-- auditor_compliance — strictly read-only audit trail oversight.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'auditor_compliance' and r.operator_id is null
   and pk.key in (
     'admin.audit_log.view', 'admin.audit_log.export',
     'admin.users.view',
     'admin.audit_privacy.read',
     'team.audit_log.view', 'team.audit_log.export',
     'team.users.self_update'
   )
on conflict do nothing;

-- training_lead — product-agnostic training role. Today edits Barrio
-- supervisor content + interview playbook; no handbook edit.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'training_lead' and r.operator_id is null
   and pk.key in (
     'product.barrio.access',
     'barrio.handbook.view',
     'barrio.interview_playbook.view', 'barrio.interview_playbook.edit',
     'barrio.jim_taylor.view',
     'barrio.preston_lee.view',
     'barrio.supervisor_content.view', 'barrio.supervisor_content.edit',
     'barrio.el_podio.view',
     'barrio.streak.view',
     'team.users.self_update'
   )
on conflict do nothing;

-- team_admin — roster + role admin; no operational dashboards.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'team_admin' and r.operator_id is null
   and pk.key in (
     'team.users.view', 'team.users.invite', 'team.users.deactivate',
     'team.users.reactivate', 'team.users.reset_password',
     'team.users.reset_mfa', 'team.users.self_update',
     'team.roles.view', 'team.roles.assign', 'team.roles.revoke',
     'team.audit_log.view',
     'team.session.force_logout',
     'admin.users.view'
   )
on conflict do nothing;

-- ─── Step 4: Auto-migrate v1 user_roles to v2 roles ─────────────────
--
-- Mapping (per the proposal doc + operator approval log):
--   operator_manager     -> operator_general_manager (operator-wide).
--   operator_supervisor  -> supervisor (LOCATION-scoped; preserves
--                            location_id; fan out across the user's
--                            visible locations if location_id IS NULL).
--   operator_staff       -> supervisor (same fan-out logic; folded into
--                            shift supervisor).
--
-- Idempotency: the UPDATE / INSERT statements filter on the OLD role_id
-- so re-running after a successful pass is a no-op (no rows still
-- carry the v1 role_id).

-- 4a. operator_manager -> operator_general_manager (in-place flip).
update public.user_roles ur
   set role_id    = '00000000-0000-0000-0000-000000000007'::uuid,
       reason     = coalesce(reason, '') ||
                    case when reason is null or reason = '' then ''
                         else ' | ' end ||
                    'auto-migrated from operator_manager by R-2L',
       updated_at = now()
 where ur.role_id = '00000000-0000-0000-0000-000000000004'::uuid
   and ur.revoked_at is null;

-- 4b. operator_supervisor / operator_staff -> supervisor.
-- Step 1: in-place flip for rows that already carry a location_id
-- (location-scoped v1 grants — keep the location, narrow the role).

update public.user_roles ur
   set role_id    = '00000000-0000-0000-0000-000000000009'::uuid,
       reason     = coalesce(reason, '') ||
                    case when reason is null or reason = '' then ''
                         else ' | ' end ||
                    'auto-migrated from operator_supervisor by R-2L',
       updated_at = now()
 where ur.role_id = '00000000-0000-0000-0000-000000000005'::uuid
   and ur.revoked_at is null
   and ur.location_id is not null;

update public.user_roles ur
   set role_id    = '00000000-0000-0000-0000-000000000009'::uuid,
       reason     = coalesce(reason, '') ||
                    case when reason is null or reason = '' then ''
                         else ' | ' end ||
                    'auto-migrated from operator_staff by R-2L',
       updated_at = now()
 where ur.role_id = '00000000-0000-0000-0000-000000000006'::uuid
   and ur.revoked_at is null
   and ur.location_id is not null;

-- Step 2: fan out — for v1 supervisor / staff grants with NULL
-- location_id, insert one new supervisor grant per location the user
-- has visibility into, then revoke the original NULL-location grant.
-- "Visibility" = any active user_roles row for the same user +
-- operator with a non-null location_id, OR (when no such row exists)
-- every location in `locations` for that operator (per the proposal
-- doc's fall-back rule).

-- 2a. Fan out for users that already carry at least one location-scoped
-- grant in the same operator — insert one supervisor grant per such
-- location_id (deduping against any existing supervisor grant at that
-- location via the anti-join).
insert into public.user_roles (
  user_id, role_id, operator_id, location_id,
  valid_from, granted_by, reason, created_at, updated_at
)
select distinct
       ur.user_id,
       '00000000-0000-0000-0000-000000000009'::uuid,
       ur.operator_id,
       loc.location_id,
       now(),
       ur.granted_by,
       'auto-migrated from ' ||
         case ur.role_id
           when '00000000-0000-0000-0000-000000000005'::uuid
             then 'operator_supervisor'
           when '00000000-0000-0000-0000-000000000006'::uuid
             then 'operator_staff'
           else 'unknown'
         end || ' by R-2L (fan-out from NULL location_id; review)',
       now(),
       now()
  from public.user_roles ur
  join public.user_roles loc
    on loc.user_id     = ur.user_id
   and loc.operator_id = ur.operator_id
   and loc.revoked_at  is null
   and loc.location_id is not null
 where ur.role_id in (
         '00000000-0000-0000-0000-000000000005'::uuid,
         '00000000-0000-0000-0000-000000000006'::uuid
       )
   and ur.revoked_at  is null
   and ur.location_id is null
   and not exists (
     select 1
       from public.user_roles existing
      where existing.operator_id = ur.operator_id
        and existing.user_id     = ur.user_id
        and existing.role_id     =
              '00000000-0000-0000-0000-000000000009'::uuid
        and existing.location_id = loc.location_id
        and existing.revoked_at  is null
   );

-- 2b. Fan out for users with NO existing location-scoped grant —
-- fall back to every location in the operator's `locations`, per the
-- proposal doc's ambiguity fall-back.
insert into public.user_roles (
  user_id, role_id, operator_id, location_id,
  valid_from, granted_by, reason, created_at, updated_at
)
select distinct
       ur.user_id,
       '00000000-0000-0000-0000-000000000009'::uuid,
       ur.operator_id,
       rl.location_id,
       now(),
       ur.granted_by,
       'auto-migrated from ' ||
         case ur.role_id
           when '00000000-0000-0000-0000-000000000005'::uuid
             then 'operator_supervisor'
           when '00000000-0000-0000-0000-000000000006'::uuid
             then 'operator_staff'
           else 'unknown'
         end || ' by R-2L (fall-back fan-out; flag for review)',
       now(),
       now()
  from public.user_roles ur
  join public.locations rl
    on rl.operator_id = ur.operator_id
 where ur.role_id in (
         '00000000-0000-0000-0000-000000000005'::uuid,
         '00000000-0000-0000-0000-000000000006'::uuid
       )
   and ur.revoked_at  is null
   and ur.location_id is null
   and not exists (
     -- Skip users that already got fan-out coverage from step 2a.
     select 1
       from public.user_roles peer
      where peer.user_id     = ur.user_id
        and peer.operator_id = ur.operator_id
        and peer.role_id     =
              '00000000-0000-0000-0000-000000000009'::uuid
        and peer.revoked_at  is null
   )
   and not exists (
     select 1
       from public.user_roles existing
      where existing.operator_id = ur.operator_id
        and existing.user_id     = ur.user_id
        and existing.role_id     =
              '00000000-0000-0000-0000-000000000009'::uuid
        and existing.location_id = rl.location_id
        and existing.revoked_at  is null
   );

-- 2c. Revoke the original NULL-location v1 grants now that the
-- fan-out is in place. revoked_at preserves the audit trail.
update public.user_roles ur
   set revoked_at    = now(),
       revoked_by    = null,
       reason        = coalesce(reason, '') ||
                       case when reason is null or reason = '' then ''
                            else ' | ' end ||
                       'auto-revoked by R-2L (replaced by supervisor '
                       'location fan-out)',
       updated_at    = now()
 where ur.role_id in (
         '00000000-0000-0000-0000-000000000005'::uuid,
         '00000000-0000-0000-0000-000000000006'::uuid
       )
   and ur.revoked_at  is null
   and ur.location_id is null;

-- ─── Step 5: Soft-delete v1 retired role rows ───────────────────────
--
-- operator_manager / operator_supervisor / operator_staff are retired.
-- Hard delete is forbidden so the audit trail and any FK references
-- (role_permissions, role_audit_log) stay intact. The display_name
-- gets a `(retired)` suffix so any leftover admin UI rendering pulls
-- the v1 row reads as obviously decommissioned.

update public.roles
   set deleted_at   = now(),
       is_editable  = false,
       display_name = display_name ||
                      case when display_name like '%(retired)' then ''
                           else ' (retired)' end,
       updated_at   = now()
 where role_key in (
         'operator_manager',
         'operator_supervisor',
         'operator_staff'
       )
   and operator_id is null
   and deleted_at is null;

-- ─── Step 6: Emit auth_events_audit rows ────────────────────────────
--
-- One row per migrated user_role + one row per retired seeded role.
-- `actor_user_id` is NULL because the migration is system-emitted
-- (no human actor); the foundation migration's audit table already
-- supports NULL actor + NULL operator_id rows for system events.

-- 6a. Per migrated user_role row.
insert into public.auth_events_audit (
  actor_user_id, target_user_id, operator_id, location_id,
  event_type, event_payload, occurred_at, schema_version
)
select null,
       ur.user_id,
       ur.operator_id,
       ur.location_id,
       'auth.role.seeded_catalog_v2_published',
       jsonb_build_object(
         'slice', 'R-2L',
         'new_role_key', r.role_key,
         'new_role_id',  r.role_id,
         'reason',       ur.reason
       ),
       now(),
       1
  from public.user_roles ur
  join public.roles r on r.role_id = ur.role_id
 where ur.updated_at >= now() - interval '5 minutes'
   and ur.reason like '%R-2L%';

-- 6b. Per retired seeded role row.
insert into public.auth_events_audit (
  actor_user_id, target_user_id, operator_id, location_id,
  event_type, event_payload, occurred_at, schema_version
)
select null, null, null, null,
       'auth.role.seeded_catalog_v2_published',
       jsonb_build_object(
         'slice',            'R-2L',
         'retired_role_key', r.role_key,
         'retired_role_id',  r.role_id,
         'deleted_at',       r.deleted_at
       ),
       now(),
       1
  from public.roles r
 where r.role_key in (
         'operator_manager',
         'operator_supervisor',
         'operator_staff'
       )
   and r.operator_id is null
   and r.deleted_at  is not null
   and r.deleted_at  >= now() - interval '5 minutes';

commit;

-- Follow-up: NOT NULL flip on `permission_keys.human_label` is
-- deferred to the R-1L-FU follow-up migration (alongside the existing
-- product_label / category_label / scope_kind NOT NULL flip). The
-- runtime mirror at lib/auth/permission_key_metadata.dart is
-- NOT-NULL-at-source via tool/permission_key_lint.dart's
-- HUMAN_LABEL_INVALID pass, so the runtime cannot ship a key without
-- a humanLabel even while the DB column remains nullable.
