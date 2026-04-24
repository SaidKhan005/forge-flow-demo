# Phase 8 - Live POS + Labor Adapters

Updated: 2026-04-22
Status: Planned, blocked on vendor selection
Owner: Future connector lane
Last review: 2026-04-22 - POS and Labor vendors both still TBD; unblocks this phase

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

## Timezone Conversion Acceptance Criteria (handoff from 7.55r audit, 2026-04-24)

The 7.55r foundation-closeout audit surfaced that central timezone
conversion belongs in Phase 8 rather than in any current cleanup lane,
because the converter's interface shape is only knowable when a real
vendor adapter lands. Phase 7.55r deliberately did **not** pre-build a
converter — the pressure-test output is instead captured here as
binding acceptance criteria for the adapter work this phase owns.

### Architectural constraint (not negotiable)

- **Use an IANA-backed timezone library (e.g. `package:timezone`).**
  A fixed-offset calculation will silently mis-bucket DST fall-back
  timestamps twice a year. IANA-backed conversion disambiguates
  correctly.
- The adapter layer must interpret every vendor timestamp in the
  restaurant's configured `businessTimezone` (from
  `RestaurantTimingConfig`) before any business-date decision is made.
  `BusinessDateResolver` — the existing resolver — expects
  pre-converted restaurant-local time; the adapter boundary is where
  that conversion must live.
- The restaurant timezone is the authority. The device clock is never
  the source of truth for business boundaries.

### Scenarios A–F — binding test cases

These are acceptance tests the first real adapter must pass before it
can ship. Each represents a real-world class of vendor-timestamp
ambiguity that will silently corrupt business-date attribution if
handled naively:

- **Scenario A — Pacific restaurant, 4 AM business-day cutoff.**
  Vendor emits `2025-01-01T10:30:00Z` (UTC). Restaurant tz is
  `America/Los_Angeles`, business-day start `04:00`. Expected
  `businessDate = 2024-12-31` (the 02:30 PT ticket is before the 4 AM
  local cut, so it belongs to Dec 31's business day). Naive
  UTC-bucketing gives `Jan 1` — wrong.
- **Scenario B — late-night ticket spanning midnight.** Dinner ticket
  opens 23:55 ET, closes 00:15 ET. With business-day start `04:00`
  local, both events belong to the prior business date. Test both
  open and close timestamps resolve to the same business date.
- **Scenario C — DST fall-back ambiguity.** Vendor emits
  `2025-11-02T05:30:00Z` and `2025-11-02T06:30:00Z`. Both convert to
  `01:30 local` in `America/New_York` (DST fall-back day). An IANA
  library must disambiguate; a fixed-offset calc cannot. Test that
  both timestamps resolve to distinct wall-clock instants and the
  correct business date. **This is the reason IANA is mandatory.**
- **Scenario D — multi-location chain (e.g. Toronto + Vancouver).**
  Two locations served by the same app instance with different
  timezones. Test that "today's covers" for each resolves against
  the location's own timezone, not the operator's device clock.
- **Scenario E — ambiguous vendor timestamp (no tz info).** Vendor
  emits `2025-01-01T02:30:00` with no `Z` suffix and no offset.
  Adapter must declare the vendor's convention explicitly (document
  per integration) — treat as UTC, treat as location-local, or
  reject as malformed. Each vendor adapter picks one and documents
  it; the framework must make the choice visible, not implicit.
- **Scenario F — historical replay / pre-DST-policy-change
  timestamps.** Replay data from a year when DST rules differed
  (some regions have abolished DST since). IANA's historical offset
  database is the only reliable source; test that replay of a 2022
  timestamp uses 2022's tz rules, not today's.

### Implementation expectations

- Converter lives at the adapter boundary, not in screens or read
  services. `BusinessDateResolver` stays as-is (it already expects
  pre-converted local timestamps).
- The converter's interface is designed against the first real
  adapter's DTO shape, not guessed at ahead of time. Vendor-specific
  input types are explicit (ISO string, epoch ms, ambiguous local
  string, etc.) and each adapter declares which it produces.
- Scenarios A–F become named test cases in the first adapter's test
  suite. Cannot ship without all six green.

### Source material

- `docs/contracts/phase_7_55_time_boundary_contract.md` — the
  business-date authority contract the converter must serve.
- `lib/data/business_date_authority_service.dart` — existing
  resolver that consumes the post-conversion local timestamp.
- `lib/domain/models/restaurant_timing_config.dart` — the
  `businessTimezone` field the converter reads from.

## Adjacent Phases

- `Phase 8R` owns official reservation transport
- `Phase 9` owns identity and permissions
- `Phase 10` owns shared multi-device state, not connector ingest

