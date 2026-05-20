-- Brand/account scope: org-unit account overrides.
--
-- Operator decision 2026-05-20:
--   * Brand is a real hierarchy layer.
--   * Brand, Region, and District can set account contact, currency,
--     locale, and timezone for descendants.
--   * Business name and logo stay Business-only.
--   * Data Accuracy and Vendor Integrations stay location-only.
--   * Business-day rollover is owned by Business Timing, not this table.
--
-- This table stores scoped overrides for any org_units row. NULL means
-- "inherit from the nearest ancestor or Business default." Location rows keep
-- their existing location_account_overrides path.

begin;

create table if not exists public.org_unit_account_overrides (
  operator_id        uuid not null references public.operators(operator_id)
    on delete cascade,
  org_unit_id        uuid not null,
  iana_timezone      text,
  locale_code        text,
  currency_code      text,
  contact_email      text,
  contact_phone      text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by_user_id uuid references public.users(user_id),
  updated_by_user_id uuid references public.users(user_id),
  primary key (operator_id, org_unit_id),
  constraint org_unit_account_overrides_org_unit_fk
    foreign key (operator_id, org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint org_unit_account_overrides_locale_code_format_check
    check (
      locale_code is null
      or locale_code ~ '^[a-z]{2,3}(-[A-Z]{2})?$'
    ),
  constraint org_unit_account_overrides_currency_code_format_check
    check (
      currency_code is null
      or currency_code ~ '^[A-Z]{3}$'
    ),
  constraint org_unit_account_overrides_contact_email_format_check
    check (
      contact_email is null
      or (contact_email like '%@%' and length(contact_email) <= 320)
    ),
  constraint org_unit_account_overrides_contact_phone_length_check
    check (
      contact_phone is null
      or length(contact_phone) between 1 and 64
    )
);

comment on table public.org_unit_account_overrides is
  'Brand/account scope: per-(operator, org unit) account overrides for '
  'timezone, locale, currency, contact email, and contact phone. NULL '
  'columns inherit from the nearest ancestor or Business default.';

comment on column public.org_unit_account_overrides.iana_timezone is
  'IANA timezone override for this org unit and its descendants. Location '
  'overrides still win for an individual location.';

alter table public.org_unit_account_overrides enable row level security;

drop policy if exists "org_unit_account_overrides_per_tenant"
  on public.org_unit_account_overrides;
create policy "org_unit_account_overrides_per_tenant"
  on public.org_unit_account_overrides for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "org_unit_account_overrides_per_tenant"
  on public.org_unit_account_overrides is
  'Per-tenant org-unit account override policy. Uses app_current_operator() '
  'so tenant filtering follows the same wrapper posture as sibling settings '
  'tables.';

revoke all on public.org_unit_account_overrides from public;
grant select, insert, update, delete
  on public.org_unit_account_overrides to service_role;
grant select, insert, update, delete
  on public.org_unit_account_overrides to forge_admin;

create index if not exists idx_org_unit_account_overrides_operator
  on public.org_unit_account_overrides (operator_id, org_unit_id);

drop trigger if exists org_unit_account_overrides_set_updated_at
  on public.org_unit_account_overrides;
create trigger org_unit_account_overrides_set_updated_at
before update on public.org_unit_account_overrides
for each row execute function public.cloud_foundation_set_updated_at();

commit;
