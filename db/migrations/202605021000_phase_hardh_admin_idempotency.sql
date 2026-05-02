-- HARD-H — admin request idempotency (cross-tenant admin operations).
--
-- The Phase 9 `proxy_requests` table provides idempotency for tenant-
-- scoped routes (operator_id + location_id NOT NULL with composite FK
-- to `public.locations`). F&F admin operations driven by super_admin /
-- ff_support actors are cross-tenant — the actor JWT carries no
-- operator_id, and the route may legitimately mutate global rows
-- (e.g. `feature_flags` with operator_id IS NULL). proxy_requests
-- cannot host these because:
--
--   1. operator_id is NOT NULL (no value to write for cross-tenant
--      admin actions);
--   2. (operator_id, location_id) composite FK requires a real
--      locations row — admin actions don't have one.
--
-- This table provides idempotency for those routes. Scope axis is
-- (idempotency_key) — admin actors are global and the route is the
-- only producer, so a single-key UNIQUE is sufficient. `request_type`
-- is recorded so a key reused across different admin operations
-- surfaces as a `idempotency_key_conflict` 409 (matching the
-- service-principal idempotency contract).
--
-- Live target: HARD-H feature flags admin route. Other admin routes
-- (operators, locations, pricing tiers, integrations) can adopt the
-- same store as their idempotency posture is rolled out.

begin;

create table if not exists public.admin_request_idempotency (
  idempotency_key text primary key,
  request_type text not null
    check (char_length(request_type) between 1 and 200),
  actor_user_id uuid null,
  request_body_hash text null,
  response_status integer null
    check (response_status is null or response_status between 100 and 599),
  response_payload jsonb null,
  created_at timestamptz not null default now(),
  completed_at timestamptz null
);

comment on table public.admin_request_idempotency is
  'HARD-H — idempotency ledger for cross-tenant F&F admin routes. '
  'Used by routes whose actor JWT carries no operator scope (super_admin '
  'feature_flags toggle, super_admin pricing tier mutations, etc.). '
  'Per-tenant routes continue to use proxy_requests.';

comment on column public.admin_request_idempotency.idempotency_key is
  'Per-request idempotency key from the Idempotency-Key request header. '
  'Primary key — duplicate POSTs with the same key return the cached '
  'response_payload + response_status.';

comment on column public.admin_request_idempotency.request_body_hash is
  'SHA-256 of the canonicalized request body, recorded on reserve so a '
  'duplicate key with a DIFFERENT body surfaces as 409 '
  'idempotency_key_conflict instead of silently replaying the prior '
  'response.';

-- service_role gets full read/write so the proxy can reserve + complete
-- rows. forge_admin can only SELECT (operational visibility for ops);
-- mutations must flow through the proxy.
revoke all on public.admin_request_idempotency from public;
grant select, insert, update on public.admin_request_idempotency to service_role;
grant select on public.admin_request_idempotency to forge_admin;

-- No RLS — the table is global by design (no operator_id column). The
-- table is reachable only by service_role (proxy) and forge_admin
-- (operational read), both of which bypass RLS for a non-tenant-
-- scoped admin ledger.

commit;
