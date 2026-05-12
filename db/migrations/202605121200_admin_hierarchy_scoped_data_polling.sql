-- Admin hierarchy scoped Data Accuracy and Polling Setup.
--
-- Business Accounts is the command center: a Forge admin selects a
-- business, org unit, or location, then writes setup settings at that
-- exact scope. Existing per-location tables remain for operator self
-- service and backward compatibility. The effective views below resolve
-- location values with the most specific configured admin scope winning:
-- scoped location, nearest org-unit ancestor, business scope, legacy
-- per-location row, then defaults.

begin;

create extension if not exists ltree;

create table if not exists public.data_accuracy_scoped_overrides (
  override_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scope_type text not null
    check (scope_type in ('business', 'org_unit', 'location')),
  org_unit_id uuid null,
  location_id uuid null,
  covers_source_lunch text null
    check (
      covers_source_lunch is null
      or covers_source_lunch in ('vendor', 'forecast', 'manual')
    ),
  covers_source_dinner text null
    check (
      covers_source_dinner is null
      or covers_source_dinner in ('vendor', 'forecast', 'manual')
    ),
  covers_source_late_night text null
    check (
      covers_source_late_night is null
      or covers_source_late_night in ('vendor', 'forecast', 'manual')
    ),
  wage_source text null
    check (wage_source is null or wage_source in ('vendor', 'manual_mix')),
  walk_in_handling_mode text null
    check (
      walk_in_handling_mode is null
      or walk_in_handling_mode in (
        'reservations_only',
        'walk_ins_added_to_reservations',
        'walk_ins_tracked_separately'
      )
    ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text,
  constraint data_accuracy_scoped_scope_payload_ck
    check (
      (scope_type = 'business' and org_unit_id is null and location_id is null)
      or
      (scope_type = 'org_unit' and org_unit_id is not null and location_id is null)
      or
      (scope_type = 'location' and location_id is not null and org_unit_id is null)
    ),
  constraint data_accuracy_scoped_org_unit_fk
    foreign key (operator_id, org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint data_accuracy_scoped_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

create unique index if not exists data_accuracy_scoped_override_uq
  on public.data_accuracy_scoped_overrides (
    operator_id,
    scope_type,
    coalesce(org_unit_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

create index if not exists data_accuracy_scoped_operator_scope_idx
  on public.data_accuracy_scoped_overrides (
    operator_id,
    scope_type,
    org_unit_id,
    location_id
  );

alter table public.data_accuracy_scoped_overrides enable row level security;

drop policy if exists "data_accuracy_scoped_overrides_per_tenant"
  on public.data_accuracy_scoped_overrides;
create policy "data_accuracy_scoped_overrides_per_tenant"
  on public.data_accuracy_scoped_overrides for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

revoke all on public.data_accuracy_scoped_overrides from public;
grant select, insert, update on public.data_accuracy_scoped_overrides
  to service_role;
grant select, insert, update on public.data_accuracy_scoped_overrides
  to forge_admin;

drop trigger if exists data_accuracy_scoped_overrides_set_updated_at
  on public.data_accuracy_scoped_overrides;
create trigger data_accuracy_scoped_overrides_set_updated_at
before update on public.data_accuracy_scoped_overrides
for each row execute function public.cloud_foundation_set_updated_at();

create table if not exists public.forge_flow_polling_tier_scope_assignment (
  assignment_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scope_type text not null
    check (scope_type in ('business', 'org_unit', 'location')),
  org_unit_id uuid null,
  location_id uuid null,
  tier_key text not null
    check (tier_key in ('standard', 'premium', 'custom')),
  polling_cadence_per_vendor_seconds jsonb not null default '{}'::jsonb
    check (jsonb_typeof(polling_cadence_per_vendor_seconds) = 'object'),
  monthly_price_cents integer
    check (monthly_price_cents is null or monthly_price_cents >= 0),
  vendor_api_cost_estimate_cents_monthly integer
    check (
      vendor_api_cost_estimate_cents_monthly is null
      or vendor_api_cost_estimate_cents_monthly >= 0
    ),
  admin_notes text,
  effective_at timestamptz not null default now(),
  effective_until timestamptz,
  assigned_by_admin_user_id text,
  created_at timestamptz not null default now(),
  constraint polling_tier_scope_payload_ck
    check (
      (scope_type = 'business' and org_unit_id is null and location_id is null)
      or
      (scope_type = 'org_unit' and org_unit_id is not null and location_id is null)
      or
      (scope_type = 'location' and location_id is not null and org_unit_id is null)
    ),
  constraint polling_tier_scope_org_unit_fk
    foreign key (operator_id, org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint polling_tier_scope_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

create unique index if not exists polling_tier_scope_current_uq
  on public.forge_flow_polling_tier_scope_assignment (
    operator_id,
    scope_type,
    coalesce(org_unit_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where effective_until is null;

create index if not exists polling_tier_scope_operator_scope_idx
  on public.forge_flow_polling_tier_scope_assignment (
    operator_id,
    scope_type,
    org_unit_id,
    location_id,
    effective_at desc
  );

alter table public.forge_flow_polling_tier_scope_assignment
  enable row level security;

drop policy if exists "polling_tier_scope_assignment_per_tenant"
  on public.forge_flow_polling_tier_scope_assignment;
create policy "polling_tier_scope_assignment_per_tenant"
  on public.forge_flow_polling_tier_scope_assignment for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

revoke all on public.forge_flow_polling_tier_scope_assignment from public;
grant select, insert, update
  on public.forge_flow_polling_tier_scope_assignment to service_role;
grant select, insert, update
  on public.forge_flow_polling_tier_scope_assignment to forge_admin;

create or replace view public.effective_data_accuracy_settings_v as
select
  coalesce(
    location_scope.override_id::text,
    org_scope.override_id::text,
    business_scope.override_id::text,
    legacy.setting_id::text,
    'default:' || loc.operator_id::text || ':' || loc.location_id::text
  ) as setting_id,
  loc.operator_id,
  loc.location_id,
  coalesce(
    location_scope.covers_source_lunch,
    org_scope.covers_source_lunch,
    business_scope.covers_source_lunch,
    legacy.covers_source_lunch,
    'vendor'
  ) as covers_source_lunch,
  coalesce(
    location_scope.covers_source_dinner,
    org_scope.covers_source_dinner,
    business_scope.covers_source_dinner,
    legacy.covers_source_dinner,
    'vendor'
  ) as covers_source_dinner,
  coalesce(
    location_scope.covers_source_late_night,
    org_scope.covers_source_late_night,
    business_scope.covers_source_late_night,
    legacy.covers_source_late_night,
    'vendor'
  ) as covers_source_late_night,
  coalesce(legacy.covers_manual_entries, '{}'::jsonb) as covers_manual_entries,
  coalesce(
    location_scope.wage_source,
    org_scope.wage_source,
    business_scope.wage_source,
    legacy.wage_source,
    'vendor'
  ) as wage_source,
  coalesce(
    location_scope.walk_in_handling_mode,
    org_scope.walk_in_handling_mode,
    business_scope.walk_in_handling_mode,
    legacy.walk_in_handling_mode,
    'reservations_only'
  ) as walk_in_handling_mode,
  coalesce(legacy.walk_in_manual_entries, '{}'::jsonb) as walk_in_manual_entries,
  coalesce(
    location_scope.created_at,
    org_scope.created_at,
    business_scope.created_at,
    legacy.created_at,
    now()
  ) as created_at,
  coalesce(
    location_scope.updated_at,
    org_scope.updated_at,
    business_scope.updated_at,
    legacy.updated_at,
    now()
  ) as updated_at,
  coalesce(
    location_scope.updated_by,
    org_scope.updated_by,
    business_scope.updated_by,
    legacy.updated_by
  ) as updated_by
from public.locations loc
left join public.data_accuracy_settings legacy
  on legacy.operator_id = loc.operator_id
 and legacy.location_id = loc.location_id
left join public.data_accuracy_scoped_overrides business_scope
  on business_scope.operator_id = loc.operator_id
 and business_scope.scope_type = 'business'
left join public.data_accuracy_scoped_overrides location_scope
  on location_scope.operator_id = loc.operator_id
 and location_scope.scope_type = 'location'
 and location_scope.location_id = loc.location_id
left join lateral (
  select scoped.*
    from public.data_accuracy_scoped_overrides scoped
    join public.org_units ou
      on ou.operator_id = scoped.operator_id
     and ou.id = scoped.org_unit_id
   where scoped.operator_id = loc.operator_id
     and scoped.scope_type = 'org_unit'
     and loc.org_unit_path <@ ou.path
   order by nlevel(ou.path) desc, scoped.updated_at desc
   limit 1
) org_scope on true;

create or replace view public.effective_forge_flow_polling_tier_assignment_v as
select
  coalesce(
    location_scope.assignment_id::text,
    org_scope.assignment_id::text,
    business_scope.assignment_id::text,
    legacy.assignment_id::text,
    'default:' || loc.operator_id::text || ':' || loc.location_id::text
  ) as assignment_id,
  loc.operator_id,
  loc.location_id,
  coalesce(
    location_scope.tier_key,
    org_scope.tier_key,
    business_scope.tier_key,
    legacy.tier_key,
    'standard'
  ) as tier_key,
  coalesce(
    location_scope.polling_cadence_per_vendor_seconds,
    org_scope.polling_cadence_per_vendor_seconds,
    business_scope.polling_cadence_per_vendor_seconds,
    legacy.polling_cadence_per_vendor_seconds,
    '{}'::jsonb
  ) as polling_cadence_per_vendor_seconds,
  coalesce(
    location_scope.monthly_price_cents,
    org_scope.monthly_price_cents,
    business_scope.monthly_price_cents,
    legacy.monthly_price_cents
  ) as monthly_price_cents,
  coalesce(
    location_scope.vendor_api_cost_estimate_cents_monthly,
    org_scope.vendor_api_cost_estimate_cents_monthly,
    business_scope.vendor_api_cost_estimate_cents_monthly,
    legacy.vendor_api_cost_estimate_cents_monthly
  ) as vendor_api_cost_estimate_cents_monthly,
  coalesce(
    location_scope.effective_at,
    org_scope.effective_at,
    business_scope.effective_at,
    legacy.effective_at,
    '1970-01-01T00:00:00Z'::timestamptz
  ) as effective_at,
  null::timestamptz as effective_until,
  coalesce(
    location_scope.assigned_by_admin_user_id,
    org_scope.assigned_by_admin_user_id,
    business_scope.assigned_by_admin_user_id,
    legacy.assigned_by_admin_user_id
  ) as assigned_by_admin_user_id,
  coalesce(
    location_scope.created_at,
    org_scope.created_at,
    business_scope.created_at,
    legacy.created_at,
    '1970-01-01T00:00:00Z'::timestamptz
  ) as created_at,
  coalesce(
    location_scope.admin_notes,
    org_scope.admin_notes,
    business_scope.admin_notes
  ) as admin_notes
from public.locations loc
left join public.forge_flow_polling_tier_assignment legacy
  on legacy.operator_id = loc.operator_id
 and legacy.location_id = loc.location_id
 and legacy.effective_until is null
left join public.forge_flow_polling_tier_scope_assignment business_scope
  on business_scope.operator_id = loc.operator_id
 and business_scope.scope_type = 'business'
 and business_scope.effective_until is null
left join public.forge_flow_polling_tier_scope_assignment location_scope
  on location_scope.operator_id = loc.operator_id
 and location_scope.scope_type = 'location'
 and location_scope.location_id = loc.location_id
 and location_scope.effective_until is null
left join lateral (
  select scoped.*
    from public.forge_flow_polling_tier_scope_assignment scoped
    join public.org_units ou
      on ou.operator_id = scoped.operator_id
     and ou.id = scoped.org_unit_id
   where scoped.operator_id = loc.operator_id
     and scoped.scope_type = 'org_unit'
     and scoped.effective_until is null
     and loc.org_unit_path <@ ou.path
   order by nlevel(ou.path) desc, scoped.effective_at desc
   limit 1
) org_scope on true;

grant select on public.effective_data_accuracy_settings_v to service_role;
grant select on public.effective_data_accuracy_settings_v to forge_admin;
grant select on public.effective_forge_flow_polling_tier_assignment_v
  to service_role;
grant select on public.effective_forge_flow_polling_tier_assignment_v
  to forge_admin;

commit;
