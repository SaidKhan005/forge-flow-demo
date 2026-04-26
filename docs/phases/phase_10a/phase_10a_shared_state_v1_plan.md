# Phase 10a - Shared Multi-Device State (V1)

Updated: 2026-04-26
Status: Planned, ready to build against the locked stack
Owner: Future shared-state lane

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

- **Real-time sync: proxy WebSocket bridge over Postgres LISTEN/NOTIFY
  + client polling fallback.** Locked 2026-04-26 (was "Supabase
  Realtime" prior; Azure DB does not bundle a Realtime equivalent, so
  Phase 10a builds a thin LISTEN/NOTIFY → WebSocket bridge in the
  Cloud Run proxy backend that already exists for `11a.10`. The bridge
  uses native Postgres `LISTEN <channel>` / `NOTIFY <channel>, payload`
  triggered on every shared-state table mutation, fans out to
  authenticated WebSocket clients filtered by `restaurant_id` from the
  Firebase JWT claim). Fallback channel is client-side polling every
  30-60 seconds. If the WebSocket bridge degrades or the connection
  drops, the client keeps working from cache and catches up via
  polling. This belt-and-suspenders pattern is resilient to brief
  bridge outages. Cloud Run WebSocket lifetime cap (~60 minutes idle)
  is acceptable; clients reconnect transparently. Alternative
  considered and rejected: managed WebSocket service (Pusher / Ably) —
  adds a vendor in T&Cs without architectural benefit.

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
- Postgres `NOTIFY` → Cloud Pub/Sub → WebSocket bridge in the Cloud Run
  proxy backend (Lock 9 in `phase_11a_decision_register.md` Production
  Hardening Locks, fully specified):

  - **Topic naming**: `shared_state.{operator_id}.{table}` (one topic per
    operator-table pair; clients subscribe to operator-scoped topics
    only, never cross-operator).
  - **Message payload schema** (versioned for forward compatibility):
    ```json
    {
      "schema_version": 1,
      "operator_id": "uuid",
      "location_id": "uuid",
      "table": "weekly_plan_snapshots",
      "op": "INSERT" | "UPDATE" | "DELETE",
      "primary_key": "uuid_or_composite_string",
      "updated_at": "2026-04-26T12:34:56Z",
      "version": 47
    }
    ```
    Payload does NOT carry full row content; clients re-fetch the row
    via `/v1/...` proxy. Reasons: keeps Pub/Sub messages small;
    operator-scoped re-fetch goes through RLS so it's safe; handles
    schema changes without versioning the message body.
  - **Subscriber acks within 30s**; unprocessed messages route to
    `shared_state.deadletter` topic for later replay.
  - **WebSocket lifecycle**:
    - Cloud Run idle timeout: 60 minutes (cap); transparent client
      reconnect on close
    - Last-seen-sequence in client → server resends missed messages on
      reconnect from operator's recent NOTIFY history (up to 5 minutes
      retention in Pub/Sub message backlog)
    - Heartbeat ping every 30s
    - Server closes connection if heartbeat missed for 90s
    - Client falls back to 30-60s polling if WebSocket fails 3×
      consecutively within 5 minutes (circuit-breaker pattern matching
      Lock 7 LLM fallback shape)
  - Each WebSocket connection authenticates via Firebase JWT; proxy
    injects `(operator_id, location_id, staff_id NULL)` into the Pub/Sub
    subscription filter so the connection only receives operator-scoped
    events.
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

## Runtime Contract

```text
write path:
  client → proxy backend (/v1/...) → Azure DB Postgres (RLS-scoped by JWT)
  ↳ Postgres trigger sets updated_at server timestamp
  ↳ audit_trail row appended
  ↳ Postgres NOTIFY shared_state:<restaurant_id>:<table>, <payload>
  ↳ proxy LISTEN handler fans out to WebSocket subscribers for this
    restaurant_id
  ↳ local SQLite cache updated on write success

read path (hot):
  client → local SQLite cache (fast)

read path (cold / startup):
  client → proxy backend → Azure DB Postgres bulk query (RLS-scoped)
  ↳ hydrate SQLite cache

subscribe path:
  client → proxy WebSocket /v1/realtime?restaurant_id=...
  ↳ proxy authenticates Firebase JWT, registers LISTEN on relevant
    Postgres channels, fans out NOTIFY events to this connection
  ↳ client receives event with (restaurant_id, table, op, pk, updated_at):
     update SQLite cache (refetch row by pk)
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

## Dependencies

Required before Phase 10a can ship real:

- `Phase 9` auth identity and JWT integration with Postgres (RLS
  depends on Firebase JWT claims reaching Postgres via the proxy
  backend's session-variable injection)
- Azure DB Flexible Server (Postgres) instance provisioned (same
  instance as Phase 9, 9.5; provisioned in `11a.11c.6`)
- Postgres triggers + LISTEN/NOTIFY channels defined on shared-state
  tables; WebSocket bridge implemented in Cloud Run proxy backend
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
