-- Phase 9.0 - Auth schema foundation: identity, RBAC, sessions, audit, MFA.
--
-- Single deterministic migration that turns the 11a cloud-foundation
-- schema (operators, locations, users, operator_admins) into the full
-- 2026-industry-standard auth surface promised by phase_9_auth_plan.md:
--
--   New tables:
--     * roles                      - global + operator-scoped roles
--     * permission_keys            - frozen catalog (seeded from this file)
--     * role_permissions           - bundle definition (allow / deny; deny wins)
--     * user_roles                 - grant + scope + time-bound; partial-unique
--                                    on the active grant
--     * auth_sessions              - own-ledger of Firebase session lifecycle
--     * auth_events_audit          - APPEND-ONLY audit log
--     * mfa_factors                - enrolled second factor inventory
--     * tncs_acceptances           - never-overwrite T&Cs acceptance log
--     * password_history           - last 5 password hashes per user
--     * auth_invites               - invite-with-expiry
--     * role_audit_log             - APPEND-ONLY role/permission diff history
--     * external_identity_links    - Phase 8 vendor-employee bridge (NOT auth
--                                    source-of-truth)
--
--   Extensions to existing tables:
--     * users           gains firebase_uid, external_id, status, deleted_at,
--                       roles_version, mfa_required, last_login_at,
--                       last_active_at, password_set_at, email_verified_at,
--                       first_name, last_name, display_name, primary_role_id,
--                       preferred_locale, avatar_url; legacy `role` column
--                       is migrated into `user_roles` and dropped.
--     * operator_admins gains scope_type, scope_location_id, valid_from,
--                       valid_until.
--
-- Hard rules carried from the active CLAUDE.md authority:
--
--   1. TIMESTAMPTZ everywhere. The unzoned local-time variant is banned
--      in operator-scoped tables (silent DST corruption).
--   2. RLS performance discipline: every operator-scoped fact-table index
--      leads with `operator_id` (or `(operator_id, location_id)`). Indexes
--      that lead with anything else on operator-scoped tables are forbidden.
--      The verification audit query in
--      `db/verification/202604250006_advisor_schema_hardening_audits.sql`
--      enforces this against the new auth tables.
--   3. RLS enabled on every new table with a service-role-only policy stub.
--      Phase 9.2 flips these stubs to real per-tenant policies; until then
--      only the proxy's service-role connection touches these tables.
--   4. Audit tables are append-only at the grant shape. UPDATE / DELETE are
--      revoked from PUBLIC and from `service_role`; INSERT and SELECT are
--      granted to `service_role`. PG enforces the grant shape; rows cannot
--      be mutated or deleted by the proxy.
--   5. Composite (operator_id, location_id) FKs reference
--      `locations(operator_id, location_id)` for every operator + location
--      scoped row, rejecting (operator_a, location_b) cross-tenant
--      mismatches at the database layer.
--   6. Permission keys are app-defined and frozen at code level. The
--      catalog seeded here mirrors `lib/auth/permission_keys.dart` and
--      `docs/contracts/auth_permission_key_catalog.md`. Operators may not
--      invent new keys at runtime.
--
-- This migration does not call any provider, does not write any user or
-- session row, and does not change any runtime auth behavior. Phase 9.1
-- wires the live JWT verifier; Phase 9.2 turns on real per-tenant RLS.

