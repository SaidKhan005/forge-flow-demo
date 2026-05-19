-- Per-Daypart V1 R7e data accuracy provenance.
--
-- Adds source metadata to public.effective_data_accuracy_settings_v so
-- clients can show where effective data-accuracy values came from
-- without guessing inheritance in Flutter.
--
-- Additive only:
--   * existing view columns stay in the same order and keep the same
--     expressions
--   * new source columns are appended at the end
--   * no table shape changes

begin;

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
  (
    coalesce(
      (
        select jsonb_object_agg(k.service_period_key, k.covers_source)
          from (
            select distinct on (sp.service_period_key)
                   sp.service_period_key,
                   sp.covers_source
              from public.data_accuracy_service_period_settings sp
             where sp.operator_id = loc.operator_id
               and sp.location_id = loc.location_id
               and sp.effective_at_business_date
                     <= (now() at time zone 'utc')::date
             order by sp.service_period_key,
                      sp.effective_at_business_date desc
          ) k
      ),
      '{}'::jsonb
    )
    || coalesce(business_scope.covers_source_per_service_period, '{}'::jsonb)
    || coalesce(org_scope.covers_source_per_service_period, '{}'::jsonb)
    || coalesce(location_scope.covers_source_per_service_period, '{}'::jsonb)
  ) as covers_source_per_service_period,
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
  ) as updated_by,
  (
    coalesce(
      (
        select jsonb_object_agg(
          k.service_period_key,
          jsonb_build_object(
            'scope_type', 'location',
            'scope_id', loc.location_id::text,
            'source_kind', 'service_period_setting',
            'setting_id', k.id::text
          )
        )
          from (
            select distinct on (sp.service_period_key)
                   sp.id,
                   sp.service_period_key
              from public.data_accuracy_service_period_settings sp
             where sp.operator_id = loc.operator_id
               and sp.location_id = loc.location_id
               and sp.effective_at_business_date
                     <= (now() at time zone 'utc')::date
             order by sp.service_period_key,
                      sp.effective_at_business_date desc
          ) k
      ),
      '{}'::jsonb
    )
    || coalesce(
      (
        select jsonb_object_agg(
          keys.service_period_key,
          jsonb_build_object(
            'scope_type', 'business',
            'scope_id', loc.operator_id::text,
            'source_kind', 'scoped_override',
            'override_id', business_scope.override_id::text
          )
        )
          from jsonb_object_keys(
            coalesce(
              business_scope.covers_source_per_service_period,
              '{}'::jsonb
            )
          ) as keys(service_period_key)
      ),
      '{}'::jsonb
    )
    || coalesce(
      (
        select jsonb_object_agg(
          keys.service_period_key,
          jsonb_build_object(
            'scope_type', 'org_unit',
            'scope_id', org_scope.org_unit_id::text,
            'source_kind', 'scoped_override',
            'override_id', org_scope.override_id::text
          )
        )
          from jsonb_object_keys(
            coalesce(org_scope.covers_source_per_service_period, '{}'::jsonb)
          ) as keys(service_period_key)
      ),
      '{}'::jsonb
    )
    || coalesce(
      (
        select jsonb_object_agg(
          keys.service_period_key,
          jsonb_build_object(
            'scope_type', 'location',
            'scope_id', loc.location_id::text,
            'source_kind', 'scoped_override',
            'override_id', location_scope.override_id::text
          )
        )
          from jsonb_object_keys(
            coalesce(
              location_scope.covers_source_per_service_period,
              '{}'::jsonb
            )
          ) as keys(service_period_key)
      ),
      '{}'::jsonb
    )
  ) as covers_source_per_service_period_source,
  case
    when location_scope.wage_source is not null then jsonb_build_object(
      'scope_type', 'location',
      'scope_id', loc.location_id::text,
      'source_kind', 'scoped_override',
      'override_id', location_scope.override_id::text
    )
    when org_scope.wage_source is not null then jsonb_build_object(
      'scope_type', 'org_unit',
      'scope_id', org_scope.org_unit_id::text,
      'source_kind', 'scoped_override',
      'override_id', org_scope.override_id::text
    )
    when business_scope.wage_source is not null then jsonb_build_object(
      'scope_type', 'business',
      'scope_id', loc.operator_id::text,
      'source_kind', 'scoped_override',
      'override_id', business_scope.override_id::text
    )
    when legacy.wage_source is not null then jsonb_build_object(
      'scope_type', 'location',
      'scope_id', loc.location_id::text,
      'source_kind', 'base_setting',
      'setting_id', legacy.setting_id::text
    )
    else jsonb_build_object(
      'scope_type', 'default',
      'scope_id', null,
      'source_kind', 'default'
    )
  end as wage_source_source,
  case
    when location_scope.walk_in_handling_mode is not null then
      jsonb_build_object(
        'scope_type', 'location',
        'scope_id', loc.location_id::text,
        'source_kind', 'scoped_override',
        'override_id', location_scope.override_id::text
      )
    when org_scope.walk_in_handling_mode is not null then jsonb_build_object(
      'scope_type', 'org_unit',
      'scope_id', org_scope.org_unit_id::text,
      'source_kind', 'scoped_override',
      'override_id', org_scope.override_id::text
    )
    when business_scope.walk_in_handling_mode is not null then
      jsonb_build_object(
        'scope_type', 'business',
        'scope_id', loc.operator_id::text,
        'source_kind', 'scoped_override',
        'override_id', business_scope.override_id::text
      )
    when legacy.walk_in_handling_mode is not null then jsonb_build_object(
      'scope_type', 'location',
      'scope_id', loc.location_id::text,
      'source_kind', 'base_setting',
      'setting_id', legacy.setting_id::text
    )
    else jsonb_build_object(
      'scope_type', 'default',
      'scope_id', null,
      'source_kind', 'default'
    )
  end as walk_in_handling_mode_source
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

grant select on public.effective_data_accuracy_settings_v to service_role;
grant select on public.effective_data_accuracy_settings_v to forge_admin;

commit;
