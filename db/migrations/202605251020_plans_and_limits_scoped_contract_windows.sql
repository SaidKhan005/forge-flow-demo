-- Plans & Limits V1: scoped custom contract effective-date windows.
--
-- The first scoped-contract table version allowed only one row per hierarchy
-- target for all time. That made future-dated contracts unsafe because saving
-- a future row could replace the current active contract. This follow-up keeps
-- one non-overlapping contract window per hierarchy target instead.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

alter table public.pricing_contract_overrides
  drop constraint if exists pricing_contract_overrides_target_uq;

create index if not exists pricing_contract_overrides_target_window_idx
  on public.pricing_contract_overrides (
    operator_id,
    scope_type,
    org_unit_id,
    location_id,
    effective_from,
    effective_until
  );

create or replace function public.pricing_contract_overrides_prevent_overlap()
returns trigger
language plpgsql
as $$
begin
  if exists (
    select 1
      from public.pricing_contract_overrides existing
     where existing.operator_id = new.operator_id
       and existing.scope_type = new.scope_type
       and existing.org_unit_id is not distinct from new.org_unit_id
       and existing.location_id is not distinct from new.location_id
       and existing.id is distinct from new.id
       and daterange(
             existing.effective_from,
             coalesce(existing.effective_until, 'infinity'::date),
             '[)'
           ) && daterange(
             new.effective_from,
             coalesce(new.effective_until, 'infinity'::date),
             '[)'
           )
  ) then
    raise exception
      'overlapping pricing_contract_overrides row for scope target'
      using errcode = '23505';
  end if;
  return new;
end;
$$;

drop trigger if exists pricing_contract_overrides_prevent_overlap
  on public.pricing_contract_overrides;
create trigger pricing_contract_overrides_prevent_overlap
before insert or update on public.pricing_contract_overrides
for each row execute function public.pricing_contract_overrides_prevent_overlap();

comment on function public.pricing_contract_overrides_prevent_overlap() is
  'Prevents overlapping custom contract effective-date windows for the same '
  'operator hierarchy target.';

comment on table public.pricing_contract_overrides is
  'Plans & Limits V1 scoped custom contract overrides. Rows may be scheduled '
  'across non-overlapping effective-date windows per operator and hierarchy '
  'target. Resolver precedence is location, org_unit, business, then '
  'pricing_plan_catalog.';

commit;
