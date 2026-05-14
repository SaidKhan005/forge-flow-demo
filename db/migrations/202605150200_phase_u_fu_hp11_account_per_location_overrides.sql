-- Wave 2 U-FU-hp11-account — per-location overrides for AccountScreen's
-- three settings cards (region, business-day rollover, business identity
-- contact email + phone).
--
-- Authority anchors
-- -----------------
--   * docs/_indices/WAVE_2_LEDGER.md U-FU-hp11-account row — schema +
--     write path for the HP #11 scope notice shipped in PUNT mode by
--     PR #712 (operator decision logged 2026-05-14).
--   * db/migrations/202605070000_phase_11W_7_operator_account_fields.sql
--     — the operator-level (Business default) source for these fields.
--   * lib/operator_web/screens/account_screen.dart — UI shipped with
--     HP #11 notices but Save disabled below Business scope.
--   * docs/contracts/auth_permission_key_catalog.md — no new permission
--     key is introduced; per-location overrides reuse the existing
--     operator_owner / operator_admin role gate the rest of the
--     operator-write surface enforces.
--
-- Per-location-with-business-fallback semantics
-- ---------------------------------------------
-- The operator decision was: location-level edits override the business
-- default *for that location only*. When the override row is missing
-- (or a column is NULL inside the row), the location inherits the
-- business default from `public.operators`.
--
-- The table stores only the SCOPED FIELDS — the business display name
-- stays operator-wide (single business name doctrine) so it is NOT in
-- this table. The HP #11 carve-out is documented in account_screen.dart
-- and surfaced in the UI as a disabled field at location scope with the
-- explainer "The business name is set at the Business level."
--
-- CLAUDE.md compliance
-- --------------------
--   * RLS-ready schema from day one (HP #4 per-operator + per-location
--     isolation). RLS is the backup defence; the proxy + repository
--     are the primary defence via OperatorScopedRepository.withTenant.
--   * B-tree index leads with `operator_id` per the RLS-ready rule.
--   * Wrapper functions are the canonical
--     `STABLE LEAKPROOF PARALLEL SAFE` ones from
--     `db/migrations/202605020500_hardening_auth_rls_to_wrappers.sql`
--     (`public.app_current_operator()`).
--   * Migration is idempotent: `create table if not exists`,
--     `if not exists` on the index, `drop policy if exists` before
--     `create policy`.

begin;

create table if not exists public.location_account_overrides (
  operator_id          uuid not null references public.operators(operator_id)
    on delete cascade,
  location_id          uuid not null,
  -- Region + formatting overrides (each column NULL ⇒ inherit business
  -- default).
  iana_timezone        text,
  locale_code          text,
  currency_code        text,
  -- Business week + rollover override. NOTE: `public.locations`
  -- already carries `business_day_rollover_hour` (the legacy
  -- per-location source). U-FU-hp11-account's repository writes the
  -- override into BOTH columns so legacy readers (and the
  -- benchmark_overrides effective-value resolver) keep working. The
  -- column on this table is the canonical AccountScreen-level
  -- override surface; the legacy `locations` column remains the
  -- physical home that runtime cycle logic already reads.
  business_day_rollover_hour integer
    check (business_day_rollover_hour is null
      or business_day_rollover_hour between 0 and 23),
  -- Identity overrides at location scope. Display name is intentionally
  -- NOT here (single business name doctrine — see file header).
  contact_email        text,
  contact_phone        text,
  -- Bookkeeping.
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by_user_id   uuid references public.users(user_id),
  updated_by_user_id   uuid references public.users(user_id),
  primary key (operator_id, location_id),
  -- Cross-tenant composite FK chain — the `(operator_id, location_id)`
  -- pair must point at a location owned by the same operator. This
  -- mirrors the benchmark_overrides composite FK pattern.
  constraint location_account_overrides_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint location_account_overrides_locale_code_format_check
    check (
      locale_code is null
      or locale_code ~ '^[a-z]{2,3}(-[A-Z]{2})?$'
    ),
  constraint location_account_overrides_currency_code_format_check
    check (
      currency_code is null
      or currency_code ~ '^[A-Z]{3}$'
    ),
  constraint location_account_overrides_contact_email_format_check
    check (
      contact_email is null
      or (contact_email like '%@%' and length(contact_email) <= 320)
    ),
  constraint location_account_overrides_contact_phone_length_check
    check (
      contact_phone is null
      or length(contact_phone) between 1 and 64
    )
);

comment on table public.location_account_overrides is
  'U-FU-hp11-account: per-(operator, location) overrides for the three '
  'AccountScreen settings (region, business-day rollover, identity '
  'contact email + phone). NULL columns inherit the business default '
  'from public.operators. Business display name stays operator-wide.';

comment on column public.location_account_overrides.business_day_rollover_hour is
  'Override for the location''s rollover hour. The U-FU-hp11-account '
  'repository writes the same value into public.locations.'
  'business_day_rollover_hour so legacy readers stay coherent.';

-- RLS-ready posture. The composite PK plus the operator-leading index
-- guarantees the planner can push the predicate down for both reads
-- and writes.
alter table public.location_account_overrides enable row level security;

drop policy if exists "location_account_overrides_per_tenant"
  on public.location_account_overrides;
create policy "location_account_overrides_per_tenant"
  on public.location_account_overrides for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "location_account_overrides_per_tenant"
  on public.location_account_overrides is
  'U-FU-hp11-account per-tenant policy. Uses the app_current_operator() '
  'wrapper so the planner can push the predicate down to the operator-'
  'leading index. forge_admin BYPASSRLS handles audited cross-tenant '
  'support paths the same way it does for benchmark_overrides.';

revoke all on public.location_account_overrides from public;
grant select, insert, update, delete
  on public.location_account_overrides to service_role;
grant select, insert, update, delete
  on public.location_account_overrides to forge_admin;

-- B-tree index leading with operator_id per the RLS-ready rule. The
-- composite PK already gives `(operator_id, location_id)` access, but
-- the standalone index keeps `tool/repo_index_lint.dart` happy if a
-- future query plan needs an explicit B-tree.
create index if not exists idx_location_account_overrides_operator
  on public.location_account_overrides (operator_id, location_id);

-- updated_at trigger mirrors benchmark_overrides + locations. The
-- shared `cloud_foundation_set_updated_at` trigger function is defined
-- in 202604250005_advisor_cloud_foundation.sql.
drop trigger if exists location_account_overrides_set_updated_at
  on public.location_account_overrides;
create trigger location_account_overrides_set_updated_at
before update on public.location_account_overrides
for each row execute function public.cloud_foundation_set_updated_at();

commit;
