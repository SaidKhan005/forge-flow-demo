-- Wave 2 R-1L - Roles schema rewrite (product label + category + scope kind + implies).
--
-- Origin:
--   * debug.md:28-43 (RP-7 / RP-8 / RP-12 / RP-14 / RP-15 / OW-7a..g).
--     The operator brain-dump for Roles + Permissions calls for
--     categorisation by product → functionality, dependency tracking
--     (e.g. "edit" implies "view"; "manage members" implies
--     `team.users.view`), org-wide vs location-scoped tagging, and a
--     per-permission-key product label so the editor can group by
--     product.
--   * docs/_indices/WAVE_2_LEDGER.md Lane R row R-1L. R-2L (new Roles
--     editor UI) and S-3 (Roles screen simplification) are held in
--     the ledger pending this slice.
--   * Authority anchors:
--     - `lib/auth/permission_keys.dart` (frozen catalog mirror).
--     - `docs/contracts/auth_permission_key_catalog.md` (canonical
--       catalog doc).
--     - `lib/services/auth/custom_role_validator.dart` (Q-4's
--       advisory tables — `kOrgWidePermissionKeys`,
--       `kViewRequiredForWrite`, `kTeamUsersWriteKeys`). The schema
--       backfill mirrors the data already captured there so the
--       validator and the schema can never drift.
--     - CLAUDE.md "RLS-Ready Schema" — `permission_keys` is the
--       frozen catalog table, NOT an operator-scoped fact table, so
--       the (operator_id, location_id) discipline does NOT apply to
--       its rows. RLS is enabled with a service-role-only policy stub
--       from 9.0; this slice does not change that posture.
--     - CLAUDE.md "Time Guardrails" — no new timestamp columns are
--       added; `created_at` / `updated_at` already cover update audit.
--
-- Why this exists
-- ---------------
-- The Roles editor UX (R-2L) needs to group permission keys by
-- product → functionality, the runtime resolver needs to know which
-- keys auto-grant other keys (e.g. `team.users.invite` should also
-- grant `team.users.view`), and the proxy needs to reject
-- location-scoped grants for org-wide-only keys. Today those facts
-- live in three places:
--
--   1. The catalog markdown doc has per-category prose but no
--      machine-readable product label, category label, or scope
--      tag.
--   2. The custom_role_validator has hand-curated tables for
--      view-required-for-write pairs, member-management chains, and
--      org-wide-only keys — but those are UI-side advisory only.
--   3. The Dart constants file has the dotted-key strings but no
--      metadata.
--
-- This slice promotes those facts into the canonical
-- `public.permission_keys` table so the runtime resolver, the proxy
-- editor, and the audit log all read the same source of truth.
--
-- Expand-contract posture
-- -----------------------
-- The four new columns ship as NULLABLE in this expand-only
-- migration. The backfill `UPDATE` runs inline so existing rows get
-- non-null values before the migration commits. The follow-up
-- migration `R-1L-FU` flips the columns to NOT NULL after a clean
-- apply cycle on staging + production. Splitting the SET NOT NULL
-- into its own migration is the standard expand-contract pattern
-- enforced by `tool/migration_drift_scanner.dart` for any migration
-- after the grandfather cutoff at
-- `202605131030_b11_1_auth_handoff_codes.sql`.
--
-- Defense-in-depth: `tool/permission_key_lint.dart` is extended in
-- the same slice to fail CI when a new permission key is added
-- without `product_label` / `category_label` / `scope_kind` /
-- `implies` populated in the Dart mirror. The combination of
-- (NULLABLE columns at the schema layer + NOT-NULL enforcement at
-- the source-of-truth Dart layer) keeps the migration zero-downtime
-- while still preventing operators from ever shipping a key with
-- missing metadata.

begin;

-- Local statement timeout / lock timeout. `permission_keys` carries
-- ~103 rows so the ALTER TABLE / UPDATE pair runs sub-second on
-- realistic data; the explicit timeouts are belt-and-braces against
-- a stalled session blocking the cutover.
set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── permission_keys: new columns (NULLABLE, expand-only) ────────────

