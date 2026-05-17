-- Per-Daypart Targets V1 — Slice R7a (2026-05-17)
--
-- Per-service-period covers source through the HP #11 admin hierarchy.
--
-- This migration is PURELY ADDITIVE and backward compatible. It does
-- two things and nothing else:
--
--   1. Adds a nullable `covers_source_per_service_period jsonb` column
--      to `public.data_accuracy_scoped_overrides` (the HP #11
--      scoped-overrides table) so a Forge admin can set covers source
--      keyed by `service_period_key` at a business / org-unit /
--      location scope, not only via the three hardcoded
--      `covers_source_lunch` / `_dinner` / `_late_night` columns.
--
--   2. Redefines `public.effective_data_accuracy_settings_v` to ADD a
--      new output column `covers_source_per_service_period jsonb` that
--      resolves per `service_period_key` with the SAME
--      most-specific-scope-wins precedence the view uses today
--      (location scope → org-unit scope via the HP #11 ltree lateral →
--      business scope → legacy keyed
--      `public.data_accuracy_service_period_settings` effective row →
--      'vendor' default).
--
-- Authority:
--   * docs/contracts/data_accuracy_settings_contract.md
--     "Business timing compatibility amendment (2026-05-06)" — the
--     hardcoded covers_source_* triplet is a rejected legacy shape;
--     the V1 target is the keyed child table per service_period_key.
--   * CLAUDE.md Hard Promise #11 — hierarchy-scoped settings inherit
--     downward (operator → org unit → location); lower configured
--     scopes override higher scopes. This migration carries the
--     per-period covers source through that same inheritance.
--   * db/migrations/202605121200_admin_hierarchy_scoped_data_polling.sql
--     defined the scoped-overrides table + the effective view this
--     migration extends. The HP #11 org-unit ltree lateral
--     (`loc.org_unit_path <@ ou.path`, deepest ancestor wins) is
--     reproduced byte-for-byte for the new jsonb output.
--   * db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql
--     created the keyed legacy fallback table whose effective-row
--     resolution (DISTINCT ON … ORDER BY effective_at_business_date
--     DESC, at-or-before today) this migration mirrors in SQL, the
--     same projection used by
--     lib/services/data_accuracy/data_accuracy_settings_repository.dart
--     and lib/services/integration/canonical_fact_to_closed_shift_input.dart.
--   * db/migrations/202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql
--     (Slice R5) backfilled the legacy per-location covers columns into
--     the keyed table and DEPRECATED (did not drop) the legacy
--     columns. R7a does not drop or alter any legacy column either:
--     the hard drop of the scalar columns + the legacy view outputs is
--     a later scoped slice (R7d). R7b moves the proxy onto the new
--     jsonb; R7c owns the admin / app Dart. R7a is schema + view only.
--   * docs/contracts/phase_7_55_time_boundary_contract.md
--     (TIMESTAMPTZ on operator-scoped fact tables; this migration adds
--     no temporal columns — only a jsonb column).
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--     (per-tenant RLS preserved; operator-leading B-tree indexes;
--     wrapper-only policy bodies — none changed here).
--
-- ── ADDITIVE ONLY (HARD CONSTRAINT) ──────────────────────────────
--
-- No column is dropped or altered. The existing scalar columns
-- `covers_source_lunch` / `covers_source_dinner` /
-- `covers_source_late_night` on
-- `public.data_accuracy_scoped_overrides` and on
-- `public.data_accuracy_settings` are untouched. The view's three
-- existing scalar outputs (`covers_source_lunch` /
-- `covers_source_dinner` / `covers_source_late_night`) are emitted
-- byte-for-byte exactly as today, still backed by the legacy columns,
-- so every current consumer keeps working unchanged. The only change
-- to the view's output shape is one ADDED column appended after the
-- existing late-night scalar; no existing output column is removed,
-- reordered, or re-typed. The hard drop of the scalars + the legacy
-- columns + redefining the view to remove them is deferred to R7d.
--
-- ── Why a jsonb column on the scoped-overrides table ──────────────
--
-- The scoped-overrides table is keyed by (scope_type, org_unit_id,
-- location_id) — one row per admin scope, not per service period.
-- The keyed legacy table
-- `public.data_accuracy_service_period_settings` is the per-period
-- shape but is per-(operator, location) only and carries no admin
-- scope dimension. To carry per-period covers source through the
-- HP #11 hierarchy without inventing a parallel scoped+keyed table
-- (which would duplicate the hierarchy logic), the per-period map
-- rides on the existing scope row as a `{service_period_key:
-- covers_source}` jsonb. This preserves the table's existing
-- scope_type / org_unit_id / location_id hierarchy dimensions, its
-- existing per-tenant RLS policy, and its operator-leading indexes
-- unchanged.
--
-- The jsonb value contract (validated by a CHECK below):
--   * Must be a jsonb object (or null when the scope sets no
--     per-period covers source).
--   * Keys are service_period_key strings (e.g. 'lunch', 'dinner',
--     'late_night', 'breakfast', 'brunch', 'happy_hour').
--   * Each value is one of the keyed table's covers_source enum
--     values ('vendor' / 'forecast' / 'manual' /
--     'reservation_plus_walkin'), matching
--     public.data_accuracy_service_period_settings.covers_source.
--
-- ── Most-specific-scope-wins precedence (HP #11) ──────────────────
--
-- The new view output resolves per service_period_key by merging the
-- per-period maps from least to most specific, so the most specific
-- configured scope wins per key (a key set at location scope
-- overrides the same key set at org-unit scope, which overrides
-- business scope, which overrides the legacy keyed table, which
-- defaults to 'vendor'). The org-unit scope row is selected by the
-- SAME HP #11 ltree lateral the view already uses for the scalar
-- columns (`loc.org_unit_path <@ ou.path`, deepest ancestor wins) —
-- the lateral join `org_scope` is reused, not duplicated. Per-key
-- precedence is implemented with jsonb concatenation in
-- least-to-most-specific order (`a || b` keeps b's value on key
-- collision), then a default-fill for any keyed-table period the
-- scopes did not set, defaulting unset periods to 'vendor' to match
-- the scalar columns' 'vendor' fallback.
--
-- ── Idempotency ──────────────────────────────────────────────────
--
-- `add column if not exists` + `create or replace view`. The CHECK
-- constraint is added with a guarded DO block so re-applying the
-- migration does not error on an already-present constraint. Wrapped
-- in BEGIN … COMMIT so a partial failure leaves the schema
-- unchanged. No down migration: the column add is additive and the
-- view replace is forward-compatible (R7d redefines the view and
-- drops columns). This follows the repo's deferred-drop idiom
-- (202605161500 / 202605170000 deprecate-not-drop).

begin;

-- ── 1. Additive column on the HP #11 scoped-overrides table ──────
--
-- Nullable: a scope row that sets no per-period covers source leaves
-- this null and contributes nothing to the merge (legacy keyed table
-- / 'vendor' default still resolves). The existing scalar
-- covers_source_* columns on this table are left exactly as-is.

alter table public.data_accuracy_scoped_overrides
  add column if not exists covers_source_per_service_period jsonb;

comment on column
  public.data_accuracy_scoped_overrides.covers_source_per_service_period is
  'Per-Daypart V1 / Slice R7a (2026-05-17). Optional '
  '{service_period_key: covers_source} map a Forge admin sets at this '
  'business / org-unit / location scope. Keys are service_period_key '
  'strings; values match '
  'public.data_accuracy_service_period_settings.covers_source '
  '(vendor / forecast / manual / reservation_plus_walkin). Resolved '
  'per period with most-specific-scope-wins precedence by '
  'public.effective_data_accuracy_settings_v output column '
  'covers_source_per_service_period. The legacy scalar '
  'covers_source_lunch / _dinner / _late_night columns on this table '
  'are unchanged and still drive the view scalar outputs until '
  'Slice R7d.';

-- jsonb shape guard. Added via a guarded DO block so re-applying the
-- migration is a no-op rather than a duplicate-constraint error.
-- Validates: null OR a jsonb object whose every value is one of the
-- keyed table's covers_source enum values. Empty object is allowed
-- (a scope that sets the column to {} contributes nothing, same as
-- null).
do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'data_accuracy_scoped_covers_per_period_ck'
       and conrelid = 'public.data_accuracy_scoped_overrides'::regclass
  ) then
    alter table public.data_accuracy_scoped_overrides
      add constraint data_accuracy_scoped_covers_per_period_ck
      check (
        covers_source_per_service_period is null
        or (
          jsonb_typeof(covers_source_per_service_period) = 'object'
          and not exists (
            select 1
              from jsonb_each_text(covers_source_per_service_period) e
             where e.value not in (
               'vendor', 'forecast', 'manual', 'reservation_plus_walkin'
             )
          )
        )
      );
  end if;
