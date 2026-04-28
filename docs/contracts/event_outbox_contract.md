# event_outbox Contract

Updated: 2026-04-28
Owner: Phase 9.0Σ.e (foundation) → Phase 10a (Pub/Sub bridge + WebSocket)
Status: Active authority

## Why This Exists

`event_outbox` is the durable transactional outbox locked in
`docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
item 33 (Q22). Every business mutation that needs to fan out
(real-time UI push, downstream rollup invalidation, F&F internal
admin telemetry, advisor learning candidate emission) writes one
`event_outbox` row in the same transaction as the business change.
The table is the source of truth; `pg_notify('event_outbox', …)` is
only a wake-up signal so the Phase 10a bridge worker does not have
to poll on idle operators.

This contract pins the topic shape, the producer/consumer split, and
the boundary between the foundation slice (9.0Σ.e) and the bridge
worker slice (Phase 10a) so the schema does not evolve underneath
the worker after the worker ships.

## Foundation vs. Bridge Boundary

This slice (9.0Σ.e) lands:

- `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql` —
  table, tenant-leading claim index, RLS policies through the
  `public.app_current_operator()` wrapper, the
  `event_outbox_notify` trigger, and the grants.
- `lib/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart`
  — `enqueue` + `claimBatch` against the
  `OperatorScopedRepository` / `TenantTransactionWrapper` path.
- This contract document.
- A focused test in
  `test/phase_9_0sigma_e_event_outbox_test.dart` proving the shape
  and the lint posture.

Phase 10a lands:

- The bridge worker (Cloud Run / scheduled container) that
  `LISTEN event_outbox` + claim-loops via `claimBatch`.
- `Pub/Sub` topic / subscription configuration.
- The WebSocket fan-out leg the operator app subscribes to.
- The retry ledger writes (`attempt_count`, `last_error_at`,
  `last_error`) and the dead-letter handling once a tunable cap is
  reached.
- The retention sweep that deletes delivered rows older than the
  retention window (target: 7 days) via `pg_cron` or a Cloud Run
  scheduled job.
- The yellow/red lag tripwires from Q22:
  yellow at 60s lag / 10 000 undelivered rows / 1 % publish error
  rate / `pg_notification_queue_usage()` ≥ 0.10; red at 5 min lag /
  100 000 undelivered rows / repeated publish failures /
  `pg_notification_queue_usage()` ≥ 0.25.
- The fallback path (poll-by-shard, more workers, dead-letter,
  producer slowdown) when red fires.

## Schema (locked here)

```text
event_outbox (
  id            bigserial primary key,
  operator_id   uuid not null references operators(operator_id) on delete cascade,
  topic         text not null  check (char_length(topic) between 1 and 200),
  payload       jsonb not null default '{}'::jsonb
                  check (octet_length(payload::text) <= 262144),
  created_at    timestamptz not null default now(),
  picked_up_at  timestamptz null,
  delivered_at  timestamptz null,           -- Phase 10a fills on Pub/Sub ack
  attempt_count integer not null default 0  check (attempt_count >= 0),
  last_error_at timestamptz null,
  last_error    text null
);
```

Index:

```text
event_outbox_claim_idx on event_outbox (operator_id, picked_up_at NULLS FIRST, id);
```

`operator_id` MUST lead per the CLAUDE.md "RLS performance discipline"
rule — without this lead the per-tenant policy degrades to a row-level
filter and claim throughput collapses on multi-operator deployments.
`picked_up_at NULLS FIRST` matches the worker's
`WHERE picked_up_at IS NULL` filter so the index walks contiguous
pages. The trailing `id` column lets `ORDER BY id` resolve from the
index without a sort.

RLS policies are wrapper-only per 9.0Σ.b:

```text
event_outbox_per_tenant_select  USING  (operator_id = public.app_current_operator())
event_outbox_per_tenant_modify  USING  (operator_id = public.app_current_operator())
                                 WITH CHECK (operator_id = public.app_current_operator())
