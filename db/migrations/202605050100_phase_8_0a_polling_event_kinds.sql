-- Phase 8 spine-bridge `8.spine-bridge.0a` — extend
-- `connector_sync_log.event_kind` CHECK constraint to admit the four
-- event kinds the polling cadence resolver + its dispatch hook emit.
--
-- Authority:
--   * docs/contracts/data_accuracy_settings_contract.md "Polling
--     cadence resolution" — F&F-controlled tier model (REVERSED
--     2026-05-05).
--   * docs/contracts/integration_spine_architecture_contract.md sub-
--     lane `.0a`.
--
-- New event kinds:
--   * `tier_assignment_missing` — resolver invoked with a null tier
--     row for (operator, location); fell back to the standard-tier
--     presets. F&F Ops Console (`8.spine-bridge.C`) surfaces this so
--     operations sees which operator-locations still need a tier
--     assignment after onboarding.
--   * `cadence_clamped` — resolver received an override outside
--     `[vendor_minimum, framework_maximum]` (3600s) and clamped it.
--     The audit row carries the requested + clamped values + the
--     bound name (`vendor_minimum` / `framework_maximum`).
--   * `custom_tier_vendor_unset` — tier_key='custom' assigned for the
--     (operator, location) but the per-vendor JSONB has no entry for
--     this vendor; resolver fell back to the vendor minimum. Tells
--     F&F admin which vendor cadences still need explicit values for
--     a custom-tier operator.
--   * `tier_assignment_lookup_failed` — the dispatch hook's tier-
--     assignment lookup threw (DB connection lost, timeout, etc.).
--     The poll proceeds with the default cadence; the failure is
--     surfaced separately so it does not get conflated with vendor
--     poll errors.
--
-- This migration also closes a latent gap from Lane `.0`: the
-- dispatcher was already emitting `vendor_not_registered` (when a
-- `connector_connection.vendor_id` references a retired or drifted
-- vendor key) but that value was missing from the original CHECK
-- list. Lane `.0`'s in-memory test fakes do not enforce CHECK
-- constraints, so the gap was invisible until a Postgres-backed sink
-- ran the path.
--
-- The CHECK constraint is dropped + recreated in a single transaction.
-- No rows in `connector_sync_log` carry the new values yet, so the
-- recreate is a structural-only change — no data migration needed.

begin;

alter table public.connector_sync_log
  drop constraint if exists connector_sync_log_event_kind_check;

alter table public.connector_sync_log
  add constraint connector_sync_log_event_kind_check
  check (event_kind in (
    'poll_success',
    'poll_error',
    'webhook_received',
    'webhook_rejected',
    'auth_refresh',
    'auth_refresh_failed',
    'rate_limit_retry',
    'connect',
    'disconnect',
    'test_connection',
    'sanity_drop',
    'vendor_not_registered',
    'tier_assignment_missing',
    'cadence_clamped',
    'custom_tier_vendor_unset',
    'tier_assignment_lookup_failed'
  ));

commit;
