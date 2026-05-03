# Phase 10a - Shared Multi-Device State (V1)

Updated: 2026-05-02
Status: Active. `10a.0` realtime push channel scaffold accepted (NOTIFY
→ `EventOutboxRepository.claimBatch` → `RealtimeEventPublisher`
in-process binding → `/v1/realtime` WebSocket → client
`RealtimeSubscription` with reconnect/back-off; `WeekDataNotifier`
hook for `rollup.invalidate.variance_week`). See
`docs/_walkthroughs/10a.0.md`. Cloud Pub/Sub publisher, retry ledger,
dead-letter cap, retention sweep, yellow/red tripwires, and
`last_event_id` replay are queued Phase 10a follow-ups; they layer on
the `RealtimeEventPublisher` seam without touching the bridge worker
or the WebSocket route. UX sub-slice family `10a.UX.0-1` (sync-state
badge, peer-edit toast, freshness rows) wires the shipped subscription
into the operator shell.
Owner: Future shared-state lane

## 2026-04-28 - Phase 9 Foundation Available

`9.0Σ.e` event_outbox foundation is merged into master via `fe14b31`:

- Migration: `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql`
- Repository:
  `lib/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart`
- Contract: `docs/contracts/event_outbox_contract.md`

The transactional outbox + `pg_notify` wake-up is the durable substrate.
This phase's first slice is the Pub/Sub bridge consumer worker — read
the contract above plus `phase_9_execution_backlog.md` B26 (foundation)
before drafting prompts. Health metrics for outbox lag /
undelivered-count are queued in `phase_9_execution_backlog.md` B42 (proxy
`/health` expansion).

## Decisions Locked (2026-04-23 review; backend updated 2026-04-26)

- **Scope: V1, not V2.** Phase 10a ships shared-state infrastructure
  sufficient for single-operator launch with 2-3 manager devices online
  most of the time. Full offline sync with optimistic concurrency and
  complex conflict resolution is deferred to Phase 10b (post-launch).

- **Sequencing: pre-launch.** Phase 10a is pulled forward from H1 2028
  to the Jul-Sep 2026 sprint so Forge & Flow's manager multi-device use
  case works at Vanessa's restaurant launch (host stand tablet + office
  computer + phone on the floor). Starts mid-sprint after Phase 9 auth
  identity is usable.

- **Backend: Azure DB Flexible Server (Postgres) with Row-Level
  Security.** Same Postgres instance as Phase 9 (profiles, roles) and
  Phase 9.5 (leaderboard). Locked 2026-04-26 (was Supabase prior;
  pivoted to Azure DB Flexible Server in `Canada Central`, PG 16,
  because Apache AGE for Phase 11a is GA on Azure but unavailable on
  Supabase). Shared-state tables live under the `public` schema with
  RLS policies scoping every read/write by `restaurant_id` from the
  Firebase JWT claim.

- **Conflict resolution: last-write-wins (LWW) with audit trail.**
  Postgres server timestamps (`updated_at` set by trigger on every
  UPDATE) establish ordering. Writes never reject on concurrency; the
  later write overwrites. Audit trail captures every write with
  `written_by_uid`, `written_at`, and the prior value, so disputes are
  resolvable after the fact.

