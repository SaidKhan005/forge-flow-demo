-- B10.1 - vendor_applicability location scope.
--
-- Adds a LOCATION dimension to the operator-scoped, temporal
-- allow-list public.vendor_applicability. Today a row is scoped global
-- (operator_id NULL) or per-operator (operator_id set). This migration
-- adds a nullable location_id so a row can additionally be scoped to one
-- location. Read precedence becomes: location-specific beats
-- operator-level beats global default (resolved in the repository, not
-- here).
--
-- Backward compatible: location_id defaults to NULL on every existing
-- row, which keeps today's operator-level / global behavior byte for
-- byte. location_id is always WITHIN the operator's tenant, so RLS stays
-- keyed on operator_id via app_current_operator() and is NOT weakened by
-- this change.
--
-- Idempotent: safe to re-run (add column if not exists, drop/create
-- indexes + policy if exists). Pure expand — no backfill, no SET NOT
-- NULL — so it stays a single, cheap, online migration.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── location_id column ───────────────────────────────────────────────
--
-- NULLABLE. NULL = operator-level (when operator_id is set) or global
-- (when operator_id is NULL). A non-NULL location_id narrows the row to
-- one location within the owning operator's tenant.
alter table public.vendor_applicability
  add column if not exists location_id uuid null;

comment on column public.vendor_applicability.location_id is
  'Optional location narrowing. NULL = operator-level (operator_id set) '
  'or global (operator_id NULL) row, preserving pre-location behavior. '
  'A non-NULL value scopes the row to one location within the operator '
  'tenant; read precedence is location-specific > operator-level > global.';

-- A location only exists inside an operator tenant, so a location-scoped
-- row must carry an operator_id. Global defaults (operator_id NULL) keep
-- location_id NULL. This also keeps the global uniqueness/lookup indexes
-- below correct without a location term.
alter table public.vendor_applicability
  drop constraint if exists vendor_applicability_location_requires_operator_ck;
alter table public.vendor_applicability
  add constraint vendor_applicability_location_requires_operator_ck
  check (location_id is null or operator_id is not null);

-- Composite FK rejects (operator_a, location_b) mismatches. NULL
-- location_id passes (no FK applied) so operator-level / global rows do
-- not need a location. Guarded so the migration is a no-op if the
-- locations table is absent in a given environment.
alter table public.vendor_applicability
  drop constraint if exists vendor_applicability_location_fk;
do $$
begin
  if exists (
    select 1
      from information_schema.tables
     where table_schema = 'public'
       and table_name = 'locations'
  ) then
    execute $sql$
      alter table public.vendor_applicability
        add constraint vendor_applicability_location_fk
        foreign key (operator_id, location_id)
        references public.locations(operator_id, location_id)
        on delete cascade
    $sql$;
  end if;
end;
$$;

-- ─── history uniqueness (operator scope) ──────────────────────────────
--
-- History uniqueness must now distinguish two rows that differ only by
-- location_id at the same effective_from (an operator-level row plus a
-- location-specific row). coalesce(location_id, zero-uuid) keeps NULL
-- distinct from any real location. operator_id still LEADS so per-tenant
-- B-trees stay cheap. The global history index is unchanged: global rows
-- keep location_id NULL via the CHECK above.
drop index if exists vendor_applicability_history_operator_uq;
create unique index if not exists vendor_applicability_history_operator_uq
  on public.vendor_applicability (
    operator_id,
    coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
    setting_kind,
    setting_key,
    vendor_slug,
    effective_from
  )
  where operator_id is not null;

-- ─── current-row uniqueness (operator scope) ──────────────────────────
--
-- At most one currently-effective row per (operator, location, kind,
-- key, vendor). Adding the location term lets an operator-level row
-- (location_id NULL) and a location-specific row coexist as current.
drop index if exists vendor_applicability_current_operator_uq;
create unique index if not exists vendor_applicability_current_operator_uq
  on public.vendor_applicability (
    operator_id,
    coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
    setting_kind,
    setting_key,
    vendor_slug
  )
  where operator_id is not null and effective_until is null;

-- ─── current-row lookup index (operator_id-leading) ───────────────────
--
-- Tenant lookup index for the precedence read. operator_id LEADS per the
-- RLS-Ready Schema rule; location_id follows so the 3-way precedence
-- ranking (location-match, operator-level, global) can resolve from the
-- index. effective_from desc supports the tie-break. This replaces the
-- prior tenant lookup index, which omitted location_id.
drop index if exists vendor_applicability_current_tenant_lookup_idx;
create index if not exists vendor_applicability_current_tenant_lookup_idx
  on public.vendor_applicability (
    operator_id,
    location_id,
    setting_kind,
    setting_key,
    vendor_slug,
    effective_from desc
  )
  where effective_until is null;

-- ─── history lookup index (operator_id-leading) ───────────────────────
--
-- Extend the history lookup index with location_id (after operator_id)
-- so temporal scans for a specific location scope stay index-served.
drop index if exists vendor_applicability_history_lookup_idx;
create index if not exists vendor_applicability_history_lookup_idx
  on public.vendor_applicability (
    operator_id,
    location_id,
    setting_kind,
    setting_key,
    vendor_slug,
    effective_from desc
  );

-- ─── RLS policy ───────────────────────────────────────────────────────
--
-- Re-assert the SELECT policy unchanged in substance: tenant rows are
-- visible only through app_current_operator(); global (operator_id NULL)
-- rows remain readable. location_id lives inside the operator tenant, so
-- operator isolation is unchanged — no location term is added to the
-- policy and isolation is NOT weakened.
drop policy if exists "vendor_applicability_per_tenant_select"
  on public.vendor_applicability;
drop policy if exists "vendor_applicability_service_role_select"
  on public.vendor_applicability;
create policy "vendor_applicability_service_role_select"
  on public.vendor_applicability for select to service_role
  using (
    operator_id is null
    or operator_id = public.app_current_operator()
  );

commit;
