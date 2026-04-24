# Phase 10a - Shared Multi-Device State (V1)

Updated: 2026-04-23
Status: Planned, ready to build against the locked stack
Owner: Future shared-state lane

## Decisions Locked (2026-04-23 review)

- **Scope: V1, not V2.** Phase 10a ships shared-state infrastructure
  sufficient for single-operator launch with 2-3 manager devices online
  most of the time. Full offline sync with optimistic concurrency and
  complex conflict resolution is deferred to Phase 10b (post-launch).

- **Sequencing: pre-launch.** Phase 10a is pulled forward from H1 2028
  to the Jul-Sep 2026 sprint so Forge & Flow's manager multi-device use
  case works at Vanessa's restaurant launch (host stand tablet + office
  computer + phone on the floor). Starts mid-sprint after Phase 9 auth
  identity is usable.

- **Backend: Supabase Postgres with Row-Level Security.** Same Postgres
  project as Phase 9 (profiles, roles) and Phase 9.5 (leaderboard).
  Shared-state tables live under the `public` schema with RLS policies
  scoping every read/write by `restaurant_id` from the Firebase JWT
  claim.

- **Conflict resolution: last-write-wins (LWW) with audit trail.**
  Postgres server timestamps (`updated_at` set by trigger on every
  UPDATE) establish ordering. Writes never reject on concurrency; the
  later write overwrites. Audit trail captures every write with
  `written_by_uid`, `written_at`, and the prior value, so disputes are
  resolvable after the fact.

- **Real-time sync: Supabase Realtime + client polling fallback.**
  Primary channel is Supabase Realtime (Postgres LISTEN/NOTIFY over
  WebSockets) for sub-second cross-device propagation. Fallback channel
  is client-side polling every 30-60 seconds. If Realtime degrades or
  the connection drops, the client keeps working from cache and catches
  up via polling. This belt-and-suspenders pattern is resilient to
  brief Realtime outages.

- **Device-local SQLite stays as cache, not source of truth.** Reads
  served from local SQLite cache; writes route through Supabase
  Postgres first, then update local cache. On app startup, local cache
  hydrated from the latest Postgres state via one bulk sync call.

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

- Supabase Postgres schema for shared-state tables (under `public`
  schema or a dedicated `shared_state` schema)
- Row-Level Security (RLS) policies on every shared-state table,
  scoping by `restaurant_id` from JWT claims
- `updated_at` trigger on every table for LWW ordering
- Audit trail table (append-only) with mutation log
- Editable restaurant timing + service-period settings UI that writes
  through Postgres (supersedes the Settings-screen read-only timing
  display landed in `7.55o.4`)
- Client-side repository layer that:
  - reads local SQLite cache for fast display
  - writes through Supabase Postgres first, updates cache on success
  - subscribes to Supabase Realtime for push updates on shared-state
    table changes
  - falls back to polling every 30-60 seconds if Realtime degrades
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
  client → Supabase Postgres (RLS-scoped by JWT claim)
  ↳ Postgres trigger sets updated_at server timestamp
  ↳ audit_trail row appended
  ↳ Realtime broadcast to all subscribers for this restaurant_id
  ↳ local SQLite cache updated on write success

read path (hot):
  client → local SQLite cache (fast)

read path (cold / startup):
  client → Supabase Postgres bulk query (RLS-scoped)
  ↳ hydrate SQLite cache

subscribe path:
  client → Supabase Realtime WebSocket (per-table subscription)
  ↳ on UPDATE/INSERT/DELETE for this restaurant_id:
     update SQLite cache
     invalidate dependent read models

fallback path (if Realtime degrades):
  client polls Supabase Postgres every 30-60 seconds for updated_at
  changes since last poll
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
- Realtime is best-effort; the app must work correctly even if
  Realtime is offline for minutes

## Dependencies

Required before Phase 10a can ship real:

- `Phase 9` auth identity and JWT integration with Supabase (RLS
  depends on Firebase JWT claims reaching Postgres)
- Supabase Postgres project provisioned (same project as Phase 9, 9.5)
- Supabase Realtime enabled on shared-state tables
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
- The app must function correctly if Realtime is offline (polling
  fallback is the safety net, not the exception)
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

- [Supabase RLS + Firebase Auth third-party integration](https://supabase.com/docs/guides/auth/third-party/firebase-auth)
- [Supabase Realtime](https://supabase.com/docs/guides/realtime)
- [Multi-tenant PostgreSQL with RLS](https://www.wellally.tech/blog/postgres-multi-tenant-database-row-level-security) (industry pattern)
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
- Write path to Supabase Postgres (via the Phase 10a shared-state
  repository), respecting RLS scoping on `restaurant_id`.
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
- Realtime subscription granularity (per-table vs per-row filtering) to
  be decided during implementation spec pass
- Tracker folding: add to `PROJECT_TRACKER.md` Active Planning Docs list
  on next Codex pass