- **Real-time sync: durable `event_outbox` → Pub/Sub → WebSocket bridge
  + client polling fallback.** Locked 2026-04-26, refined
  2026-04-27 by Q22 / item 33 of
  `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
  (was "Supabase Realtime" prior; Azure DB does not bundle a Realtime
  equivalent). The contract is in
  `docs/contracts/event_outbox_contract.md`. **NOTIFY is a wake-up
  signal only — never the source of truth.** Producers enqueue rows
  in `public.event_outbox` inside the same transaction as their
  business write; the bridge worker in the Cloud Run proxy backend
  shards by operator, claims durable rows via
  `EventOutboxRepository.claimBatch(...)` (`SELECT … FOR UPDATE SKIP
  LOCKED` against the tenant-leading index), publishes to Cloud
  Pub/Sub, and only then marks `delivered_at`. The bridge MUST NOT
  bypass `event_outbox` and route straight off the
  `pg_notify('event_outbox', …)` envelope — Postgres drops
  notifications under queue pressure, so a NOTIFY-only bridge would
  lose events. Fallback channel is client-side polling every
  30-60 seconds. If the WebSocket bridge degrades or the connection
  drops, the client keeps working from cache and catches up via
  polling. This belt-and-suspenders pattern is resilient to brief
  bridge outages. Cloud Run WebSocket lifetime cap (~60 minutes
  idle) is acceptable; clients reconnect transparently. Alternative
  considered and rejected: managed WebSocket service (Pusher / Ably)
  — adds a vendor in T&Cs without architectural benefit.

- **Device-local SQLite stays as cache, not source of truth.** Reads
  served from local SQLite cache; writes route through the proxy
  backend → Azure DB first, then update local cache. On app startup,
  local cache hydrated from the latest Postgres state via one bulk
  sync call.

- **Shared-state list (in Postgres, RLS-protected):**
  - `restaurants` (timing config, service-period definitions)
  - `benchmark_overrides` (manager override applications)
  - `weekly_plan_snapshots` (locked weekly plans)
  - `target_cycle_provenance` (which cycle is active, when locked)
  - `app_notifications` (read/dismissed state)
  - `audit_trail` (append-only log of manager actions)
  - `connector_configs` (Toast/7shifts/OpenTable webhook URLs, credential
    metadata; secrets NEVER in Postgres - those live in Cloud Run env)
  - `restaurant_users` + `roles` + `role_permissions` (Phase 9 tables;
    shared with 10a scoping)

- **Per-device-only state (stays SQLite, never Postgres):**
  - Canonical operational facts cache (`ClosedShiftInput`,
    `OpenShiftSnapshot`, `ReservationBookSnapshot`, `RawImportRecord`)
  - Derived read models (`ShiftDashboardReadModel`, etc.)
  - Import tracking (`ImportRun`, `SyncWatermark`)
  - UI state (scroll positions, expanded rows, local drafts)

## Goal

Make Forge & Flow's shared restaurant state (settings, overrides,
locked plans, audit trail, notifications) consistent across the manager's
multiple devices, so an action taken on one device propagates to the
other devices within seconds. Without this, a manager on the office
computer and a manager on the host-stand tablet see different app state
for the same restaurant.

## Scope

Phase 10a owns:

- Azure DB Flexible Server (Postgres) schema for shared-state tables
  (under `public` schema or a dedicated `shared_state` schema)
- Row-Level Security (RLS) policies on every shared-state table,
  scoping by `restaurant_id` from JWT claims
- `updated_at` trigger on every table for LWW ordering
- Audit trail table (append-only) with mutation log
- Editable restaurant timing + service-period settings UI that writes
  through Postgres via the proxy backend (supersedes the
  Settings-screen read-only timing display landed in `7.55o.4`)
- `event_outbox` → Cloud Pub/Sub → WebSocket bridge in the Cloud Run
  proxy backend (Lock 9 in `phase_11a_decision_register.md` Production
  Hardening Locks, completes Q22 / item 33 from
  `phase_9_scalability_decisions_2026-04-27.md`):

  Authority for the table shape, claim contract, payload rules, topic
  namespaces, lease semantics, and yellow/red tripwires is
  `docs/contracts/event_outbox_contract.md`. Phase 9.0Σ.e (B26) lands
  the table + repository + the foundation tests; Phase 10a builds the
  bridge worker against that contract. **NOTIFY is a wake-up signal
  only — never the source of truth.** The bridge MUST claim durable
  `event_outbox` rows via `EventOutboxRepository.claimBatch(...)`; a
  bridge that skipped the table and routed straight off the
  `pg_notify('event_outbox', …)` envelope would lose events the
  moment Postgres dropped a notification under queue pressure.

  - **Source of truth**: producers enqueue rows in
    `public.event_outbox` inside the same transaction as the business
    write (see contract doc "Producer Contract"). The
    `event_outbox_notify` trigger fires `pg_notify('event_outbox',
    '{operator_id, topic, id}')` on insert; the bridge `LISTEN`s on
    that channel. NOTIFY may be dropped under connection failure or
    queue pressure — the bridge's 60s scheduled poll is the catch-all.
  - **Claim path**: bridge worker shards by operator and runs each
    shard's claim inside `runInTenantContext(operator)` so the
    per-tenant RLS policy admits the row.
    `EventOutboxRepository.claimBatch(...)` issues `SELECT … FOR
    UPDATE SKIP LOCKED` against the tenant-leading
    `(operator_id, picked_up_at NULLS FIRST, id)` index, stamps
    `picked_up_at = now()` on each claimed row, and returns rows in
    `id` ascending order. Worker concurrency scales linearly with
    shard count.
  - **Topic routing**: payload `topic` (locked namespaces in the
    contract: `auth.session.*`, `auth.user.*`, `usage.cap.*`,
    `rollup.invalidate.*`, `advisor.candidate.*`,
    `workflow.event.*`, `internal.health.*`) maps to the matching
    Cloud Pub/Sub topic. Operator scoping is enforced by injecting
    `operator_id` into the Pub/Sub subscription filter; subscribers
    never see cross-operator events.
  - **Payload contract**: producers stuff a JSON object into the
    `payload` jsonb column (DB CHECK enforces both
    `jsonb_typeof = 'object'` and ≤ 256 KiB). The bridge publishes
    the row's payload as the Pub/Sub message body. Payloads MUST
    NOT carry secrets — see contract doc "Payload Shape" for the
    full rule set. Payloads SHOULD include `event_id` (UUID) so
    consumers can dedupe across at-least-once redeliveries, and
    SHOULD include `occurred_at` so consumers compute lag without
    joining back to `event_outbox`.
  - **Lease + retry**: claimed rows carry a stale-reclaim lease
    (default 5 min, tunable per claim via the `claimReclaimAfter`
    parameter; see contract doc "Claim Lease + Returned Order
    (Locked)"). On Pub/Sub ack, worker writes
    `delivered_at = now()` and the row drops out of the claim
    predicate. On graceful Pub/Sub failure, worker increments
    `attempt_count`, writes `last_error_at` + `last_error`, and
    re-NULLs `picked_up_at` so the next claim picks the row up
    immediately. On worker crash between claim-commit and Pub/Sub
    ack, the lease window expires and another worker re-claims.
    Pub/Sub itself is at-least-once anyway and consumers dedupe via
    `event_id`, so the cost of a rare double-publish is bounded.
  - **Dead-letter**: rows whose `attempt_count` exceeds the tunable
    cap (Phase 10a defines, expected ≥ 5) move to
    `event_outbox_dead_letter` and surface in F&F Dev/Admin Health
    UX. Dead-letter handling is alarmed.
  - **Retention sweep**: Cloud Run scheduled job (or `pg_cron`)
    deletes rows where `delivered_at IS NOT NULL AND delivered_at <
    now() - INTERVAL '7 days'`. Un-delivered rows are never
    auto-deleted; the yellow/red tripwires alert before the table
    grows past safe size.
  - **WebSocket lifecycle** (downstream of Pub/Sub):
    - Cloud Run idle timeout: 60 minutes (cap); transparent client
      reconnect on close
    - On reconnect, client provides last-seen `event_id`; server
      replays missed events from Pub/Sub message backlog (up to 5
      minutes retention)
    - Heartbeat ping every 30s
    - Server closes connection if heartbeat missed for 90s
    - Client falls back to 30-60s polling if WebSocket fails 3×
      consecutively within 5 minutes (circuit-breaker pattern
      matching Lock 7 LLM fallback shape)
  - Each WebSocket connection authenticates via Firebase JWT; proxy
    injects `(operator_id, location_id, staff_id NULL)` into the
    Pub/Sub subscription filter so the connection only receives
    operator-scoped events.
  - **Yellow/red tripwires** (Q22 lock; surface in F&F Dev/Admin
    Health UX, not just logs):
    - Yellow: bridge lag > 60s, undelivered outbox rows > 10 000,
      publish error rate > 1 %, or
      `pg_notification_queue_usage()` ≥ 0.10
    - Red: bridge lag > 5 min, undelivered rows > 100 000, repeated
      publish failures, or `pg_notification_queue_usage()` ≥ 0.25
    - Fallback when red fires: poll-by-shard, increase workers,
      dead-letter repeated failures, slow non-critical producers.
- Client-side repository layer that:
  - reads local SQLite cache for fast display
  - writes through the proxy backend → Azure DB first, updates cache
    on success
  - subscribes to the proxy WebSocket bridge for push updates on
    shared-state table changes
  - falls back to polling every 30-60 seconds if the bridge degrades
- Conflict detection and logging (not rejection; LWW just records the
  overwrite in audit trail)
- Startup sync path: on app launch, hydrate SQLite cache from Postgres
  before rendering any shared-state-dependent UI
- Offline write queue: writes while disconnected go to a local queue,
  flush on reconnect, audit trail records offline-origin flag

Adjacent work that plugs in:

- Per-operator data isolation integration tests (explicit cross-operator
  read attempts; must fail by RLS)
- Security audit of RLS policies (lands in the pre-launch security
  audit, E23 $6,500)
- Admin console writes for Phase 9.75 Recognition and coaching content
  (both routed through the same shared-state write path)

## Scope Does Not Own

Phase 10a does not own:

- Full offline sync with optimistic concurrency (`Phase 10b`)
- Multi-user conflict UI ("someone else just changed this; refresh?")
  (`Phase 10b`)
- Operational-facts sync (those stay per-device; each device pulls from
  vendor adapters independently)
- Auth, roles, permission keys (`Phase 9`)
- Methodology corpus storage (`Phase 11a` — different tables)
- Cross-restaurant analytics (no cross-restaurant read paths exist;
  each restaurant is isolated)
- Real-time UI animations on peer-device changes (post-launch UX
  polish)

## Frontend Exposure

Phase 10a is infrastructure-heavy (event_outbox + Pub/Sub bridge +
WebSocket). The operator-facing UX that surfaces sync state lands as
the `10a.UX.0-1` family. Per Hard Promise #10, both backend and UX
families close before phase acceptance.

**Operator-facing surfaces this phase requires:**

- App-bar sync-state badge (live / stale / reconnecting / offline) on
  Forge & Flow + Barrio shells. Shared widget under
  `lib/screens/_shared/sync_state_badge.dart` (new).
- Per-device freshness row in
  `lib/screens/settings/settings_data_sections.dart` (new section)
  showing last-sync timestamp per shared-state table.
- Toast / inline notice when a peer device just changed the row the
  current user is viewing (LWW outcome surfaced, not concealed).
  Triggered by WebSocket frame; suppressed when the same device made
  the change.

**Admin (11A) surfaces this phase requires:** outbox lag tile +
undelivered-count tile in the 11A health/observability admin surfaces
(B26 → B42 producer wiring). No additional 11A scope here.

**UX sub-slice family:** `10a.UX.0-1`

- `10a.UX.0` — sync-state badge + reconnect chrome. Reads bridge
  connection state from a shared notifier; renders pill in app bar.
- `10a.UX.1` — peer-edit toast + freshness row in Settings. Wires
  WebSocket frames to a notification surface; renders per-table
  last-sync rows.

Conflict-resolution UI (high-stakes object collisions, "keep yours /
accept theirs / merge") is **out of scope for 10a** and lives in
Phase 10b.

**Demo-mode walkthrough (`kDemoMode = true`)** — needs a fake bridge
notifier to simulate state transitions:

- `10a.UX.0`: launch app → bridge notifier reports `connected` →
  badge shows green "Live" → notifier reports `disconnected` → badge
  shows amber "Reconnecting…" → notifier reports `connected` again →
  badge returns to green.
- `10a.UX.1`: open Shift → notifier injects a peer-edit frame for the
  shift the user is viewing → toast appears with "Updated by another
  device" → Settings → Sync → see last-sync timestamps per table.

Walkthrough evidence required at slice acceptance per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Runtime Contract

```text
write path:
  client → proxy backend (/v1/...) → Azure DB Postgres (RLS-scoped by JWT)
  ↳ Postgres trigger sets updated_at server timestamp
  ↳ audit_trail row appended
  ↳ producer enqueues one row in public.event_outbox in the SAME
    transaction (operator_id + dotted topic + JSON-object payload);
    the AFTER INSERT trigger fires pg_notify('event_outbox', ...) as
    a wake-up signal only
  ↳ local SQLite cache updated on write success

