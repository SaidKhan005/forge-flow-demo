-- Phase 8 — Vendor idempotency key hardening: add location_id to the
-- four fact-table partial UNIQUE indexes and to the
-- inbound_webhook_idempotency UNIQUE index.
--
-- ─── WHY ─────────────────────────────────────────────────────────────
-- The previous indexes keyed on
-- (operator_id, vendor_id, vendor_entity_id, vendor_modified_at).
-- Two bugs follow:
--
--   1. Multi-location data loss: Two locations under one operator can
--      share a `vendor_entity_id` (Toast check-id reuse, multi-store
--      POS).  The second location's write silently no-ops because the
--      index fires on the FIRST location's row — the conflict trips
--      before the engine can compare location_id.
--
--   2. Late-backfill shadows newer corrections: vendor_modified_at was
--      part of the key, so an older-timestamped correction
--      (vendor_modified_at < stored) inserted a NEW row rather than
--      being blocked or updating.  The "closed truth never rewritten"
--      promise was violated.
--
-- Fix:
--   * Add location_id to every fact-table idempotency key so same-
--     entity, different-location rows coexist.
--   * Drop vendor_modified_at from the key.  It now lives in the
--     upsert WHERE clause (`WHERE excluded.vendor_modified_at >=
--     public.<fact>.vendor_modified_at`) so older arrivals are
--     rejected, newer arrivals update in-place.
--
-- ─── PATTERN ─────────────────────────────────────────────────────────
-- CONCURRENTLY index ops cannot run inside a transaction block; each
-- DROP/CREATE below runs in its own implicit per-statement transaction
-- so live writers see neither a long lock nor a window without an
-- index.  Re-applying is a no-op: every IF EXISTS / IF NOT EXISTS
-- guard makes subsequent runs safe. Pattern mirrors
-- db/migrations/202605061500_hardening_phase_8_email_index_leading_column_rekey.sql.

-- ─── 1. shift_records_vendor_idempotency_idx ─────────────────────────

drop index concurrently if exists public.shift_records_vendor_idempotency_idx;

create unique index concurrently if not exists shift_records_vendor_idempotency_idx
  on public.shift_records (operator_id, location_id, vendor_id, vendor_entity_id)
  where vendor_id is not null
    and vendor_entity_id is not null;

-- ─── 2. cover_facts_vendor_idempotency_idx ───────────────────────────

drop index concurrently if exists public.cover_facts_vendor_idempotency_idx;

create unique index concurrently if not exists cover_facts_vendor_idempotency_idx
  on public.cover_facts (operator_id, location_id, vendor_id, vendor_entity_id)
  where vendor_id is not null
    and vendor_entity_id is not null;

-- ─── 3. labor_punches_vendor_idempotency_idx ─────────────────────────

drop index concurrently if exists public.labor_punches_vendor_idempotency_idx;

create unique index concurrently if not exists labor_punches_vendor_idempotency_idx
  on public.labor_punches (operator_id, location_id, vendor_id, vendor_entity_id)
  where vendor_id is not null
    and vendor_entity_id is not null;

-- ─── 4. reservation_facts_vendor_idempotency_idx ─────────────────────

drop index concurrently if exists public.reservation_facts_vendor_idempotency_idx;

create unique index concurrently if not exists reservation_facts_vendor_idempotency_idx
  on public.reservation_facts (operator_id, location_id, vendor_id, vendor_entity_id)
  where vendor_id is not null
    and vendor_entity_id is not null;

-- ─── 5. inbound_webhook_idempotency_unique_idx ───────────────────────
-- The prior rekey
-- (202605061500_hardening_phase_8_email_index_leading_column_rekey.sql)
-- promoted operator_id to the leading position but did not add
-- location_id.  Adding it here completes the per-location isolation.

drop index concurrently if exists public.inbound_webhook_idempotency_unique_idx;

create unique index concurrently if not exists inbound_webhook_idempotency_unique_idx
  on public.inbound_webhook_idempotency
    (operator_id, location_id, vendor_id, vendor_event_id);