-- ─── Trigger function for updated_at on auth tables ────────────────────
--
-- Kept distinct from `public.advisor_set_updated_at` (corpus side, 11a.3)
-- and `public.cloud_foundation_set_updated_at` (cloud side, 11a.11c.1) so
-- the auth surface is self-contained: dropping it does not orphan corpus
-- or cloud-foundation triggers and vice-versa.
create or replace function public.auth_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ─── permission_keys ──────────────────────────────────────────────────
--
-- Frozen catalog. `frozen` defaults to true so operators cannot invent
-- new keys at runtime; `requires_mfa` flags keys that need a fresh
-- `auth_time` MFA assertion to use. Phase 9.6 reads this catalog to
-- resolve permission decisions; Phase 9.9 renders the read-only
-- catalog viewer.
create table if not exists public.permission_keys (
  key text primary key,
  category text not null,
  description text not null,
  requires_mfa boolean not null default false,
  frozen boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ─── roles ─────────────────────────────────────────────────────────────
--
-- `operator_id IS NULL` rows are global / F&F-defined seeded roles
-- (super_admin, ff_support, operator_owner, operator_manager,
-- operator_supervisor, operator_staff). Operator-scoped custom roles
-- carry a non-null `operator_id` set by 9.6's POST /v1/admin/auth/roles
-- endpoint.
create table if not exists public.roles (
  role_id uuid primary key default gen_random_uuid(),
  operator_id uuid null references public.operators(operator_id)
    on delete cascade,
  role_key text not null,
  display_name text not null,
  description text not null default '',
  is_seeded boolean not null default false,
  is_editable boolean not null default true,
  created_by uuid null,
  updated_by uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null
);

-- Composite uniqueness for operator-scoped roles. NULL operator_id is
-- handled by a separate partial unique index below (Postgres treats NULL
-- as distinct in plain UNIQUE).
create unique index if not exists roles_operator_role_key_idx
  on public.roles (operator_id, role_key)
  where operator_id is not null;

create unique index if not exists roles_global_role_key_idx
  on public.roles (role_key)
  where operator_id is null;

-- ─── role_permissions ─────────────────────────────────────────────────
--
-- Bundle definition: `effect = 'deny'` wins over `effect = 'allow'` per
-- the resolution algorithm in 9.6. Composite PK so a (role, key) pair
-- has at most one row.
create table if not exists public.role_permissions (
  role_id uuid not null references public.roles(role_id)
    on delete cascade,
  permission_key text not null references public.permission_keys(key)
    on delete restrict,
  effect text not null
    check (effect in ('allow', 'deny')),
  created_by uuid null,
  updated_by uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (role_id, permission_key)
);

-- ─── user_roles ───────────────────────────────────────────────────────
--
-- Grant + scope + time-bound. `location_id NULL` means operator-wide
-- grant; non-null means location-scoped. `valid_until NULL` means
-- non-expiring. `revoked_at` keeps revoked grants visible for audit.
--
-- Composite FK on (operator_id-of-user, location_id) is enforced via the
-- denormalized `operator_id` column written by the application layer
-- (the proxy resolves user_id -> operator_id and writes both). The
-- (operator_id, location_id) composite FK target is `locations`.
create table if not exists public.user_roles (
  user_role_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  role_id uuid not null references public.roles(role_id)
    on delete restrict,
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  location_id uuid null,
  valid_from timestamptz not null default now(),
  valid_until timestamptz null,
  granted_by uuid not null references public.users(user_id)
    on delete restrict,
  revoked_at timestamptz null,
  revoked_by uuid null references public.users(user_id)
    on delete set null,
  reason text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Composite FK rejects (operator_a, location_b) mismatches when the
  -- grant is location-scoped. NULL location_id passes MATCH SIMPLE for
  -- operator-wide grants.
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

-- Active-grant uniqueness, tenant-leading. The composite leads with
-- operator_id so the same user can hold the same role across different
-- operators (the super_admin / ff_support pattern needs this) while a
-- duplicate active grant within one (operator, user, role, location)
-- scope is still blocked. NULL location_id is treated as a sentinel
-- UUID so operator-wide grants share the same uniqueness slot.
--
-- The drop-then-create pattern guarantees re-applies of this migration
-- replace any pre-fix shape that was created by an earlier draft of
-- 9.0 (where the index led with user_id and ignored operator_id).
drop index if exists public.user_roles_active_grant_idx;
create unique index if not exists user_roles_active_grant_idx
  on public.user_roles (
    operator_id,
    user_id,
    role_id,
    coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where revoked_at is null;

-- Tenant-leading lookup index for RLS performance.
create index if not exists user_roles_tenant_lookup_idx
  on public.user_roles (operator_id, location_id, user_id);

-- ─── auth_sessions ────────────────────────────────────────────────────
--
-- Own ledger of Firebase session lifecycle. Phase 9.3 writes here on
-- login; phase 9.8's force-logout-all-sessions revokes by setting
-- revoked_at + reason.
create table if not exists public.auth_sessions (
  session_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  refresh_token_hash text not null,
  ip inet null,
  user_agent text null,
  device_fingerprint text null,
  geo_country char(2) null
    check (geo_country is null or geo_country ~ '^[A-Z]{2}$'),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz null,
  revoked_reason text null
);

-- Per-user session-state lookup. Active sessions filter on
-- `revoked_at IS NULL`; this index makes that scan cheap.
create index if not exists auth_sessions_user_active_idx
  on public.auth_sessions (user_id, last_seen_at desc)
  where revoked_at is null;

-- ─── mfa_factors ──────────────────────────────────────────────────────
--
-- Enrolled second-factor inventory. `factor_metadata` carries the
-- Firebase factor uid for passkey/totp and the hashed code material
-- for `recovery_code` rows. SMS is intentionally absent (NIST SP
-- 800-63B-4 deprecated SMS as a primary AAL2 factor).
create table if not exists public.mfa_factors (
  factor_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  factor_type text not null
    check (factor_type in ('passkey', 'totp', 'recovery_code')),
  factor_metadata jsonb not null default '{}'::jsonb,
  enrolled_at timestamptz not null default now(),
  last_used_at timestamptz null,
  revoked_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists mfa_factors_user_active_idx
  on public.mfa_factors (user_id, factor_type)
  where revoked_at is null;

-- ─── tncs_acceptances ─────────────────────────────────────────────────
--
-- Never-overwrite T&Cs acceptance log. Phase 9.8 writes the legal text
-- versions; this slice only stores the schema. Operator + user are
-- both required because the accepter is acting on behalf of an
-- operator.
create table if not exists public.tncs_acceptances (
  acceptance_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  tncs_version text not null,
  accepted_at timestamptz not null default now(),
  ip inet null,
  user_agent text null,
  created_at timestamptz not null default now()
);

-- Tenant-leading audit lookup.
create index if not exists tncs_acceptances_operator_user_idx
  on public.tncs_acceptances (operator_id, user_id, accepted_at);

-- ─── password_history ────────────────────────────────────────────────
--
-- Last 5 password hashes per user; pruned by trigger / scheduled job in
-- 9.5 (HIBP + reuse-detection slice). Cleared on GDPR erasure (9.8).
-- Firebase manages the actual password hash for login; this column is a
-- copy used only for reuse-detection at password-change time.
create table if not exists public.password_history (
  entry_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  password_hash text not null,
  set_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists password_history_user_recent_idx
  on public.password_history (user_id, set_at desc);

-- ─── auth_invites ─────────────────────────────────────────────────────
--
-- Invite-with-expiry. Magic-link delivered via Firebase email template;
-- the magic-link target carries the `invite_token_hash` as a query
-- param the client posts back to `/v1/admin/auth/invites/accept` (9.8).
create table if not exists public.auth_invites (
  invite_id uuid primary key default gen_random_uuid(),
  email text not null,
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  role_id uuid not null references public.roles(role_id)
    on delete restrict,
  location_id uuid null,
  invited_by uuid not null references public.users(user_id)
    on delete restrict,
  expires_at timestamptz not null,
  accepted_at timestamptz null,
  revoked_at timestamptz null,
  invite_token_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Composite FK forbids cross-tenant location scopes.
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

-- Open-invite uniqueness: at most one open invite per (operator, email)
-- at a time. Acceptance / revocation closes the partial slot.
create unique index if not exists auth_invites_open_email_idx
  on public.auth_invites (operator_id, email)
  where revoked_at is null and accepted_at is null;

-- Tenant-leading expiry sweep.
create index if not exists auth_invites_operator_expires_idx
  on public.auth_invites (operator_id, expires_at);

-- ─── auth_events_audit (APPEND-ONLY) ─────────────────────────────────
--
-- Every login / logout / token refresh / password change / MFA
-- enrollment / role change / soft-delete / GDPR redaction emits a row
-- here. UPDATE / DELETE are revoked from PUBLIC and from service_role
-- below; the proxy can only INSERT and SELECT. The schema_version
-- column gives the redaction runbook a way to mark redacted rows
-- without dropping the audit trail.
create table if not exists public.auth_events_audit (
  event_id uuid primary key default gen_random_uuid(),
  actor_user_id uuid null references public.users(user_id)
    on delete set null,
  target_user_id uuid null references public.users(user_id)
    on delete set null,
  operator_id uuid null,
  location_id uuid null,
  event_type text not null,
  event_payload jsonb not null default '{}'::jsonb,
  ip inet null,
  user_agent text null,
  geo_country char(2) null
    check (geo_country is null or geo_country ~ '^[A-Z]{2}$'),
  request_id uuid null,
  occurred_at timestamptz not null default now(),
  schema_version integer not null default 1,
  created_at timestamptz not null default now()
);

-- Tenant-leading time-window queries are the dominant access pattern
-- for the audit log viewer (9.9). NULL operator_id rows (system-wide
-- events like Firebase JWKS rotations) live in a separate partial
-- index keyed only by occurred_at.
create index if not exists auth_events_audit_operator_occurred_idx
  on public.auth_events_audit (operator_id, occurred_at desc)
  where operator_id is not null;

create index if not exists auth_events_audit_global_occurred_idx
  on public.auth_events_audit (occurred_at desc)
  where operator_id is null;

-- Actor / target lookup indexes are tenant-leading so RLS-wrapped audit
-- queries that filter by `(operator_id, actor_user_id)` or
-- `(operator_id, target_user_id)` keep operator_id as the first probe
-- column. The partial predicate also requires `operator_id is not null`
-- so global / system-level rows do not bloat the per-operator
-- per-actor lookup indexes — they are covered by the
-- `auth_events_audit_global_occurred_idx` partial above.
create index if not exists auth_events_audit_actor_occurred_idx
  on public.auth_events_audit (operator_id, actor_user_id, occurred_at desc)
  where operator_id is not null and actor_user_id is not null;

create index if not exists auth_events_audit_target_occurred_idx
  on public.auth_events_audit (operator_id, target_user_id, occurred_at desc)
  where operator_id is not null and target_user_id is not null;

-- ─── role_audit_log (APPEND-ONLY) ────────────────────────────────────
--
-- Diff history of role + permission changes. Either `role_id` (catalog
-- mutation) or `user_role_id` (grant mutation) is set; the change_payload
-- carries before/after. Same append-only grant shape as
-- auth_events_audit (REVOKE UPDATE/DELETE; GRANT INSERT, SELECT).
create table if not exists public.role_audit_log (
  entry_id uuid primary key default gen_random_uuid(),
  role_id uuid null,
  user_role_id uuid null,
  change_type text not null,
  change_payload jsonb not null default '{}'::jsonb,
  changed_by uuid not null references public.users(user_id)
    on delete restrict,
  changed_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists role_audit_log_role_changed_idx
  on public.role_audit_log (role_id, changed_at desc)
  where role_id is not null;

create index if not exists role_audit_log_user_role_changed_idx
  on public.role_audit_log (user_role_id, changed_at desc)
  where user_role_id is not null;

create index if not exists role_audit_log_changed_at_idx
  on public.role_audit_log (changed_at desc);

-- ─── external_identity_links (Phase 8 vendor bridge) ─────────────────
--
-- Phase 8 / 8R / Operations El Podio later phases consume this table to
-- attribute vendor data (sales, shifts, reservations) to real app
-- users. Vendor APIs do NOT become identity authority - this is a
-- mapping bridge only.
create table if not exists public.external_identity_links (
  link_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  location_id uuid null,
  vendor text not null,
  labor_email text null,
  labor_employee_id text null,
  pos_employee_id text null,
  vendor_display_name_snapshot text null,
  last_linked_at timestamptz not null default now(),
  revoked_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

-- Per-vendor identity uniqueness: one link per (operator, vendor,
-- vendor-employee-id) when present. Partial because labor / pos can be
-- linked independently.
create unique index if not exists external_identity_links_labor_idx
  on public.external_identity_links (operator_id, vendor, labor_employee_id)
  where labor_employee_id is not null;

create unique index if not exists external_identity_links_pos_idx
  on public.external_identity_links (operator_id, vendor, pos_employee_id)
  where pos_employee_id is not null;

-- Tenant-leading lookup for "who is this user across vendors".
create index if not exists external_identity_links_operator_user_idx
  on public.external_identity_links (operator_id, user_id);

-- ─── Extend public.users ─────────────────────────────────────────────
--
-- firebase_uid carries a NOT NULL DEFAULT gen_random_uuid()::text so existing
-- (test-seed) rows get distinct placeholder values and the UNIQUE
-- constraint can be added immediately. Phase 9.1 overwrites firebase_uid
-- with the real Firebase Identity Platform uid as users link in. Firebase
-- Identity Platform accepts arbitrary string uids, so this is text.

alter table public.users
  add column if not exists firebase_uid text not null default gen_random_uuid()::text;

alter table public.users
  drop constraint if exists users_firebase_uid_key;

alter table public.users
  add constraint users_firebase_uid_key unique (firebase_uid);

alter table public.users
  add column if not exists external_id text null;

alter table public.users
  drop constraint if exists users_external_id_key;

alter table public.users
  add constraint users_external_id_key unique (external_id);

alter table public.users
  add column if not exists status text not null default 'invited';

alter table public.users
  drop constraint if exists users_status_check;

alter table public.users
  add constraint users_status_check
  check (status in (
    'invited',
    'active',
    'suspended',
    'dormant_30',
    'dormant_60',
    'dormant_90',
    'deleted'
  ));

alter table public.users
  add column if not exists deleted_at timestamptz null;

alter table public.users
  add column if not exists roles_version integer not null default 0;

alter table public.users
  add column if not exists mfa_required boolean not null default false;

alter table public.users
  add column if not exists last_login_at timestamptz null;

alter table public.users
  add column if not exists last_active_at timestamptz null;

alter table public.users
  add column if not exists password_set_at timestamptz null;

alter table public.users
  add column if not exists email_verified_at timestamptz null;

alter table public.users
  add column if not exists first_name text null;

alter table public.users
  add column if not exists last_name text null;

alter table public.users
  add column if not exists display_name text null;

alter table public.users
  add column if not exists primary_role_id uuid null;

alter table public.users
  add column if not exists preferred_locale text null;

alter table public.users
  add column if not exists avatar_url text null;

-- Forward FK to roles. Done after the roles table is created; ON DELETE
-- SET NULL so deleting a role does not cascade-delete users.
alter table public.users
  drop constraint if exists users_primary_role_fk;

alter table public.users
  add constraint users_primary_role_fk
  foreign key (primary_role_id) references public.roles(role_id)
  on delete set null;

-- Tenant-leading user lookup index.
create index if not exists users_operator_status_idx
  on public.users (operator_id, status)
  where deleted_at is null;

-- ─── Extend public.operator_admins ───────────────────────────────────
--
-- scope_type is added nullable first, then backfilled, then made NOT
-- NULL so existing rows do not violate the NOT NULL on first apply.

alter table public.operator_admins
  add column if not exists scope_type text;

update public.operator_admins
   set scope_type = case
     when is_super_admin then 'super_admin'
     else 'operator_owner'
   end
 where scope_type is null;

alter table public.operator_admins
  alter column scope_type set not null;

alter table public.operator_admins
  drop constraint if exists operator_admins_scope_type_check;

alter table public.operator_admins
  add constraint operator_admins_scope_type_check
  check (scope_type in (
    'super_admin',
    'ff_support',
    'operator_owner',
    'operator_manager'
  ));

alter table public.operator_admins
  add column if not exists scope_location_id uuid null;

alter table public.operator_admins
  drop constraint if exists operator_admins_scope_location_fk;

-- Composite FK forbids cross-tenant scope_location_id (an admin scoped
-- to a location must scope to a location owned by the operator they
-- admin).
alter table public.operator_admins
  add constraint operator_admins_scope_location_fk
  foreign key (operator_id, scope_location_id)
  references public.locations(operator_id, location_id)
  on delete cascade;

alter table public.operator_admins
  add column if not exists valid_from timestamptz not null default now();

alter table public.operator_admins
  add column if not exists valid_until timestamptz null;

-- ─── updated_at triggers on new tables ───────────────────────────────

drop trigger if exists permission_keys_set_updated_at on public.permission_keys;
create trigger permission_keys_set_updated_at
before update on public.permission_keys
for each row execute function public.auth_set_updated_at();

drop trigger if exists roles_set_updated_at on public.roles;
create trigger roles_set_updated_at
before update on public.roles
for each row execute function public.auth_set_updated_at();

drop trigger if exists role_permissions_set_updated_at on public.role_permissions;
create trigger role_permissions_set_updated_at
before update on public.role_permissions
for each row execute function public.auth_set_updated_at();

drop trigger if exists user_roles_set_updated_at on public.user_roles;
create trigger user_roles_set_updated_at
before update on public.user_roles
for each row execute function public.auth_set_updated_at();

drop trigger if exists mfa_factors_set_updated_at on public.mfa_factors;
create trigger mfa_factors_set_updated_at
before update on public.mfa_factors
for each row execute function public.auth_set_updated_at();

drop trigger if exists auth_invites_set_updated_at on public.auth_invites;
create trigger auth_invites_set_updated_at
before update on public.auth_invites
for each row execute function public.auth_set_updated_at();

drop trigger if exists external_identity_links_set_updated_at
  on public.external_identity_links;
create trigger external_identity_links_set_updated_at
before update on public.external_identity_links
for each row execute function public.auth_set_updated_at();

-- ─── RLS scaffolding (service-role-only policy stubs) ────────────────
--
-- Phase 9.2 flips these to per-tenant policies using
-- `current_setting('app.operator_id', true)::uuid`. Until then, only
-- the proxy's service-role connection touches these tables.

alter table public.permission_keys enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles enable row level security;
alter table public.auth_sessions enable row level security;
alter table public.mfa_factors enable row level security;
alter table public.tncs_acceptances enable row level security;
alter table public.password_history enable row level security;
alter table public.auth_invites enable row level security;
alter table public.auth_events_audit enable row level security;
alter table public.role_audit_log enable row level security;
alter table public.external_identity_links enable row level security;

create policy "permission_keys_service_role_all"
  on public.permission_keys for all to service_role
  using (true) with check (true);

create policy "roles_service_role_all"
  on public.roles for all to service_role
  using (true) with check (true);

create policy "role_permissions_service_role_all"
  on public.role_permissions for all to service_role
  using (true) with check (true);

create policy "user_roles_service_role_all"
  on public.user_roles for all to service_role
  using (true) with check (true);

create policy "auth_sessions_service_role_all"
  on public.auth_sessions for all to service_role
  using (true) with check (true);

create policy "mfa_factors_service_role_all"
  on public.mfa_factors for all to service_role
  using (true) with check (true);

create policy "tncs_acceptances_service_role_all"
  on public.tncs_acceptances for all to service_role
  using (true) with check (true);

create policy "password_history_service_role_all"
  on public.password_history for all to service_role
  using (true) with check (true);

create policy "auth_invites_service_role_all"
  on public.auth_invites for all to service_role
  using (true) with check (true);

-- Audit tables get a SELECT/INSERT-only policy stub. The grant shape
-- below is the canonical defense; the policy stub is a belt-and-braces
-- consistency layer with the rest of the auth surface.
create policy "auth_events_audit_service_role_append_only"
  on public.auth_events_audit for insert to service_role
  with check (true);

create policy "auth_events_audit_service_role_select"
  on public.auth_events_audit for select to service_role
  using (true);

create policy "role_audit_log_service_role_append_only"
  on public.role_audit_log for insert to service_role
  with check (true);

create policy "role_audit_log_service_role_select"
  on public.role_audit_log for select to service_role
  using (true);

create policy "external_identity_links_service_role_all"
  on public.external_identity_links for all to service_role
  using (true) with check (true);

-- ─── Append-only grants on audit tables ──────────────────────────────
--
-- The grant shape is the canonical append-only enforcement. RLS
-- policies are belt-and-braces. `service_role` is the proxy's only
-- connection role; PUBLIC stays revoked everywhere.

revoke update, delete on public.auth_events_audit from public;
revoke update, delete on public.auth_events_audit from service_role;
grant insert, select on public.auth_events_audit to service_role;

revoke update, delete on public.role_audit_log from public;
revoke update, delete on public.role_audit_log from service_role;
grant insert, select on public.role_audit_log to service_role;

-- ─── Seed permission_keys catalog (frozen) ───────────────────────────
--
-- Mirrors `lib/auth/permission_keys.dart` and
-- `docs/contracts/auth_permission_key_catalog.md`. Adding a key
-- requires updating all three sources together.

insert into public.permission_keys (key, category, description, requires_mfa, frozen)
values
  -- product.* (2)
  ('product.forgeflow.access', 'product',
   'Access to Forge & Flow surfaces in either product shell.', false, true),
  ('product.barrio.access', 'product',
   'Access to Barrio surfaces in the Barrio product shell.', false, true),

  -- forgeflow.* (20)
  ('forgeflow.shift.view', 'forgeflow', 'View shift surface.', false, true),
  ('forgeflow.shift.edit', 'forgeflow', 'Edit shift assignments.', false, true),
  ('forgeflow.variance.view', 'forgeflow', 'View variance surface.', false, true),
  ('forgeflow.variance.edit', 'forgeflow',
   'Edit variance reasons and notes.', false, true),
  ('forgeflow.schedule.view', 'forgeflow', 'View schedule surface.', false, true),
  ('forgeflow.schedule.edit', 'forgeflow',
   'Edit upcoming schedule assignments.', false, true),
  ('forgeflow.baseline.view', 'forgeflow', 'View baseline benchmark.', false, true),
  ('forgeflow.baseline.override', 'forgeflow',
   'Override baseline values for a service period.', false, true),
  ('forgeflow.history.view', 'forgeflow',
   'View historical service-period results.', false, true),
  ('forgeflow.benchmark.view', 'forgeflow',
   'View 60-day benchmark snapshot.', false, true),
  ('forgeflow.benchmark.edit', 'forgeflow',
   'Edit 60-day benchmark snapshot inputs.', false, true),
  ('forgeflow.target_profile.view', 'forgeflow',
   'View active target profile.', false, true),
  ('forgeflow.target_profile.manage', 'forgeflow',
   'Manage target-profile parameters.', false, true),
  ('forgeflow.target_cycle.view', 'forgeflow', 'View target cycle.', false, true),
  ('forgeflow.target_cycle.unlock', 'forgeflow',
   'Unlock the active target cycle for early replacement.', false, true),
  ('forgeflow.target_cycle.replace', 'forgeflow',
   'Replace the active target cycle.', false, true),
  ('forgeflow.weekly_plan.view', 'forgeflow',
   'View locked weekly plan snapshot.', false, true),
  ('forgeflow.weekly_plan.lock', 'forgeflow',
   'Lock the in-force weekly plan snapshot.', false, true),
  ('forgeflow.settings.view', 'forgeflow',
   'View Forge & Flow settings.', false, true),
  ('forgeflow.settings.manage', 'forgeflow',
   'Manage Forge & Flow settings.', false, true),

  -- barrio.* (12)
  ('barrio.handbook.view', 'barrio', 'View Barrio handbook.', false, true),
  ('barrio.interview_playbook.view', 'barrio',
   'View interview playbook.', false, true),
  ('barrio.jim_taylor.view', 'barrio', 'View Jim Taylor course.', false, true),
  ('barrio.preston_lee.view', 'barrio', 'View Preston Lee course.', false, true),
  ('barrio.supervisor_content.view', 'barrio',
   'View supervisor learning content.', false, true),
  ('barrio.el_podio.view', 'barrio',
   'View El Podio leaderboard surfaces.', false, true),
  ('barrio.handbook.edit', 'barrio',
   'Edit Barrio handbook content (operator owner / F&F only).', false, true),
  ('barrio.interview_playbook.edit', 'barrio',
   'Edit interview-playbook content.', false, true),
  ('barrio.preston_lee.edit', 'barrio',
   'Edit Preston Lee course content.', false, true),
  ('barrio.supervisor_content.edit', 'barrio',
   'Edit supervisor learning content.', false, true),
  ('barrio.learning.complete_unit', 'barrio',
   'Mark a learning unit complete for the current user.', false, true),
  ('barrio.streak.view', 'barrio',
   'View own streak / leaderboard standing.', false, true),

  -- admin.* (26)
  ('admin.users.view', 'admin', 'View users in admin console.', false, true),
  ('admin.users.create', 'admin',
   'Create users programmatically (rare path).', false, true),
  ('admin.users.deactivate', 'admin',
   'Suspend a user account.', false, true),
  ('admin.users.reactivate', 'admin',
   'Reactivate a suspended user account.', false, true),
  ('admin.users.soft_delete', 'admin',
   'Soft-delete a user (status -> deleted; data retained).', false, true),
  ('admin.users.erase_pii', 'admin',
   'GDPR right-to-erasure: redact PII for a user. Paired-approval + MFA required.',
   true, true),
  ('admin.users.reset_password', 'admin',
   'Trigger admin-initiated password reset for a user.', false, true),
  ('admin.invites.create', 'admin', 'Create user invites.', false, true),
  ('admin.invites.revoke', 'admin', 'Revoke pending user invites.', false, true),
  ('admin.roles.view', 'admin', 'View roles in admin console.', false, true),
  ('admin.roles.edit_seeded', 'admin',
   'Edit permissions on seeded roles (super_admin only). MFA required.',
   true, true),
  ('admin.roles.create_custom', 'admin',
   'Create custom operator-scoped roles.', false, true),
  ('admin.roles.delete_custom', 'admin',
   'Delete custom operator-scoped roles (after revoking grants).', false, true),
  ('admin.roles.assign', 'admin', 'Grant a role to a user.', false, true),
  ('admin.roles.revoke', 'admin', 'Revoke a role from a user.', false, true),
  ('admin.audit_log.view', 'admin',
   'View auth event audit log.', false, true),
  ('admin.audit_log.export', 'admin',
   'Export audit log to CSV.', false, true),
  ('admin.target_cycle.unlock', 'admin',
   'Admin-side override of target-cycle lock.', false, true),
  ('admin.pricing_tier.view', 'admin',
   'View operator pricing tier.', false, true),
  ('admin.pricing_tier.edit', 'admin',
   'Edit operator pricing tier (F&F super_admin only). MFA required.',
   true, true),
  ('admin.feature_flag.view', 'admin', 'View feature flags.', false, true),
  ('admin.feature_flag.toggle', 'admin', 'Toggle feature flag value.', false, true),
  ('admin.status_page.publish', 'admin',
   'Publish a status-page incident or recovery.', false, true),
  ('admin.debug_console.view', 'admin',
   'View internal debug console.', false, true),
  ('admin.session.force_logout', 'admin',
   'Force-revoke all sessions for a user.', false, true),
  ('admin.service_principal.issue_token', 'admin',
   'Issue short-lived service-principal JWTs for automation identities. MFA required.',
   true, true),

  -- billing.* (5)
  ('billing.invoice.view', 'billing', 'View operator invoices.', false, true),
  ('billing.subscription.manage', 'billing',
   'Manage subscription tier + payment terms. MFA required.', true, true),
  ('billing.payment_method.manage', 'billing',
   'Add or remove operator payment methods. MFA required.', true, true),
  ('billing.usage.view', 'billing',
   'View per-class usage and cost rollups.', false, true),
  ('billing.usage_caps.edit', 'billing',
   'Edit per-class monthly cap. MFA required.', true, true),

  -- integration.* (9)
  ('integration.toast.connect', 'integration',
   'Connect or rotate Toast POS credentials.', false, true),
  ('integration.toast.view', 'integration',
   'View Toast integration status.', false, true),
  ('integration.7shifts.connect', 'integration',
   'Connect or rotate 7shifts labor credentials.', false, true),
  ('integration.7shifts.view', 'integration',
   'View 7shifts integration status.', false, true),
  ('integration.opentable.connect', 'integration',
   'Connect or rotate OpenTable reservation credentials.', false, true),
  ('integration.opentable.view', 'integration',
   'View OpenTable integration status.', false, true),
  ('integration.qbo.connect', 'integration',
   'Connect or rotate QuickBooks Online credentials.', false, true),
  ('integration.xero.connect', 'integration',
   'Connect or rotate Xero credentials.', false, true),
  ('integration.key_rotate', 'integration',
   'Rotate any integration secret. MFA required.', true, true),

  -- workflow.* (8) - placeholder, fully populated by Phase 12
  ('workflow.catalog.view', 'workflow',
   'View Phase 12 workflow catalog.', false, true),
  ('workflow.run', 'workflow', 'Run a Phase 12 workflow.', false, true),
  ('workflow.approve', 'workflow',
   'Approve a Phase 12 workflow approval gate.', false, true),
  ('workflow.reject', 'workflow',
   'Reject a Phase 12 workflow approval gate.', false, true),
  ('workflow.create', 'workflow', 'Create a Phase 12 workflow.', false, true),
  ('workflow.delete', 'workflow', 'Delete a Phase 12 workflow.', false, true),
  ('workflow.history.view', 'workflow',
   'View Phase 12 workflow run history.', false, true),
  ('workflow.tool.invoke', 'workflow',
   'Invoke a Phase 12 workflow tool directly.', false, true)
on conflict (key) do nothing;

-- ─── Seed six baseline roles (global, is_seeded = true) ──────────────

insert into public.roles (
  role_id, operator_id, role_key, display_name, description,
  is_seeded, is_editable, created_at, updated_at
)
values
  (
    '00000000-0000-0000-0000-000000000001'::uuid, null, 'super_admin',
    'F&F Super Admin',
    'F&F company super-admin. Full access across operators. BYPASSRLS via forge_admin Postgres role.',
    true, false, now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000002'::uuid, null, 'ff_support',
    'F&F Support',
    'F&F support staff. Read-only access to assigned operators (scope via operator_admins.scope_location_id).',
    true, false, now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000003'::uuid, null, 'operator_owner',
    'Operator Owner',
    'Operator owner / customer. Full operator-scoped operational + admin surfaces.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000004'::uuid, null, 'operator_manager',
    'Operator Manager',
    'Manager-level operator user. Broad operational access; limited admin surfaces.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000005'::uuid, null, 'operator_supervisor',
    'Operator Supervisor',
    'Supervisor-level operator user. Selected operational + supervisor learning surfaces.',
    true, true, now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000006'::uuid, null, 'operator_staff',
    'Operator Staff',
    'Line-level staff. Barrio learning surfaces only by default.',
    true, true, now(), now()
  )
on conflict do nothing;

-- ─── Seed role_permissions for the six baseline roles ────────────────
--
-- super_admin gets every key; the others enumerate explicitly so the
-- seed is auditable. `effect = 'allow'` everywhere; deny rules are
-- introduced by operator_owner via the role console (9.6) when needed.

-- super_admin: every key in the catalog.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'super_admin' and r.operator_id is null
on conflict do nothing;

-- ff_support: read-only across products + admin views.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'ff_support' and r.operator_id is null
   and pk.key in (
     'product.forgeflow.access', 'product.barrio.access',
     'forgeflow.shift.view', 'forgeflow.variance.view',
     'forgeflow.schedule.view', 'forgeflow.baseline.view',
     'forgeflow.history.view', 'forgeflow.benchmark.view',
     'forgeflow.target_profile.view', 'forgeflow.target_cycle.view',
     'forgeflow.weekly_plan.view', 'forgeflow.settings.view',
     'barrio.handbook.view', 'barrio.interview_playbook.view',
     'barrio.jim_taylor.view', 'barrio.preston_lee.view',
     'barrio.supervisor_content.view', 'barrio.el_podio.view',
     'admin.users.view', 'admin.audit_log.view', 'admin.audit_log.export',
     'admin.debug_console.view', 'admin.feature_flag.view',
     'admin.pricing_tier.view', 'admin.roles.view',
     'billing.invoice.view', 'billing.usage.view',
     'integration.toast.view', 'integration.7shifts.view',
     'integration.opentable.view'
   )
on conflict do nothing;

-- operator_owner: full operational + operator-scoped admin + integrations.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'operator_owner' and r.operator_id is null
   and (
     pk.category in ('product', 'forgeflow', 'barrio', 'integration')
     or pk.key in (
       'admin.users.view', 'admin.users.create', 'admin.users.deactivate',
       'admin.users.reactivate', 'admin.users.reset_password',
       'admin.invites.create', 'admin.invites.revoke',
       'admin.roles.view', 'admin.roles.create_custom',
       'admin.roles.delete_custom', 'admin.roles.assign',
       'admin.roles.revoke', 'admin.audit_log.view',
       'admin.audit_log.export', 'admin.target_cycle.unlock',
       'admin.pricing_tier.view', 'admin.feature_flag.view',
       'admin.feature_flag.toggle', 'admin.session.force_logout',
       'billing.invoice.view', 'billing.usage.view',
       'billing.usage_caps.edit',
       'workflow.catalog.view', 'workflow.run', 'workflow.history.view'
     )
   )
on conflict do nothing;

-- operator_manager: broad operational + limited admin.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'operator_manager' and r.operator_id is null
   and pk.key in (
     'product.forgeflow.access', 'product.barrio.access',
     'forgeflow.shift.view', 'forgeflow.shift.edit',
     'forgeflow.variance.view', 'forgeflow.variance.edit',
     'forgeflow.schedule.view', 'forgeflow.schedule.edit',
     'forgeflow.baseline.view', 'forgeflow.baseline.override',
     'forgeflow.history.view', 'forgeflow.benchmark.view',
     'forgeflow.target_profile.view', 'forgeflow.target_profile.manage',
     'forgeflow.target_cycle.view', 'forgeflow.weekly_plan.view',
     'forgeflow.weekly_plan.lock', 'forgeflow.settings.view',
     'barrio.handbook.view', 'barrio.interview_playbook.view',
     'barrio.jim_taylor.view', 'barrio.preston_lee.view',
     'barrio.supervisor_content.view', 'barrio.supervisor_content.edit',
     'barrio.el_podio.view',
     'admin.users.view', 'admin.audit_log.view',
     'admin.session.force_logout',
     'admin.roles.view', 'admin.roles.assign', 'admin.roles.revoke',
     'billing.invoice.view', 'billing.usage.view',
     'workflow.catalog.view', 'workflow.run'
   )
on conflict do nothing;

-- operator_supervisor: read-mostly operational + supervisor content.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'operator_supervisor' and r.operator_id is null
   and pk.key in (
     'product.forgeflow.access', 'product.barrio.access',
     'forgeflow.shift.view', 'forgeflow.variance.view',
     'forgeflow.schedule.view', 'forgeflow.history.view',
     'forgeflow.weekly_plan.view',
     'barrio.handbook.view', 'barrio.interview_playbook.view',
     'barrio.jim_taylor.view', 'barrio.preston_lee.view',
     'barrio.supervisor_content.view', 'barrio.supervisor_content.edit',
     'barrio.el_podio.view',
     'barrio.learning.complete_unit', 'barrio.streak.view'
   )
on conflict do nothing;

-- operator_staff: Barrio learning surfaces only.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'operator_staff' and r.operator_id is null
   and pk.key in (
     'product.barrio.access',
     'barrio.handbook.view', 'barrio.interview_playbook.view',
     'barrio.jim_taylor.view', 'barrio.preston_lee.view',
     'barrio.el_podio.view',
     'barrio.learning.complete_unit', 'barrio.streak.view'
   )
on conflict do nothing;

-- ─── Backfill legacy users.role into user_roles, then drop column ───
--
-- The 11a.11c.1 migration created `users.role text null` as a legacy
-- single-column role. Phase 9.0 promotes role assignment to its own
-- table. For each user that still carries a non-null `role` matching
-- a seeded role_key, insert a self-granted user_roles row, then drop
-- the legacy column. The DO block guards against re-runs after the
-- column has already been dropped.

do $$
begin
  if exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name = 'users'
       and column_name = 'role'
  ) then
    execute $sql$
      insert into public.user_roles (
        user_role_id, user_id, role_id, operator_id, location_id,
        valid_from, granted_by, created_at, updated_at
      )
      select gen_random_uuid(),
             u.user_id,
             r.role_id,
             u.operator_id,
             null,
             now(),
             u.user_id,
             now(),
             now()
        from public.users u
        join public.roles r
          on r.role_key = u.role
         and r.operator_id is null
       where u.role is not null
      on conflict do nothing
    $sql$;

    execute 'alter table public.users drop column role';
  end if;
end
$$;

-- ─── Documentation comments ──────────────────────────────────────────

comment on table public.permission_keys is
  '9.0 frozen permission catalog. Mirrored in lib/auth/permission_keys.dart and docs/contracts/auth_permission_key_catalog.md. Operators may not invent new keys at runtime.';
comment on table public.roles is
  '9.0 RBAC roles. operator_id IS NULL = global / F&F-defined seeded role. Non-null = operator-scoped custom role created via 9.6 admin endpoints.';
comment on table public.role_permissions is
  '9.0 RBAC bundle definition. effect = ''deny'' wins over ''allow'' in 9.6 resolution algorithm.';
comment on table public.user_roles is
  '9.0 RBAC grant. Time-bound (valid_from / valid_until); revoked grants retained for audit. Active uniqueness enforced by user_roles_active_grant_idx.';
comment on table public.auth_sessions is
  '9.0 session ledger. Phase 9.3 INSERTs on login, UPDATEs last_seen_at on token refresh, SETs revoked_at on logout-all-sessions.';
comment on table public.mfa_factors is
  '9.0 MFA factor inventory. SMS deliberately absent (NIST SP 800-63B-4 deprecated as a primary AAL2 factor).';
comment on table public.tncs_acceptances is
  '9.0 T&Cs acceptance log. Append-only by convention; legal text + acceptance flow integration lands in 9.8.';
comment on table public.password_history is
  '9.0 password reuse-detection log. Last 5 hashes per user; pruned by 9.5; cleared on GDPR erasure (9.8).';
comment on table public.auth_invites is
  '9.0 invite-with-expiry. invite_token_hash matched on /v1/admin/auth/invites/accept (9.8). Open-invite uniqueness on (operator, email).';
comment on table public.auth_events_audit is
  '9.0 append-only audit log. UPDATE / DELETE revoked from PUBLIC and service_role; service_role has INSERT and SELECT only. GDPR redaction lives in 9.8 and uses jsonb_set on event_payload while preserving event_id, actor_user_id, event_type, occurred_at (Art. 17(3) operational record carve-out).';
comment on table public.role_audit_log is
  '9.0 append-only role/permission diff history. Same grant shape as auth_events_audit.';
comment on table public.external_identity_links is
  '9.0 Phase 8 vendor-employee bridge. NOT the auth source-of-truth. Vendor APIs do not become identity authority; this table maps app users to vendor employee records for downstream attribution.';

comment on column public.users.firebase_uid is
  '9.0 Firebase Identity Platform uid. Defaulted to gen_random_uuid()::text at column-add time; Phase 9.1 overwrites with the real Firebase uid when users link in. Stored as text because Firebase Identity Platform accepts arbitrary string uids.';
comment on column public.users.external_id is
  '9.0 SSO/SAML/SCIM external identifier (future, 9-future-1). Distinct from external_identity_links which is the Phase 8 vendor-employee bridge.';
comment on column public.users.status is
  '9.0 user lifecycle state. invited / active / suspended / dormant_30 / dormant_60 / dormant_90 / deleted. Operator dormancy state machine writes here in later phases.';
comment on column public.users.roles_version is
  '9.0 cache invalidation key. Bumped on every role change so JWT custom claim cache and permission cache (9.7) drop the stale entry.';
comment on column public.users.primary_role_id is
  '9.0 denormalized highest-precedence active role for compact UI rendering. Updated by trigger on user_roles change (trigger ships in 9.6).';

comment on column public.operator_admins.scope_type is
  '9.0 admin-grant kind. super_admin / ff_support / operator_owner / operator_manager. ff_support is the only kind that uses scope_location_id for per-operator + per-location read scope.';
comment on column public.operator_admins.scope_location_id is
  '9.0 ff_support per-operator + per-location read-scope filter. Composite FK forbids cross-tenant scopes.';
