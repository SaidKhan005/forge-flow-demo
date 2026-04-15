# Phase 10 - Shared Multi-Device Sync

Updated: 2026-04-14
Status: Planned
Owner: Future shared-state lane

## Goal

Add restaurant-scoped shared state across devices without confusing local
SQLite cache with the true multi-device source of truth.

## Scope

Phase 10 owns:

- shared multi-device restaurant state
- cross-device mutation propagation
- remote restaurant-scoped source of truth for settings/overrides/audit-style
  shared state
- outbound and inbound sync handling
- device-local SQLite as cache/offline store rather than the only authority

Phase 10 does not own:

- connector ingest of operational facts (`Phase 8` / `8R`)
- auth / roles / permissions (`Phase 9`)
- live daypart-aware Shift behavior (`Phase 10.5`)

## Runtime Contract

The intended shape is:

```text
shared restaurant authority
-> sync / mutation queue
-> device-local SQLite cache
-> app state / read models
-> UI
```

Phase 10 exists so the repo does not pretend:

- local SQLite alone is shared multi-device truth
- Phase 8 connector work automatically solves shared settings/override state

## Minimum Concepts

From the earlier planning notes, this phase likely needs concepts like:

- `restaurant_users`
- `restaurant_roles`
- `device_installations`
- `shared_mutations` or equivalent sync queue
- audit metadata such as `updated_by_user_id` and `updated_at`

## Boundaries

- operational source systems still answer "what happened"
- auth still answers "who is the user"
- Phase 10 answers "how do shared restaurant mutations stay consistent across devices"

## Source Material

The current repo does not yet have a standalone Phase 10 doc. This plan is
being split out from earlier archived references, especially:

- [phase_7_52_execution_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_7_52_execution_plan.md)
- [DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md)

