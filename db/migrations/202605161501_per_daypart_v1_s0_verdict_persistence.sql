-- Per-Daypart Targets V1 — Slice S0 (foundation, 2026-05-16)
--
-- Per-period verdict + reason persistence.
--
-- A later per_daypart_v1 slice replaces the benchmark-selection
-- algorithm so each service period (lunch / dinner / late_night) gets
-- its own quality VERDICT, and the Benchmark card / DAYPART BREAKDOWN
-- renders a per-period badge. Per-period TARGET persistence already
-- exists (Slice 1, migration
-- `202605160000_per_daypart_v1_per_period_target_persistence.sql`).
-- This S0 slice adds ONLY the missing per-period verdict + reason
-- persistence so the future algorithm has a column to write to.
--
-- Scope: two additive, nullable, no-default TEXT columns on the
-- existing per-period child table `public.target_cycle_dayparts`.
-- `ActiveTargetProfileDaypart` has no own table — it is projected at
-- runtime from `target_cycle_dayparts` by the service layer — so only
-- this one per-period child table needs the columns.
--
-- Back-compat: rows that pre-date S0 (and rows the future algorithm
-- leaves unscored) read back as NULL. Per Design Rule 2, NULL means
-- "unavailable"; callers never substitute 0 / empty string. No
-- algorithm, seeder, widget, or operator-facing copy changes here.
--
-- RLS posture unchanged: the table already carries
-- `(operator_id, location_id)` + the per-tenant-location policy from
-- migration 202605160000; these additive columns inherit it.

begin;

alter table public.target_cycle_dayparts
  add column if not exists verdict text,
  add column if not exists verdict_reason text;

comment on column public.target_cycle_dayparts.verdict is
  'Per-Daypart V1 S0: per-period benchmark verdict at cycle lock time '
  '(teachable | building_early | building_flat | building_few_strong | '
  'running_hot). NULL = unassigned / pre-S0 row (Design Rule 2: never '
  'substitute 0/empty). Written by the future selection-algorithm slice.';

comment on column public.target_cycle_dayparts.verdict_reason is
  'Per-Daypart V1 S0: human-readable reason backing verdict. NULL when '
  'unset. Written by the future selection-algorithm slice.';

commit;