read path (hot):
  client → local SQLite cache (fast)

read path (cold / startup):
  client → proxy backend → Azure DB Postgres bulk query (RLS-scoped)
  ↳ hydrate SQLite cache

bridge path (Phase 10a worker):
  worker LISTEN 'event_outbox' (wake-up only) + 60s scheduled poll
  ↳ for each operator shard: runInTenantContext(operator_id) →
    EventOutboxRepository.claimBatch(...) issues SELECT ... FOR
    UPDATE SKIP LOCKED + lease + delivered_at IS NULL filter, stamps
    picked_up_at = now(), returns rows ordered by id ascending
  ↳ for each claimed row: publish payload to the matching Cloud
    Pub/Sub topic (routed by the row's `topic` namespace)
  ↳ on Pub/Sub ack: write delivered_at = now()
  ↳ on graceful Pub/Sub failure: increment attempt_count, write
    last_error_at + last_error, re-NULL picked_up_at
  ↳ on worker crash between claim-commit and Pub/Sub ack: lease
    expires (default 5 min), another worker re-claims

subscribe path:
  client → proxy WebSocket /v1/realtime?operator_id=...
  ↳ proxy authenticates Firebase JWT, subscribes to operator-scoped
    Pub/Sub topics; payloads come from the bridge's published
    event_outbox rows
  ↳ client receives event payload (carries operator_id + topic +
    event_id for dedupe + occurred_at + the bits the producer chose
    to ship): update SQLite cache (refetch row by pk if needed),
    invalidate dependent read models

fallback path (if WebSocket bridge degrades):
  client polls proxy backend every 30-60 seconds for updated_at
  changes since last poll
  ↳ proxy queries Azure DB Postgres (RLS-scoped) for changed rows
  ↳ updates SQLite cache with any new rows
```

Rules:

- Postgres is the authoritative source for all shared state; SQLite
  cache is disposable and can be rebuilt from Postgres at any time
- LWW ordering comes from Postgres server timestamps, not client
  timestamps (client clocks may drift)
- RLS enforcement happens at the database layer for every query; no
  client-side scoping logic is trusted
- Audit trail is append-only; never mutate or delete audit rows
- The WebSocket bridge is best-effort; the app must work correctly
  even if the bridge is offline for minutes
- `event_outbox` is the source of truth for fan-out events; the
  bridge MUST claim through `EventOutboxRepository.claimBatch(...)`
  and treat `pg_notify('event_outbox', ...)` as a wake-up signal
  only — no direct LISTEN-fan-out path may bypass the outbox

## Dependencies

Required before Phase 10a can ship real:

- `Phase 9` auth identity and JWT integration with Postgres (RLS
  depends on Firebase JWT claims reaching Postgres via the proxy
  backend's session-variable injection)
- Azure DB Flexible Server (Postgres) instance provisioned (same
  instance as Phase 9, 9.5; provisioned in `11a.11c.6`)
- `public.event_outbox` table + repository (lands in Phase 9.0Σ.e
  / B26; contract in `docs/contracts/event_outbox_contract.md`).
  Producers enqueue rows in the same transaction as the business
  write; the AFTER INSERT trigger fires `pg_notify('event_outbox',
  …)` as a wake-up signal only. Bridge worker (this phase) claims
  durable rows via `EventOutboxRepository.claimBatch(...)` and
  publishes to Cloud Pub/Sub. No direct `LISTEN` → fan-out path
  may bypass the outbox.
- Initial RLS policies written and tested against cross-operator
  access attempts

Consumers of Phase 10a:

- `Phase 9.75` Barrio V1.1 (read receipts on announcements, Focus
  rollover, pinned-announcement consistency all depend on 10a's shared
  state)
- All future manager actions that should be "seen by the team" on
  other devices

## Non-Negotiables

- RLS policies on every shared-state table; no table exposes
  cross-operator reads
- No service-role key in Flutter client; all service-role writes
  (admin ops) happen in Cloud Functions / Edge Functions / Cloud Run
- Writes are write-through (Postgres first, then cache), not
  write-behind
- No client-trusted ordering (server timestamps only)
- Audit trail captures every write to shared-state tables
- The app must function correctly if the proxy WebSocket bridge is
  offline (polling fallback is the safety net, not the exception)
- Connector secrets live in Cloud Run env, NOT in `connector_configs`
  Postgres table (only non-secret metadata: webhook URLs, vendor
  names, last-sync timestamps)

## Adjacent Phases

- `Phase 9` provides the JWT identity that RLS scopes on
- `Phase 9.5` shares the same Postgres project; leaderboard writes
  follow the same LWW + audit pattern
- `Phase 9.75` consumes 10a's shared state for multi-device consistency
  (read receipts, pinned announcements, Focus tab rollover)
- `Phase 10b` post-launch V2 layers full offline support and optimistic
  concurrency on top of 10a's foundation
- `Phase 11a` stays a parallel lane, but its operator-scoped corpus
  tables should follow the same RLS and audit-metadata conventions where
  they overlap with shared-state governance

## Source Material

Research and industry-standard patterns this spec is built against:

- [Postgres RLS with custom JWT claims (industry pattern)](https://www.wellally.tech/blog/postgres-multi-tenant-database-row-level-security)
- [Postgres LISTEN/NOTIFY documentation](https://www.postgresql.org/docs/current/sql-listen.html)
- [Cloud Run WebSocket support](https://cloud.google.com/run/docs/triggering/websockets)
- Phase 10.5 doc as structural template for quality bar
- Phase 9 doc for the RLS + JWT integration foundation

## Handoff From 7.55r Audit (2026-04-24)

A deep architecture-alignment audit surfaced one misalignment explicitly
scoped to Phase 10a rather than to any current lane: **editable
restaurant timing + service-period settings UI.** This handoff captures
what exists, what's missing, and what Phase 10a should build.

### Current state (what's persisted, what's wired)

- `RestaurantTimingConfig` fully persists `businessTimezone`,
  `businessDayStartLocalTime`, `weekStartDay`, `shiftCloseAuthority`,
  and `servicePeriodDefinitions` (7.55n).
- `RestaurantTimingConfigReadService.instance.getActiveTimingConfig()`
  is the canonical read seam and is already consumed by
  `WeeklyPlanSnapshotService`, `ShiftBoundaryResolver` in
  `ShiftService`, and — after 7.55r item 1 —
  `VarianceWeekProjectionReadService` and `ScheduleForecastNotifier`.
- `SettingsScreen` currently renders a **read-only** display of the
  resolved timing values; there are no controls to edit them.
- No code path anywhere writes a new `RestaurantTimingConfig` at
  runtime. The persisted config is currently always absent for the
  demo restaurant; every consumer hits its honest Monday/demoDefinitions
  fallback.

### What Phase 10a should build (editable settings write path)

This is the concrete checklist implied by the existing
"Editable restaurant timing + service-period settings UI that writes
through Postgres" Scope bullet:

- Settings UI controls for:
  - `businessTimezone` (IANA picker — must reject non-IANA strings)
  - `businessDayStartLocalTime` (e.g., `04:00`)
  - `weekStartDay` (Monday through Sunday selector)
  - `shiftCloseAuthority` (enum: `vendorFinalization` vs
    `appLocalCutoffFallback`)
  - `servicePeriodDefinitions[]` — add/remove/edit service periods
    with fields: stable `id`, `label`, `shortLabel`, `sortOrder`,
    `startLocalTime`, `endLocalTime`, `rollsPastMidnight`, weekday
    applicability.
- Write path through the proxy backend to Azure DB Postgres (via the
  Phase 10a shared-state repository), respecting RLS scoping on
  `restaurant_id`.
- On write, invalidate downstream read models so any mid-week change
  triggers recompute (Variance daypart subrows, Schedule daypart
  subrows, Shift boundary resolution). Locked weekly-plan snapshots
  remain locked per the Time Boundary Contract — timing changes
  affect *future* weeks only.
- Admin-vs-manager permission split if Phase 9 role enforcement is
  active by then (editing timing config is administrative).

### Non-negotiables inherited from the Time Boundary Contract

- Timing changes must never rewrite already-locked truth (locked
  weekly snapshots, closed shifts).
- Restaurant timezone changes need careful handling: once data has
  been ingested under one timezone, re-interpreting existing
  `businessDate` values under a new timezone could corrupt history.
  Policy choice required during 10a implementation.

### Source material

- `docs/contracts/phase_7_55_time_boundary_contract.md` — authoritative
  rules the editable UI must preserve.
- `lib/domain/models/restaurant_timing_config.dart` — persistence shape.
- `lib/data/restaurant_timing_config_read_service.dart` — read seam.
- `lib/screens/settings_screen.dart` — current read-only display to
  extend.

## Placeholder Notes

- Exact Postgres schema (table names, columns, indexes) to be designed
  during implementation spec pass
- Offline write queue semantics (queue ordering, max queue size, flush
  cadence) to be designed during implementation spec pass
- Audit trail retention policy to be decided (append-forever vs archive
  after N months)
- WebSocket-bridge subscription granularity (per-table channel vs
  per-row filtering, e.g.,
  `shared_state:<restaurant_id>:weekly_plan_snapshots:<plan_id>`) to
  be decided during implementation spec pass
- Tracker folding: add to `PROJECT_TRACKER.md` Active Planning Docs list
  on next Codex pass
