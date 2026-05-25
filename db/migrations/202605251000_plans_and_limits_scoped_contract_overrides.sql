-- Plans & Limits V1: scoped custom contract overrides.
--
-- Adds operator-scoped custom contract terms for the hierarchy setting
-- rule: location overrides win over org-unit overrides, org-unit overrides
-- win over business overrides, and the global pricing_plan_catalog remains
-- the fallback when no scoped override applies.
--
-- This is an operator-scoped settings table, so it follows the same RLS
-- posture as sibling scoped settings tables:
--   * operator_id-leading keys and indexes
--   * service_role tenant policy through app_current_operator()
--   * forge_admin grants for audited admin-pool mutation paths

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

create table if not exists public.pricing_contract_overrides (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scope_type text not null
    check (scope_type in ('business', 'org_unit', 'location')),
  org_unit_id uuid null,
  location_id uuid null,
  tier_key text not null references public.pricing_plan_catalog(tier_key),
  billing_owner_org_unit_id uuid null,
  monthly_usd numeric null,
  first_n_seats integer null,
  first_seat_usd numeric null,
  additional_seat_usd numeric null,
  onboarding_min_usd numeric null,
  onboarding_max_usd numeric null,
  advisor_cap_monthly_usd numeric null,
  effective_from date not null default current_date,
  effective_until date null,
  contract_label text null,
  internal_note text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text null,
  constraint pricing_contract_overrides_scope_payload_chk check (
    (
      scope_type = 'business'
      and org_unit_id is null
      and location_id is null
    )
    or (
      scope_type = 'org_unit'
      and org_unit_id is not null
      and location_id is null
    )
    or (
      scope_type = 'location'
      and org_unit_id is null
      and location_id is not null
    )
  ),
  constraint pricing_contract_overrides_org_unit_fk
    foreign key (operator_id, org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint pricing_contract_overrides_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint pricing_contract_overrides_billing_owner_fk
    foreign key (operator_id, billing_owner_org_unit_id)
    references public.org_units(operator_id, id)
    on delete restrict,
  constraint pricing_contract_overrides_target_uq
    unique nulls not distinct (
      operator_id,
      scope_type,
      org_unit_id,
      location_id
    ),
  constraint pricing_contract_overrides_effective_dates_chk check (
    effective_until is null or effective_until > effective_from
  ),
  constraint pricing_contract_overrides_seat_band_chk check (
    first_n_seats is null or first_n_seats > 0
  ),
  constraint pricing_contract_overrides_money_nonnegative_chk check (
    (monthly_usd is null or monthly_usd >= 0)
    and (first_seat_usd is null or first_seat_usd >= 0)
    and (additional_seat_usd is null or additional_seat_usd >= 0)
    and (onboarding_min_usd is null or onboarding_min_usd >= 0)
    and (onboarding_max_usd is null or onboarding_max_usd >= 0)
    and (advisor_cap_monthly_usd is null or advisor_cap_monthly_usd >= 0)
  ),
  constraint pricing_contract_overrides_onboarding_range_chk check (
    onboarding_min_usd is null
    or onboarding_max_usd is null
    or onboarding_max_usd >= onboarding_min_usd
  )
);

comment on table public.pricing_contract_overrides is
  'Plans & Limits V1 scoped custom contract overrides. One current row per '
  'operator and hierarchy target. Resolver precedence is location, org_unit, '
  'business, then pricing_plan_catalog.';

comment on column public.pricing_contract_overrides.scope_type is
  'Hierarchy target type. business rows use operator_id only, org_unit rows '
  'use org_unit_id, and location rows use location_id.';

comment on column public.pricing_contract_overrides.tier_key is
  'Effective plan key for this scoped contract. Enterprise remains the custom '
  'contract base plan key, but the CHECK lives in pricing_plan_catalog.';

comment on column public.pricing_contract_overrides.billing_owner_org_unit_id is
  'Optional org unit that owns billing for this contract override.';

comment on column public.pricing_contract_overrides.advisor_cap_monthly_usd is
  'Optional monthly advisor spend cap attached to the contract terms.';

comment on column public.pricing_contract_overrides.effective_from is
  'First date this override can be selected by the effective resolver.';

comment on column public.pricing_contract_overrides.effective_until is
  'Exclusive end date for this override. NULL means open-ended.';

comment on column public.pricing_contract_overrides.updated_by is
  'Actor identifier for the admin or service principal that last changed '
  'this override.';

alter table public.pricing_contract_overrides enable row level security;

drop policy if exists "pricing_contract_overrides_per_tenant"
  on public.pricing_contract_overrides;
create policy "pricing_contract_overrides_per_tenant"
  on public.pricing_contract_overrides for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "pricing_contract_overrides_per_tenant"
  on public.pricing_contract_overrides is
  'Tenant policy for scoped pricing contracts. Uses app_current_operator() '
  'so tenant filtering follows the same wrapper posture as sibling scoped '
  'settings tables. forge_admin BYPASSRLS handles audited admin paths.';

revoke all on public.pricing_contract_overrides from public;
grant select, insert, update, delete
  on public.pricing_contract_overrides to service_role;
grant select, insert, update, delete
  on public.pricing_contract_overrides to forge_admin;

create index if not exists pricing_contract_overrides_operator_location_idx
  on public.pricing_contract_overrides (operator_id, location_id)
  where scope_type = 'location';

create index if not exists pricing_contract_overrides_operator_org_unit_idx
  on public.pricing_contract_overrides (operator_id, org_unit_id)
  where scope_type = 'org_unit';

drop trigger if exists pricing_contract_overrides_set_updated_at
  on public.pricing_contract_overrides;
create trigger pricing_contract_overrides_set_updated_at
before update on public.pricing_contract_overrides
for each row execute function public.cloud_foundation_set_updated_at();

commit;