alter table public.permission_keys
  add column if not exists product_label text;

alter table public.permission_keys
  add column if not exists category_label text;

alter table public.permission_keys
  add column if not exists scope_kind text;

alter table public.permission_keys
  drop constraint if exists permission_keys_scope_kind_check;

alter table public.permission_keys
  add constraint permission_keys_scope_kind_check
  check (scope_kind is null
         or scope_kind in ('org_wide', 'location_scoped', 'either'));

-- `implies` is the recursive auto-grant list. Default empty array so
-- callers that read this column without filtering NULLs see a usable
-- list. Adding the column with DEFAULT '{}'::text[] on a 103-row
-- frozen catalog is safe (PG 12+ uses the table-level default
-- without rewriting the heap).
alter table public.permission_keys
  add column if not exists implies text[] not null default '{}'::text[];

-- ─── Backfill product_label / category_label / scope_kind ────────────
--
-- The mapping below mirrors the per-category structure from
-- `docs/contracts/auth_permission_key_catalog.md` and the org-wide
-- list from `lib/services/auth/custom_role_validator.dart`'s
-- `kOrgWidePermissionKeys`. Adding a new key requires touching:
--   1. The migration's seed (foundation or follow-up).
--   2. `lib/auth/permission_keys.dart` (constant + metadata entry).
--   3. `docs/contracts/auth_permission_key_catalog.md` row.
-- The new `permission_key_lint.dart` rule fails when any of those
-- three are missing labels.

update public.permission_keys
   set product_label = case category
       when 'product'         then 'product'
       when 'forgeflow'       then 'forgeflow'
       when 'barrio'          then 'barrio'
       when 'admin'           then 'admin'
       when 'team'            then 'team'
       when 'account'         then 'account'
       when 'business_timing' then 'business_timing'
       when 'billing'         then 'billing'
       when 'integration'     then 'integration'
       when 'integrations'    then 'integration'
       when 'workflow'        then 'workflow'
       else category
     end
 where product_label is null;

update public.permission_keys
   set category_label = case category
       when 'product'         then 'Product access'
       when 'forgeflow'       then 'Forge & Flow surfaces'
       when 'barrio'          then 'Barrio learning'
       when 'admin'           then 'F&F admin actions'
       when 'team'            then 'Team management'
       when 'account'         then 'Account settings'
       when 'business_timing' then 'Business timing'
       when 'billing'         then 'Billing'
       when 'integration'     then 'Vendor integrations'
       when 'integrations'    then 'Vendor integrations'
       when 'workflow'        then 'Workflows'
       else category
     end
 where category_label is null;

