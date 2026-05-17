-- Per-Daypart Targets V1 — Slice R7d (2026-05-17)
--
-- FINAL covers-source step. SCHEMA-DESTRUCTIVE (hard column drop).
--
-- This migration does exactly two things, atomically, and nothing
-- else:
--
--   1. Redefines `public.effective_data_accuracy_settings_v` to REMOVE
--      its three legacy scalar outputs (`covers_source_lunch` /
--      `covers_source_dinner` / `covers_source_late_night`), keeping
--      the R7a `covers_source_per_service_period jsonb` output and
--      every other existing output unchanged (same HP #11 precedence,
--      same RLS posture, same grants).
--
--   2. DROPS the three legacy scalar covers columns:
--        * public.data_accuracy_settings.covers_source_lunch
--        * public.data_accuracy_settings.covers_source_dinner
--        * public.data_accuracy_settings.covers_source_late_night
--        * public.data_accuracy_scoped_overrides.covers_source_lunch
--        * public.data_accuracy_scoped_overrides.covers_source_dinner
--        * public.data_accuracy_scoped_overrides.covers_source_late_night
--      with `drop column if exists` (idempotent), inside the SAME
--      transaction as the view redefinition so the view no longer
--      depends on these columns before Postgres processes the drop
--      (no CASCADE, the view is never dropped).
--
-- ── Why this is safe NOW (deferred-drop-now-executed) ─────────────
--
-- Slice R5 (202605170000) keyed-backfilled every legacy per-location
-- covers value into the keyed table
-- `public.data_accuracy_service_period_settings` and DEPRECATED (did
-- not drop) the legacy scalar columns. Slice R7a (202605170100) added
-- the `covers_source_per_service_period jsonb` replacement column to
-- `public.data_accuracy_scoped_overrides` and the matching jsonb
-- output on the effective view, resolved with the SAME HP #11
-- most-specific-scope-wins precedence. Slice R7b moved the advisor
-- proxy off legacy-column SQL onto the keyed table / view jsonb (the
-- proxy still emits the three legacy JSON wire keys, but sourced from
-- keyed data — that wire shape is unaffected by this column drop).
-- Slice R7c removed the dead legacy-column Dart. A repo-wide pre-drop
-- safety gate (see the R7d PR body) confirmed ZERO remaining SQL
-- reads/writes of these columns and ZERO readers of the view's three
-- legacy scalar outputs anywhere in lib/**, tool/**, db/migrations/**,
-- or test/** (the only same-named symbols remaining are JSON
-- request/response wire keys sourced from keyed data, which this drop
-- does not touch). With zero readers, the hard drop is safe.
--
-- ── No down migration (intentional) ──────────────────────────────
--
-- This is the final destructive step of the covers-source migration;
-- it is not reversible. The legacy scalar columns and view outputs
-- are fully superseded by the keyed table + the R7a
-- `covers_source_per_service_period` jsonb path. A rollback would
-- require re-deriving the dropped scalars from the keyed data, which
-- the application no longer reads. This follows the repo's
-- deferred-drop idiom (202605161500 / 202605170000 deprecate-not-drop,
-- then a later scoped slice executes the hard drop).
--
-- ── Production safety ────────────────────────────────────────────
--
-- All prior covers-source migrations (R5 202605170000, R7a
-- 202605170100) are Production1-pending (not yet applied to any live
-- environment per the migration apply audit), so there is no live
-- data in these columns to lose. On a fresh staging/Production1 apply
-- this migration runs after R5 + R7a in filename order.
--
-- ── Idempotency / atomicity ──────────────────────────────────────
--
-- `create or replace view` + `drop column if exists` (re-applying is
-- a no-op). Wrapped in BEGIN … COMMIT so the view redefinition and
-- the six column drops are one atomic unit: either the view stops
-- depending on the legacy columns and the columns are dropped, or the
-- schema is left entirely unchanged. The view MUST be redefined
-- within this transaction before the drops, otherwise Postgres blocks
-- the drop (the old view depends on the columns) — which is exactly
-- why no CASCADE is used: CASCADE would silently drop the view.
--
-- Authority:
--   * docs/contracts/data_accuracy_settings_contract.md
--     "Business timing compatibility amendment (2026-05-06)" — the
--     hardcoded covers_source_* triplet is a rejected legacy shape;
--     the V1 target is the keyed child table per service_period_key.
--   * CLAUDE.md Hard Promise #11 — hierarchy-scoped settings inherit
--     downward; the retained `covers_source_per_service_period` output
--     carries that inheritance unchanged.
--   * db/migrations/202605121200_admin_hierarchy_scoped_data_polling.sql
--     defined the scoped-overrides table + the effective view.
--   * db/migrations/202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql
--     (R5) keyed-backfilled + deprecated the legacy scalar columns.
--   * db/migrations/202605170100_per_daypart_v1_r7a_covers_source_per_period_hierarchy.sql
--     (R7a) added the jsonb replacement column + view output, byte-for-byte
--     the basis for the redefined view below (this migration only removes
--     the three legacy scalar SELECT outputs from R7a's view body; every
--     other output, join, and the HP #11 ltree lateral are reproduced
--     exactly as R7a defined them).
--   * docs/contracts/phase_7_55_time_boundary_contract.md
--     (no temporal columns added or altered — drop-only + view replace).
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--     (per-tenant RLS preserved; no policy/index change; the dropped
--     columns are non-indexed scalar columns).

begin;

-- ── 1. Redefine the effective view WITHOUT the legacy scalar outputs ─
--
-- Reproduced byte-for-byte from
-- 202605170100_per_daypart_v1_r7a_covers_source_per_period_hierarchy.sql
-- with ONLY the three legacy scalar output columns
-- (`covers_source_lunch` / `covers_source_dinner` /
-- `covers_source_late_night`, and their location → org → business →
-- legacy → 'vendor' coalesce chains) removed. Every other output
-- column, every join, the HP #11 org-unit ltree lateral
-- (`loc.org_unit_path <@ ou.path`, deepest ancestor wins), the keyed
-- DISTINCT ON … at-or-before projection, and the grants are
-- UNCHANGED. The view must be redefined here, before the column drop
-- below and within the same transaction, so it no longer depends on
-- the legacy columns when Postgres processes the drop.

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
  -- R7d: the three legacy scalar covers_source_* outputs are removed.
  -- Per-service-period covers source (R7a) is the sole covers output,
  -- resolved with most-specific-scope-wins precedence. Merge least →
  -- most specific so the most specific configured scope wins per
  -- service_period_key (`a || b` keeps b on key collision):
  --   keyed legacy effective rows (lowest precedence, default-filled
  --   to 'vendor' so an unconfigured period still resolves like the
  --   prior scalar 'vendor' fallback)
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

-- ── 2. Drop the legacy scalar covers columns (idempotent) ────────
--
-- The view above no longer references these columns (and is redefined
-- within this same transaction), so the drop succeeds without
-- CASCADE. `drop column if exists` makes re-applying the migration a
-- no-op. The implicit CHECK constraints
-- (`covers_source_* in ('vendor','forecast','manual')`) created with
-- the original columns are removed automatically by the column drop;
-- no separate constraint statement is needed and none is added.

alter table public.data_accuracy_settings
  drop column if exists covers_source_lunch;
alter table public.data_accuracy_settings
  drop column if exists covers_source_dinner;
alter table public.data_accuracy_settings
  drop column if exists covers_source_late_night;

alter table public.data_accuracy_scoped_overrides
  drop column if exists covers_source_lunch;
alter table public.data_accuracy_scoped_overrides
  drop column if exists covers_source_dinner;
alter table public.data_accuracy_scoped_overrides
  drop column if exists covers_source_late_night;

commit;
