-- Per-Daypart Targets V1 — Slice R5 (Gap 27/36, 2026-05-17)
--
-- De-hardcode covers-source: data-preserving backfill of the legacy
-- hardcoded `covers_source_lunch` / `covers_source_dinner` /
-- `covers_source_late_night` columns on
-- `public.data_accuracy_settings` into the existing keyed
-- `public.data_accuracy_service_period_settings` table, then deprecate
-- the legacy columns.
--
-- Authority:
--   * docs/contracts/data_accuracy_settings_contract.md
--     "Business timing compatibility amendment (2026-05-06)" — the
--     hardcoded covers_source_* triplet is a rejected legacy shape;
--     the V1 target is the keyed child table per service_period_key.
--   * db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql
--     created the keyed table and stated: "A future migration will
--     drop them once every read path ... is migrated to the keyed
--     lookup." This slice migrates the model / aggregator / repository
--     / operator-web + mobile covers UIs read paths.
--   * docs/contracts/phase_7_55_time_boundary_contract.md
--     (TIMESTAMPTZ on operator-scoped fact tables; the keyed table
--     already complies — this migration adds no temporal columns).
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--     (RLS-ready; operator-leading indexes; wrapper-only policies).
--
-- ── Why this migration ───────────────────────────────────────────
--
-- The legacy columns admit exactly three hardcoded dayparts. An
-- operator running 4+ service periods (e.g. breakfast / lunch /
-- dinner / late_night) cannot set covers source per period. The keyed
-- `data_accuracy_service_period_settings` table (created 2026-05-06)
-- already admits one covers-source row per
-- (operator, location, service_period_key, effective_at_business_date)
-- and the closed-shift aggregator already resolves keyed-first. This
-- migration moves the legacy values into the keyed table so no
-- operator setting is lost when the model / UIs stop reading the
-- legacy columns.
--
-- ── Data preservation (HARD CONSTRAINT) ──────────────────────────
--
-- For every existing `data_accuracy_settings` row, three keyed rows
-- are inserted (one per legacy daypart) carrying that row's legacy
-- covers_source value, keyed by service_period_key = 'lunch' /
-- 'dinner' / 'late_night'. The effective date is the sentinel
-- 1970-01-01 so the keyed row is always "at or before" any closed
-- shift's business date — exactly reproducing the legacy column's
-- always-applies semantics (the aggregator's at-or-before lookup
-- resolves to the operator's intent on the day the shift closed).
--
-- `on conflict ... do nothing`: a keyed row the operator already
-- created for that (operator, location, service_period_key,
-- 1970-01-01) wins and is NOT clobbered by the legacy value. A
-- later, operator-set row at a more recent effective date also wins
-- via the descending at-or-before lookup. Idempotent: re-applying
-- this migration inserts nothing the second time.
--
-- Every legacy value lands as a keyed row; no covers-source data is
-- lost. The backfill copies operator_id / location_id straight from
-- the source row, so per-(operator, location) isolation and the
-- keyed table's existing per-tenant RLS policy are preserved.
--
-- ── Legacy-column deprecation, NOT hard drop (scope-conservative) ─
--
-- The legacy columns are still read/written by surfaces OUTSIDE this
-- slice's named scope: `tool/advisor_proxy/proxy_bootstrap.dart`
-- (mobile-operational sync upsert + admin override SQL), the
-- `public.effective_data_accuracy_settings_v` view (defined in
-- 202605121200_admin_hierarchy_scoped_data_polling.sql, which also
-- coalesces the HP #11 `data_accuracy_scoped_overrides` columns), the
-- sync DTO, and the admin gateway. A hard `DROP COLUMN` here would
-- silently break that view + proxy SQL and cascade into a
-- proxy-touching / view-touching / HP #11-hierarchy refactor the R5
-- prompt's bounded "CURRENT STATE TO REPLACE" list did not name
-- ("Do not broaden scope"). Following this repo's own deferred-drop
-- idiom (202605161500 deprecate-not-drop; 202605061701 "a future
-- migration will drop them once every read path is migrated"), the
-- columns are marked DEPRECATED via column comments. The hard drop is
-- a scoped follow-up once the proxy / view / admin-hierarchy read
-- paths are migrated. The R5 model / aggregator / repository / covers
-- UIs no longer read these columns; the keyed table is their sole
-- source of truth.
--
-- ── Idempotency ──────────────────────────────────────────────────
--
-- `insert ... on conflict do nothing` (conflict identity = the keyed
-- table's existing UNIQUE index). `comment on column` is naturally
-- idempotent. Wrapped in BEGIN ... COMMIT so a partial failure leaves
-- the schema unchanged.

begin;

-- ── Backfill: legacy columns → keyed rows ────────────────────────
--
-- One INSERT per legacy daypart. The `cross join lateral (values ...)`
-- form keeps the three legacy columns mapped to their service_period
-- keys in a single statement while preserving operator_id /
-- location_id from each source row. `updated_by` records the backfill
-- origin so an operator audit can tell a migration-seeded row from an
-- operator-set one.

insert into public.data_accuracy_service_period_settings (
  operator_id,
  location_id,
  service_period_key,
  covers_source,
  effective_at_business_date,
  updated_by
)
select
  das.operator_id,
  das.location_id,
  legacy.service_period_key,
  legacy.covers_source,
  date '1970-01-01' as effective_at_business_date,
  'migration:202605170000_r5_covers_source_keyed_backfill' as updated_by
from public.data_accuracy_settings das
cross join lateral (
  values
    ('lunch', das.covers_source_lunch),
    ('dinner', das.covers_source_dinner),
    ('late_night', das.covers_source_late_night)
) as legacy(service_period_key, covers_source)
where legacy.covers_source is not null
on conflict (
  operator_id,
  location_id,
  service_period_key,
  effective_at_business_date
) do nothing;

-- ── Deprecate the legacy columns (drop deferred — see header) ────

comment on column public.data_accuracy_settings.covers_source_lunch is
  'DEPRECATED 2026-05-17 by Per-Daypart V1 / Slice R5 (Gap 27/36). '
  'Per-period covers source is now keyed by service_period_key in '
  'public.data_accuracy_service_period_settings. This column was '
  'backfilled into that table (effective 1970-01-01) by migration '
  '202605170000. The R5 model / aggregator / repository / covers UIs '
  'no longer read it. Hard drop deferred to a scoped follow-up after '
  'the proxy / effective_data_accuracy_settings_v view / '
  'admin-hierarchy read paths are migrated.';

comment on column public.data_accuracy_settings.covers_source_dinner is
  'DEPRECATED 2026-05-17 by Per-Daypart V1 / Slice R5 (Gap 27/36). '
  'See covers_source_lunch comment. Backfilled into '
  'public.data_accuracy_service_period_settings (key=dinner, '
  'effective 1970-01-01) by migration 202605170000.';

comment on column public.data_accuracy_settings.covers_source_late_night is
  'DEPRECATED 2026-05-17 by Per-Daypart V1 / Slice R5 (Gap 27/36). '
  'See covers_source_lunch comment. Backfilled into '
  'public.data_accuracy_service_period_settings (key=late_night, '
  'effective 1970-01-01) by migration 202605170000.';

commit;
