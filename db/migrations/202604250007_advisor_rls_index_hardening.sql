-- Phase 11a.11c.6 live hardening - RLS-leading identity indexes.
--
-- The first Azure RLS-leading-column audit caught three identity indexes whose
-- leading key was not operator-scoped:
--   * advisor_proxy_usage_counters(counter_id)
--   * proxy_requests(request_id)
--   * proxy_requests(idempotency_key)
--
-- For multi-tenant RLS, hot fact/idempotency lookups must stay scoped by
-- operator/location first so tenant filters do not degrade into broad scans.
-- This migration changes the final live shape while preserving the UUID
-- columns for response payloads and traceability.

alter table public.advisor_proxy_usage_counters
  drop constraint if exists advisor_proxy_usage_counters_pkey;

alter table public.advisor_proxy_usage_counters
  drop constraint if exists
    advisor_proxy_usage_counters_operator_id_location_id_tier_i_key;

alter table public.advisor_proxy_usage_counters
  add constraint advisor_proxy_usage_counters_pkey
  primary key (operator_id, location_id, tier_id, minute_bucket);

create index if not exists advisor_proxy_usage_counters_counter_lookup_idx
  on public.advisor_proxy_usage_counters
  (operator_id, location_id, counter_id);

comment on table public.advisor_proxy_usage_counters is
  '11a.11c.6 hardening. One row per (operator, location, tier, UTC minute); primary key is tenant-leading for RLS performance. counter_id remains a trace UUID, not the lookup key.';

alter table public.proxy_requests
  drop constraint if exists proxy_requests_idempotency_key_key;

alter table public.proxy_requests
  drop constraint if exists proxy_requests_operator_location_idempotency_key_key;

alter table public.proxy_requests
  drop constraint if exists proxy_requests_pkey;

alter table public.proxy_requests
  add constraint proxy_requests_pkey
  primary key (operator_id, location_id, request_id);

alter table public.proxy_requests
  add constraint proxy_requests_operator_location_idempotency_key_key
  unique (operator_id, location_id, idempotency_key);

create index if not exists proxy_requests_operator_location_created_idx
  on public.proxy_requests
  (operator_id, location_id, created_at);

comment on table public.proxy_requests is
  '11a.11c.6 hardening. Idempotency table scoped by (operator_id, location_id, idempotency_key); request_id remains a trace UUID. Tenant-leading keys preserve RLS performance.';
