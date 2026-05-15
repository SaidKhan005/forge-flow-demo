-- Per-Daypart Targets V1 — Slice 7b option (b) (2026-05-15)
--
-- Document the deprecation of `public.locations.business_day_rollover_hour`.
--
-- Operator decision (2026-05-15, locked) per
-- `docs/_audits/per_daypart_v1/slice_7b_research_2026_05_15.md`:
-- vendor sinks resolve `business_date` via the canonical
-- `BusinessTimingProfilesRepository.listCandidateProfilesForLocation`
-- → `BusinessTimingProfileResolver.resolve` → `BusinessDateResolver.resolve`
-- chain. That chain consumes `business_timing_profiles.business_day_start_local_time`
-- (TIME, HH:MM, sub-hour aware) and honors the operator → org_unit →
-- location inheritance per Hard Promise #11. The legacy
-- `locations.business_day_rollover_hour` (INTEGER 0..23) truncates
-- sub-hour cutoffs and bypasses inheritance — the source of Gaps 46
-- and 47 in the per-daypart V1 end-to-end verification.
--
-- Sub-decisions (locked, do not revisit):
--   * Sub-option (b1): the SQL trigger
--     `db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147`
--     stays as a defense-in-depth backup — NOT rewritten in 7b.
--   * Fallback hour `4` across all sinks (matches Libro + the
--     operator-default `business_day_start_local_time = '04:00'`).
--   * Column deprecated, NOT dropped in 7b. The drop migration is a
--     follow-up after a deprecation cycle so a rolled-back deploy can
--     fall back to the legacy SQL trigger if needed.
--
-- This migration adds a column comment only — no DDL changes, no data
-- changes, fully backward compatible. The column remains writable and
-- readable; only its role in the architecture is now documented.

comment on column public.locations.business_day_rollover_hour is
  'DEPRECATED 2026-05-15 by Per-Daypart V1 / Slice 7b option (b). '
  'Vendor sinks now resolve the business-day cutoff via the canonical '
  '`business_timing_profiles.business_day_start_local_time` chain '
  '(operator → org_unit → location inheritance per HP #11, sub-hour '
  'aware). The SQL trigger '
  '`phase_8_set_business_date()` still reads this column as a '
  'defense-in-depth backup. Drop migration deferred to a follow-up '
  'after a deprecation cycle.';
