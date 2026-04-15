# Phase 8 - Live POS + Labor Adapters

Updated: 2026-04-14
Status: Planned, blocked on vendor selection
Owner: Future connector lane

## Goal

Replace replay/demo transport with official live POS and labor adapters without
rewriting the app's internal source-truth boundaries.

## Scope

Phase 8 owns:

- official POS adapter transport
- official labor adapter transport
- onboarding/config for the first live POS and labor vendors
- backfill + incremental sync strategy for POS and labor facts
- raw import records / sync watermarks / connector status plumbing where needed
- canonical mapping from vendor DTOs into the app-owned operational fact shape
- repository-backed current-state freshness and sync metadata

Phase 8 does not own:

- reservation transport (`Phase 8R`)
- auth, roles, or permissions (`Phase 9`)
- cross-device shared state (`Phase 10`)
- live daypart-aware Shift behavior (`Phase 10.5`)
- another internal architecture rewrite

## Runtime Contract

Phase 8 should follow the already-set app boundary:

```text
official POS + labor APIs
-> adapter DTOs
-> canonical operational facts
-> repositories / SQLite
-> app state / read models
-> UI
```

The rule is simple:

- Phase 8 replaces transport
- Phase 8 does not create a second UI-facing truth path

## Readiness / Blockers

The gate artifacts already document what must be true before connector work can
start:

- [README.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/README.md)
- [phase_8_readiness_signoff.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/phase_8_readiness_signoff.md)
- [vendor_live_data_capability_matrix.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/vendor_live_data_capability_matrix.md)
- [vendor_capability_profile_pos.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/vendor_capability_profile_pos.md)
- [vendor_capability_profile_labor.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/vendor_capability_profile_labor.md)
- [source_ownership_matrix.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/source_ownership_matrix.md)

Current blocker:

- first POS vendor selection is still TBD
- first labor vendor selection is still TBD

## Non-Negotiables

- one restaurant/location for the first live rollout
- official integrations only
- no vendor secrets in Flutter
- no screen-owned vendor logic
- no hidden fallback path that bypasses repositories/read services

## Adjacent Phases

- `Phase 8R` owns official reservation transport
- `Phase 9` owns identity and permissions
- `Phase 10` owns shared multi-device state, not connector ingest