```

The `public.event_outbox_notify` trigger fires
`pg_notify('event_outbox', '{"operator_id":"…","topic":"…","id":…}')`
after every INSERT. The notification payload is intentionally tiny
(operator_id + topic + id) — the bridge reads the full row from the
table on claim. NOTIFY may be dropped under connection failure or
queue pressure; the worker must NEVER treat absence of a
notification as proof that no row exists. The 60s scheduled poll in
Phase 10a is the catch-all.

## Topic Shape

Topics are dot-separated lower-snake-case strings. The bridge uses
the topic prefix to route to the matching Pub/Sub topic. Locked
namespaces (more added as consumers ship):

- `auth.session.*`           — auth session lifecycle (login,
                                refresh, revoke). Producers: the
                                proxy session-ledger writes (B6).
- `auth.user.*`              — user lifecycle (invite-accept,
                                soft-delete, force-logout, GDPR
                                redaction). Producers: B20 user
                                lifecycle bindings.
- `usage.cap.*`              — usage-cap threshold breaches that
                                need real-time UI alerts. Producers:
                                the 9.0Σ.g two-slot key writers.
- `rollup.invalidate.*`      — late-arriving vendor data that
                                marked a rollup grain stale.
                                Producers: 9.0Σ.k aggregation_state
                                writers.
- `advisor.candidate.*`      — advisor learning candidate emitted
                                from a conversation turn. Producers:
                                Phase 11b advisor turn writer.
- `workflow.event.*`         — Phase 12 workflow lifecycle events
                                (queued, claimed, completed, failed).
                                Producers: 12.0 platform foundation.
- `internal.health.*`        — F&F-internal admin/dev telemetry
                                (graph health, vector index health,
                                vendor sync failures). Producers:
                                11A.* health surfaces.

Producers MUST NOT invent topics outside these namespaces without a
paired update to this doc and to the bridge's routing table. The
character cap (200) is a guardrail against runaway producers; the
expected length is well under 60.

## Payload Shape

`payload jsonb` is the event body. Hard rules:

- Payloads MUST be JSON objects (not arrays, not strings, not
  numbers). Producers serialize through `jsonEncode(...)` in the
  repository's `enqueue` method.
- Payloads MUST stay under 32 KiB target / 256 KiB hard cap (DB
  CHECK constraint). Producers that need bigger payloads should
  store the body elsewhere (object storage, advisor conversation
  log, etc.) and put a reference in the event.
- Payloads MUST NOT carry secrets. Token hashes, ID-token contents,
  password hashes, recovery-code material, full audit-log bodies,
  raw advisor question/recommendation text — none of these belong
  in `event_outbox`. The bridge publishes payloads to Pub/Sub, and
  Pub/Sub subscribers (including future operator-facing WebSocket
  clients) see them.
- Payloads SHOULD include a stable `event_id` field (UUID generated
  by the producer) so consumers can deduplicate after a re-delivery.
  The bigserial `id` column is monotonic per row but a re-delivery
  through Pub/Sub may reuse the same Pub/Sub message id — consumer
  idempotency keys live in the payload.
- Payloads SHOULD include `occurred_at` (ISO 8601 UTC) so consumers
  can compute lag without joining back to `event_outbox`.

## Producer Contract

Producers call `EventOutboxRepository.enqueue(...)` from inside the
business mutation's tenant transaction. Until the executor surface
exposes a "join existing transaction" hook, each `enqueue` opens its
own inner transaction; this gives the "outbox row commits or
doesn't" guarantee but NOT the full "outbox row commits with the
business row" guarantee that Q22 calls for. Closing that gap is a
Phase 10a follow-up — the contract here is locked so the producer
sites do not have to change once the join-existing-transaction hook
lands.

Producers MUST:

- Pass the operator's `operator_id` and a valid `location_id`
  (single-location operators use the operator's default location).
- Pass the actor `user_id` when one is in scope (login, role
  change, manual workflow trigger). Background jobs and scheduled
  sweeps pass `null`.
- Include enough context in `payload` for downstream consumers to
  act without reading back from the producer's table — but stay
  under the size cap and never include secrets.

Producers MUST NOT:

- Issue raw INSERTs against `event_outbox` from outside the
  repository. The CLAUDE.md service-layer split forbids
  `package:postgres` imports outside
  `lib/infrastructure/persistence/postgres/`.
- Skip the repository to "save a transaction" — the SET LOCAL
  payload + the policy match make the per-tenant guarantee real.

## Consumer Contract (Phase 10a)

The bridge worker MUST:

- Run inside a tenant transaction (the worker shards by operator;
  each shard sets its own `app.operator_id` via `withTenant` so the
  policy admits the rows).
- Claim through `EventOutboxRepository.claimBatch(...)` so the
  `SELECT … FOR UPDATE SKIP LOCKED` ordering matches the index and
  workers cannot fight over the same row.
- Treat NOTIFY as a wake-up signal only. The worker MUST also poll
  on a 60s schedule so a dropped notification (Postgres queue
  pressure, connection blip) does not strand a row indefinitely.
- Mark `delivered_at = now()` only after Pub/Sub acks the publish.
- On Pub/Sub failure: increment `attempt_count`, write
  `last_error_at` + `last_error`, and re-NULL `picked_up_at` so the
  next claim picks the row up (subject to the dead-letter cap).
- Dead-letter rows whose `attempt_count` exceeds the tunable cap
  (Phase 10a defines the value; expected ≥ 5) by writing the row to
  a `event_outbox_dead_letter` table and removing it from
  `event_outbox`. Dead-letter handling is alarmed.
- Honor the yellow/red tripwires above and feed them to the F&F
  Dev/Admin Health UX (Q22 calls this out explicitly).

The bridge worker MUST NOT:

- Treat absence of a NOTIFY as proof that no row exists — that's
  the difference between a wake-up signal and a source of truth.
- Hold a row claim across a Pub/Sub publish without a timeout. A
  hung publish must release the claim (rollback the transaction)
  so another worker can retry.
- Mutate `created_at`, `id`, `operator_id`, `topic`, or `payload`.
  Those columns are write-once at producer time.

## Retention

- `delivered_at IS NOT NULL` rows: retained 7 days, then deleted by
  the Phase 10a retention sweep. The `delivered_at` column lets the
  sweep walk by date without a separate index — a partial index
  (`WHERE delivered_at IS NOT NULL`) lands alongside the sweep.
- `delivered_at IS NULL` rows: never auto-deleted. The yellow/red
  tripwires alert before the table grows past safe size; an
  operator-specific runbook walks through manual claim or producer
  pause if needed.

## Tests Belonging to This Contract

- `test/phase_9_0sigma_e_event_outbox_test.dart` — migration shape,
  RLS lint, repository SQL shape (producer + claim).
- Phase 10a will add bridge-worker integration tests (claim →
  publish → ack → delete) and the lag/tripwire tests against a
  synthetic Tier-M load (per the perf-audit gate).

## Change-Control

This document is the contract for the `event_outbox` table and its
producer/consumer split. Schema changes require a paired migration
+ doc update. Adding a topic namespace requires editing the locked
list above. Deleting or renaming a column is a breaking change for
the bridge worker — coordinate with the Phase 10a slice owner
before merging.
