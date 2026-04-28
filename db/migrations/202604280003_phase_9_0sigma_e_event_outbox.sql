-- Phase 9.0Σ.e — durable event_outbox foundation (item 33 / Q22 from
-- `phase_9_scalability_decisions_2026-04-27.md`, B26 in
-- `phase_9_execution_backlog.md`).
--
-- This slice creates the database side of the locked
-- NOTIFY → outbox → Pub/Sub → WebSocket pattern. The transactional
-- outbox row IS the source of truth: every business write that needs
-- to fan out enqueues one `event_outbox` row in the same transaction
-- as the business change. `pg_notify('event_outbox', ...)` fires from
-- a row-level INSERT trigger and is treated only as a lightweight
-- wake-up signal; the bridge worker (Phase 10a) reads `event_outbox`,
-- publishes to Cloud Pub/Sub, and marks rows delivered only after
-- Pub/Sub accepts. Q22 explicitly forbids treating NOTIFY as the
-- truth, since notifications are dropped under Postgres connection
-- failures and queue-pressure conditions.
--
-- This migration is local framework only — no live mutation. The
-- bridge worker, the WebSocket leg, and dead-letter handling all
-- land in Phase 10a per the backlog gate. The repository in
-- `lib/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart`
-- exposes the enqueue + claim contract this slice locks; the contract
-- doc at `docs/contracts/event_outbox_contract.md` documents the
-- topic shape and the Phase 10a worker boundary.
--
-- Hard rules carried from CLAUDE.md and the 4-27 lock:
--   1. RLS performance discipline — the claim-scan index leads with
--      `(operator_id, picked_up_at NULLS FIRST, id)`. Tenant context
--      lands first so the policy can fold the predicate into the
--      index probe; `picked_up_at NULLS FIRST` puts undelivered rows
--      at the front so the worker's `WHERE picked_up_at IS NULL`
--      filter walks contiguous index pages.
--   2. RLS uses the wrapper functions from 9.0Σ.b
--      (`public.app_current_operator()`); bare `current_setting()`
--      is forbidden by the lint in `tool/rls_policy_lint.dart`.
--   3. `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
--      banned in operator-scoped tables.
--   4. The trigger uses `pg_notify(channel, payload)` so the listening
--      bridge can route by topic without parsing the row first. The
--      payload carries `{operator_id, topic, id}` so the worker can
--      decide whether to claim or skip based on its shard assignment;
--      the full `payload jsonb` is read from the row on claim, not
--      from the notification.
--
-- Phase 10a worker contract (locked here so the schema does not
-- evolve underneath the bridge):
--   * Worker calls `EventOutboxRepository.claimBatch(...)` which
--     issues `SELECT ... FOR UPDATE SKIP LOCKED` and stamps
--     `picked_up_at = now()` in the same transaction.
--   * On Pub/Sub ack, worker marks the row delivered (column lands
--     in this slice as `delivered_at`; phase 10a fills it).
--   * On Pub/Sub failure, worker increments `attempt_count` and
--     records `last_error_at` / `last_error`. After a tunable
--     attempt cap (Phase 10a) the bridge dead-letters the row.
--   * Retention: a Phase 10a Cloud Run scheduled job deletes
--     delivered rows older than 7 days; un-delivered rows are
--     never auto-deleted (Q22 yellow/red tripwires alert before the
--     table grows past safe size).

begin;

-- ─── event_outbox ─────────────────────────────────────────────────────
--
-- `id bigserial` per Q22 — sequence-leading PK so claim ordering is
-- monotonic per operator and the bridge can resume from a known
-- watermark after a worker restart.
--
-- `operator_id uuid` per CLAUDE.md per-operator isolation rule. The
-- column is NOT NULL because every event flows out of an operator's
-- transaction; system-issued events (e.g. F&F infrastructure health)
-- belong on a separate channel/table that can be added later without
-- changing this contract.
--
-- `topic text` is the routing key the bridge consults to decide
-- which Pub/Sub topic to publish to. Topic shape is locked in the
-- contract doc; constraint here only enforces non-empty + length cap
-- so a runaway producer cannot blow out the index.
--
-- `payload jsonb` is the event body. Producers must keep payloads
-- small (≤ 32 KiB target; hard cap 256 KiB enforced as a CHECK
-- constraint to keep one bad producer from filling the WAL).
--
-- `created_at` records when the producer enqueued the row.
-- `picked_up_at` records when the bridge claimed the row; NULL means
-- "available for claim". Phase 10a adds `delivered_at`,
-- `attempt_count`, `last_error_at`, `last_error` for the retry
-- ledger — declared here so the table shape is stable from the
-- start.
create table if not exists public.event_outbox (
  id bigserial primary key,
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  topic text not null
    check (char_length(topic) between 1 and 200),
  payload jsonb not null default '{}'::jsonb
    check (octet_length(payload::text) <= 262144)
    -- Contract (docs/contracts/event_outbox_contract.md) requires
    -- payloads to be JSON objects so consumers can read fields like
    -- event_id / occurred_at without branching. Without this CHECK
    -- a direct service_role / forge_admin INSERT could write an
    -- array / string / number / null and the repository's claim
    -- decoder would throw on read. Enforced at the DB layer so the
    -- guarantee survives any future producer that bypasses the
    -- repository.
    check (jsonb_typeof(payload) = 'object'),
  created_at timestamptz not null default now(),
  picked_up_at timestamptz null,
  delivered_at timestamptz null,
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  last_error_at timestamptz null,
  last_error text null
);

-- ─── Tenant-leading claim index ───────────────────────────────────────
--
-- The bridge worker's hot query is:
--
--   select id, topic, payload
--     from event_outbox
--    where operator_id = public.app_current_operator()
--      and (picked_up_at is null
--           or picked_up_at < now() - <reclaim_window>)
--    order by id
--    for update skip locked
--    limit @batch_size;
--
-- The composite (operator_id, picked_up_at NULLS FIRST, id) index
-- lets the planner:
--   * narrow to the tenant's rows via the leading column,
--   * walk the undelivered head of the queue contiguously
--     (NULLS FIRST matches the `picked_up_at IS NULL` predicate),
--   * walk the stale-claim section by timestamp range immediately
--     after the NULL block (same index, just scans further),
--   * resolve ORDER BY id from the trailing column without a sort.
--
-- The reclaim window comes from the worker (Phase 10a tunes it; the
-- repository defaults to 5 minutes). Without the reclaim path,
-- picked_up_at is a one-way claim marker and a worker crash between
-- claim-commit and Pub/Sub-ack would strand rows forever — Q22's
-- "real durable queue" guardrail explicitly rules that out.
--
-- Q22 also calls out the danger of indexes that do NOT lead with
-- operator_id; without this lead the RLS policy evaluation becomes
-- a per-row filter and claim throughput collapses on multi-operator
-- deployments.
create index if not exists event_outbox_claim_idx
  on public.event_outbox (operator_id, picked_up_at nulls first, id);

-- ─── pg_notify trigger ────────────────────────────────────────────────
--
-- Fires AFTER INSERT FOR EACH ROW. Notification payload is a small
-- JSON envelope with operator_id, topic, and the row id; the bridge
-- worker uses these to decide whether to claim immediately (its
-- shard owns the operator) or wait for its scheduled poll window.
--
-- The trigger function is intentionally narrow — it does not write
-- the row's payload into the notification (Postgres truncates
-- payloads above 8000 bytes by default and notifications are
-- best-effort anyway). The full row is read inside the claim
-- transaction.
--
-- Channel name `event_outbox` matches the literal the Phase 10a
-- bridge `LISTEN`s on; changing the channel here is a breaking
-- contract change and needs a paired bridge update.

create or replace function public.event_outbox_notify()
returns trigger
language plpgsql
as $$
begin
  perform pg_notify(
    'event_outbox',
    json_build_object(
      'operator_id', new.operator_id,
      'topic', new.topic,
      'id', new.id
    )::text
  );
  return null;
end;
$$;

comment on function public.event_outbox_notify() is
  'Phase 9.0Σ.e — fires pg_notify(''event_outbox'', ...) after every '
  'event_outbox INSERT. Payload is a small JSON envelope '
  '(operator_id, topic, id); the Phase 10a bridge worker reads the '
  'full row from event_outbox on claim. NOTIFY is a wake-up signal '
  'only — durability lives in the table.';

drop trigger if exists event_outbox_notify_trg on public.event_outbox;
create trigger event_outbox_notify_trg
after insert on public.event_outbox
for each row execute function public.event_outbox_notify();

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ──────────────────────────
--
-- Two policies:
--   * `event_outbox_per_tenant_select` — tenants read only their own
--     rows; the bridge worker also runs through this policy when it
--     claims rows because it issues queries inside a tenant
--     transaction (Phase 10a wraps each shard's claim in
--     `runInTenantContext` for the operator it shards).
--   * `event_outbox_per_tenant_modify` — same predicate for
--     INSERT/UPDATE/DELETE so producers cannot enqueue cross-tenant
--     rows and the worker cannot accidentally update another
--     operator's claim state.
--
-- F&F internal admin / dev access uses the `forge_admin` BYPASSRLS
-- escape hatch via `runAsSystem` and audits every bypass with a
-- non-blank reason string (see `TenantTransactionWrapper.runAsSystem`).

alter table public.event_outbox enable row level security;

create policy "event_outbox_per_tenant_select"
  on public.event_outbox for select to service_role
  using (operator_id = public.app_current_operator());

create policy "event_outbox_per_tenant_modify"
  on public.event_outbox for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "event_outbox_per_tenant_select" on public.event_outbox is
  'Phase 9.0Σ.e — tenants and the Phase 10a bridge worker (running '
  'inside a tenant transaction) see only their own outbox rows. '
  'Cross-tenant reads require forge_admin BYPASSRLS via runAsSystem.';

comment on policy "event_outbox_per_tenant_modify" on public.event_outbox is
  'Phase 9.0Σ.e — INSERT/UPDATE/DELETE filtered by '
  'app_current_operator() so producers cannot enqueue cross-tenant '
  'rows and the bridge worker cannot mutate another operator''s '
  'claim state. Forbidden cross-tenant attempts fail at WITH CHECK.';

-- ─── Grants ──────────────────────────────────────────────────────────
--
-- Same posture as the auth-table mutable surface: service_role and
-- forge_admin can SELECT/INSERT/UPDATE/DELETE so the runtime + admin
-- paths both work. PUBLIC stays revoked. DELETE is on the surface
-- because the Phase 10a retention sweep deletes delivered rows older
-- than the retention window; un-delivered rows are never deleted
-- automatically.

grant select, insert, update, delete on public.event_outbox to service_role;
grant select, insert, update, delete on public.event_outbox to forge_admin;
grant usage, select on sequence public.event_outbox_id_seq to service_role;
grant usage, select on sequence public.event_outbox_id_seq to forge_admin;

comment on table public.event_outbox is
  'Phase 9.0Σ.e — durable transactional outbox (Q22 lock). Producers '
  'enqueue in the same transaction as their business write. Phase 10a '
  'bridge worker claims rows via SELECT … FOR UPDATE SKIP LOCKED, '
  'publishes to Cloud Pub/Sub, and marks delivered_at on ack. NOTIFY '
  'is a wake-up signal only; this table is the source of truth.';

commit;
