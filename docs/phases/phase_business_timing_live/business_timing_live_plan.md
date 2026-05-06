# Business Timing + Live Shift Implementation Plan

Status: implementation slice executed; live producer/proxy write paths still gated  
Owner: Codex  
Branch: `codex/business-timing-live`  
Worktree: `C:\Git Local Repos\forge_flow_demo\.codex_worktrees\business-timing-live`

## Product Goal

Forge & Flow needs one canonical business-timing system that every product
surface reads:

- Operator Console is the primary editor for business structure and timing.
- Admin Console is the support/internal editor with audited overrides.
- Mobile shows the resolved effective timing and uses it on Shift.
- Server-side Postgres is the source of truth.
- Mobile SQLite stores only the resolved effective timing and live snapshots it
  needs to render instantly.

The timing hierarchy is inherited downward:

```text
operator default -> org unit ancestors -> location
```

Lower scopes override higher scopes. A location override wins over a district,
district wins over region, and region wins over the operator default.

## Canonical Rules

1. Timing is operator-scoped and RLS-ready.
2. Every timing write is effective-dated.
3. Closed `ShiftRecord` rows are never re-bucketed silently.
4. A live open business day locks the timing profile it opened with unless an
   admin schedules a next-business-day effective change.
5. Location timezone is the final authority used by live bucketing. It may be
   seeded from a higher level, but the effective location timing must carry an
   IANA timezone before any live facts are bucketed.
6. Service period names are configurable.
7. An effective business day may have 1-4 service periods.
8. Service periods use 15-minute increments.
9. Service periods may not overlap on the same business date.
10. Gaps are allowed and render as `non_service`.
11. At most one service period may roll past midnight.
12. Business-day start may not fall inside a service period.

## Implementation Slices

### 1. Domain Contract

Add pure Dart models and validation/resolution:

- `BusinessTimingProfile`
- `BusinessTimingScope`
- `EffectiveBusinessTimingProfile`
- `BusinessTimingProfileResolver`

The resolver accepts candidate profiles already ordered from highest scope to
lowest scope and returns the effective profile by applying non-null lower-level
fields over inherited values. Service periods are a whole-set override: if a
lower profile defines any service periods, that set replaces inherited periods.

### 2. Postgres Source Of Truth

Add one canonical schema:

- `business_timing_profiles`
- `business_timing_service_periods`
- `business_timing_audit_events`
- `open_shift_snapshots`

The timing profile table stores scoped, effective-dated overrides. The service
period table stores the optional whole-set period override for a profile. The
audit table records operator/admin/system writes. The open snapshot table is
the server-side producer truth for the live Shift surface.

### 3. Server Repository + Resolver

Add a Postgres repository that:

- lists candidate timing profiles for a location
- resolves candidates using the domain resolver
- supports create/update through operator/admin paths
- writes audit events for mutations

Resolution order:

```text
operator default
-> matching org-unit ancestors ordered root to leaf
-> location override
```

### 4. Live Open-Shift Producer

Add an `OpenShiftSnapshotProjector` sibling to the closed-shift aggregator.
It reads canonical POS, labor, and reservation facts for the current business
date, buckets them through `DaypartBucketer`, and writes one open snapshot per
service period plus a whole-day rollup.

Producer rules:

- POS/reservation timestamps classify by effective service period.
- Labor punches split across periods; `non_service` minutes are excluded from
  per-period productivity.
- Every metric carries source/provenance state.
- Writes enqueue an `event_outbox` notification topic so mobile pulls through
  the proxy.
- The projection is provisional; closed `ShiftRecord` remains historical truth.

### 5. Proxy + Mobile Sync

Extend the proxy/mobile sync contract:

- fetch resolved timing config for a location
- fetch bounded pages of open shift snapshots
- persist the resolved timing read model into mobile SQLite
  `restaurant_timing_configs`
- persist server-produced open snapshots into mobile SQLite
  `open_shift_snapshots`
- fire `AppRuntimeInvalidationBus.notifyRuntimeWriteCompleted()`

Realtime remains a signal only. The phone always pulls durable truth through
the proxy.

### 6. Shift UX

Replace the current split “Whole Day / Daypart” feel with a unified selector:

```text
Whole Day | Lunch | Dinner | Late Night
```

Whole Day is the rollup. Each period uses the same card grammar and model
language as Whole Day. Active period chips render `ACTIVE NOW`; future periods
render projected/unavailable states without borrowing a closed driver.

### 7. Console UX

Operator Console:

- Business timing top-level page.
- Location timing tab.
- Inherited-from labels.
- Override/reset controls.
- Effective date picker.
- Service period editor with max 4 periods and no-overlap validation.

Admin Console:

- Same timing editor mounted from Operators -> Location row.
- Audit reason required for support/internal overrides.
- Read-only support role cannot mutate timing.

Mobile:

- Settings keeps a read-only effective timing summary.
- Shift consumes the resolved timing and period definitions.

### 8. Review Deployment And Acceptance

Local gates:

- targeted Dart tests for resolver, sync, and Shift selector behavior
- migration drift scanner
- migration cutoff lint
- analyzer

Review gates:

- deploy proxy/admin/operator web review revisions
- authenticate both consoles through Firebase
- test Admin timing surface in Browser Use
- test Operator timing surface in Browser Use
- install/run mobile on a connected device
- verify live/open snapshots refresh the Shift whole-day and period views
- record any missing cloud credentials or vendor-live proof as named follow-up

## Known Constraints

The closed-shift spine is already accepted. This plan must not change
`LaborModel.determineLever`, `ShiftFactBuilder`, or closed-history target
immutability. Live open snapshots are additive and provisional.

## Execution Evidence - 2026-05-06

Completed in this branch:

- Domain timing profile models and inheritance resolver.
- Postgres migration for timing profiles, service periods, audit events, and
  server-side `open_shift_snapshots`.
- Postgres repositories for timing profile writes/reads and open snapshot
  upserts/lists.
- Mobile sync contract extension for resolved timing configs and open shift
  snapshots.
- Shift screen unified selector: Whole Day plus configured service periods.
- Operator Console read surface for effective/inherited timing.
- Admin Console location-row timing dialog with non-destructive support copy.
- Migration cutoff/docs updates through
  `202605060000_phase_business_timing_live_schema.sql`.

Not completed in this branch:

- `OpenShiftSnapshotProjector` from live canonical vendor facts.
- Production proxy routes for resolved timing/open snapshot reads.
- Audited operator/admin timing write endpoints and live console edit forms.
- Cloud Run review deployment with the new migration applied.

Those remaining items are intentionally named because shipping the UI/schema
without the producer/proxy write path must not be described as a live vendor
feed.