end
$$;

-- ── 2. Redefine the effective view: ADD the per-period jsonb output ─
--
-- Every existing output column is emitted byte-for-byte exactly as in
-- 202605121200 (the three scalar covers_source_* outputs still come
-- from the legacy columns via the same coalesce chain — UNCHANGED).
-- One new output column, `covers_source_per_service_period`, is
-- APPENDED. Nothing is removed, reordered, or re-typed.
--
-- The org-unit scope row (`org_scope`) is the SAME HP #11 ltree
-- lateral the view already uses (deepest ancestor wins via
-- `loc.org_unit_path <@ ou.path`, `order by nlevel(ou.path) desc`),
-- reused for the new output — no parallel hierarchy logic.

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
  -- NEW (R7a): per-service-period covers source resolved with the
  -- same most-specific-scope-wins precedence as the scalars above.
  -- Merge least → most specific so the most specific configured scope
  -- wins per service_period_key (`a || b` keeps b on key collision):
  --   keyed legacy effective rows (lowest precedence, default-filled
  --   to 'vendor' so an unconfigured period still resolves like the
  --   scalar 'vendor' fallback)
  --   → business scope → org-unit scope (HP #11 lateral)
  --   → location scope (highest precedence).
  -- The keyed-table contribution mirrors the canonical effective-row
  -- projection used by
  -- lib/services/data_accuracy/data_accuracy_settings_repository.dart
  -- and canonical_fact_to_closed_shift_input.dart: DISTINCT ON
  -- (service_period_key) ORDER BY service_period_key,
  -- effective_at_business_date DESC, restricted to rows at-or-before
  -- today's UTC date.
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

grant select on public.effective_data_accuracy_settings_v to service_role;
grant select on public.effective_data_accuracy_settings_v to forge_admin;

commit;
