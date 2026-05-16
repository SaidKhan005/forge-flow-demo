-- Per-Daypart Targets V1 — Slice 1.5
--
-- Deprecates the operator-set `close_authority` + `local_close_fallback_time`
-- columns on `public.business_timing_profiles` (the Postgres parent of the
-- SQLite `restaurant_timing_configs` mirror named in the prompt).
--
-- Operator decision 2026-05-15: close-authority is now auto-derived per
-- shift from the per-vendor `CloseAuthorityCapability` lookup
-- (`lib/services/integration/close_authority_capability.dart`) plus the
-- operator's `business_day_start_local_time` as the universal fallback.
-- There is no operator-facing setting any more, so the persistent
-- column on `business_timing_profiles` carries no truth.
--
-- This migration drops the NOT NULL + CHECK constraints and the
-- dependent cross-column CHECK so:
--   * New rows can be written without supplying close_authority /
--     local_close_fallback_time.
--   * Existing rows preserve their legacy values until the next
--     wave's full-drop migration (separate slice).
--
-- The dropped CHECK `business_timing_profiles_local_close_required_check`
-- enforced "if close_authority = app_local_cutoff_fallback then
-- local_close_fallback_time is not null", which makes no sense when
-- close_authority is optional. The per-column CHECK on the allowed
-- close_authority enum values is preserved on the still-existing column
-- so any legacy writes still validate.

alter table public.business_timing_profiles
  drop constraint if exists business_timing_profiles_local_close_required_check;

alter table public.business_timing_profiles
  alter column close_authority drop not null;