-- scope_kind backfill — org_wide entries mirror
-- `kOrgWidePermissionKeys` in custom_role_validator.dart. Every
-- other key defaults to 'either' so the runtime resolver does not
-- accidentally reject grants for legitimately scoped keys.
update public.permission_keys
   set scope_kind = 'org_wide'
 where scope_kind is null
   and key in (
     -- account.* + business_timing.* — operator-level settings.
     'account.configure',
     'business_timing.configure',
     -- billing.* — all billing flows are operator-scoped.
     'billing.invoice.view',
     'billing.subscription.manage',
     'billing.payment_method.manage',
     'billing.usage.view',
     'billing.usage_caps.edit',
     -- admin.* org-wide flows (F&F-internal admin + pricing tier +
     -- feature flags + status page + debug console + service
     -- principals + audit privacy + seeded-role edits).
     'admin.pricing_tier.view',
     'admin.pricing_tier.edit',
     'admin.feature_flag.view',
     'admin.feature_flag.toggle',
     'admin.status_page.publish',
     'admin.debug_console.view',
     'admin.service_principal.issue_token',
     'admin.audit_privacy.read',
     'admin.roles.edit_seeded',
     -- integrations.* + integration.*.connect + key rotation. Vendor
     -- credential surfaces are operator-scoped (the view siblings
     -- are scoped 'either' per HP #11).
     'integrations.configure',
     'integration.toast.connect',
     'integration.7shifts.connect',
     'integration.opentable.connect',
     'integration.qbo.connect',
     'integration.xero.connect',
     'integration.key_rotate'
   );

update public.permission_keys
   set scope_kind = 'either'
 where scope_kind is null;

-- ─── Backfill implies — view-required-for-write + member-mgmt chain ──
--
-- Mirrors `kViewRequiredForWrite` and `kTeamUsersWriteKeys` in
-- `lib/services/auth/custom_role_validator.dart`. The validator
-- emits an advisory warning when these dependencies are not
-- selected together; the schema now auto-grants them at resolve
-- time so the operator cannot ship an incoherent role.
--
-- Important: `implies` propagates ALLOW only. The runtime resolver
-- (`PermissionResolver.resolveAll`) walks the imply graph
-- recursively for keys whose effect is `allow`; a `deny` rule is
-- never propagated through implies (deny stays the safer state).

-- view-required-for-write pairs.
update public.permission_keys set implies = array['forgeflow.shift.view']             where key = 'forgeflow.shift.edit';
update public.permission_keys set implies = array['forgeflow.variance.view']          where key = 'forgeflow.variance.edit';
update public.permission_keys set implies = array['forgeflow.schedule.view']          where key = 'forgeflow.schedule.edit';
update public.permission_keys set implies = array['forgeflow.baseline.view']          where key = 'forgeflow.baseline.override';
update public.permission_keys set implies = array['forgeflow.benchmark.view']         where key = 'forgeflow.benchmark.edit';
update public.permission_keys set implies = array['forgeflow.target_profile.view']    where key = 'forgeflow.target_profile.manage';
update public.permission_keys set implies = array['forgeflow.target_cycle.view']      where key = 'forgeflow.target_cycle.unlock';
update public.permission_keys set implies = array['forgeflow.target_cycle.view']      where key = 'forgeflow.target_cycle.replace';
update public.permission_keys set implies = array['forgeflow.weekly_plan.view']       where key = 'forgeflow.weekly_plan.lock';
update public.permission_keys set implies = array['forgeflow.settings.view']          where key = 'forgeflow.settings.manage';

update public.permission_keys set implies = array['barrio.handbook.view']             where key = 'barrio.handbook.edit';
update public.permission_keys set implies = array['barrio.interview_playbook.view']   where key = 'barrio.interview_playbook.edit';
update public.permission_keys set implies = array['barrio.preston_lee.view']          where key = 'barrio.preston_lee.edit';
update public.permission_keys set implies = array['barrio.supervisor_content.view']   where key = 'barrio.supervisor_content.edit';

update public.permission_keys set implies = array['admin.roles.view']                 where key = 'admin.roles.edit_seeded';
update public.permission_keys set implies = array['admin.roles.view']                 where key = 'admin.roles.create_custom';
update public.permission_keys set implies = array['admin.roles.view']                 where key = 'admin.roles.delete_custom';
update public.permission_keys set implies = array['admin.roles.view']                 where key = 'admin.roles.assign';
update public.permission_keys set implies = array['admin.roles.view']                 where key = 'admin.roles.revoke';
update public.permission_keys set implies = array['admin.users.view']                 where key = 'admin.users.create';
update public.permission_keys set implies = array['admin.users.view']                 where key = 'admin.users.deactivate';
update public.permission_keys set implies = array['admin.users.view']                 where key = 'admin.users.reactivate';
update public.permission_keys set implies = array['admin.users.view']                 where key = 'admin.users.soft_delete';
update public.permission_keys set implies = array['admin.users.view']                 where key = 'admin.users.erase_pii';
update public.permission_keys set implies = array['admin.users.view']                 where key = 'admin.users.reset_password';
update public.permission_keys set implies = array['admin.users.view']                 where key = 'admin.users.reset_mfa_factors';
update public.permission_keys set implies = array['admin.audit_log.view']             where key = 'admin.audit_log.export';
update public.permission_keys set implies = array['admin.pricing_tier.view']          where key = 'admin.pricing_tier.edit';
update public.permission_keys set implies = array['admin.feature_flag.view']          where key = 'admin.feature_flag.toggle';

-- team.* write keys imply team.users.view / team.roles.view per
-- `kTeamUsersWriteKeys` + `kTeamRolesWriteKeys` in the validator.
update public.permission_keys set implies = array['team.users.view']                  where key = 'team.users.invite';
update public.permission_keys set implies = array['team.users.view']                  where key = 'team.users.deactivate';
update public.permission_keys set implies = array['team.users.view']                  where key = 'team.users.reactivate';
update public.permission_keys set implies = array['team.users.view']                  where key = 'team.users.soft_delete';
update public.permission_keys set implies = array['team.users.view']                  where key = 'team.users.reset_password';
update public.permission_keys set implies = array['team.users.view']                  where key = 'team.users.reset_mfa';
update public.permission_keys set implies = array['team.users.view']                  where key = 'team.session.force_logout';
update public.permission_keys set implies = array['team.roles.view']                  where key = 'team.roles.create_custom';
update public.permission_keys set implies = array['team.roles.view']                  where key = 'team.roles.assign';
update public.permission_keys set implies = array['team.roles.view']                  where key = 'team.roles.revoke';
update public.permission_keys set implies = array['team.audit_log.view']              where key = 'team.audit_log.export';

-- ─── Defense-in-depth: backfill safety net ───────────────────────────
--
-- Any key still NULL on product_label / category_label / scope_kind
-- after the backfill above is a coverage bug in this migration.
-- Fail-loud at the migration boundary so the gap surfaces in CI
-- instead of leaking into the runtime resolver.

do $$
declare
  missing_count integer;
begin
  select count(*) into missing_count
    from public.permission_keys
   where product_label is null
      or category_label is null
      or scope_kind is null;
  if missing_count > 0 then
    raise exception
      'R-1L backfill left % permission_keys rows without product_label / '
      'category_label / scope_kind; expected zero. Investigate the '
      'category-to-label map in this migration before retrying.',
      missing_count;
  end if;
end;
$$;

-- ─── Documentation comments ──────────────────────────────────────────

comment on column public.permission_keys.product_label is
  'R-1L product grouping for the Roles editor (R-2L). E.g. ''forgeflow'', ''team'', ''integration''. The R-2L editor groups permission keys by product → functionality so the operator can grant an entire product at once and then prune.';
comment on column public.permission_keys.category_label is
  'R-1L UI grouping label for the Roles editor (R-2L). E.g. ''Team management'', ''Vendor integrations''. Operator-facing copy per the UX writing standard.';
comment on column public.permission_keys.scope_kind is
  'R-1L grantable scope. ''org_wide'' = only valid at business scope (e.g. billing, pricing tier); ''location_scoped'' = only valid at a single location; ''either'' = valid at any scope. R-2L editor blocks location-scoped role authors from selecting org_wide keys; Q-4''s advisory validator already enforces this UI-side.';
comment on column public.permission_keys.implies is
  'R-1L auto-grant list. When a role grants this key with effect=''allow'', the resolver recursively also grants every key listed here. Deny is NEVER propagated through implies (deny stays the safer state). Mirrors view-required-for-write + member-management chain rules from lib/services/auth/custom_role_validator.dart.';

commit;

-- Follow-up: R-1L-FU flips product_label / category_label / scope_kind
-- to NOT NULL after a clean apply on staging + production. The
-- runtime mirror (`lib/auth/permission_keys.dart` PermissionKeyMetadata
-- entries) is NOT-NULL-at-source via the permission_key_lint.dart
-- rule introduced in this slice, so the runtime cannot ship a key
-- without metadata even while the DB columns remain nullable.
