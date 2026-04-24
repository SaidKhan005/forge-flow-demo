# Phase 8R - Official Reservation Connector

Updated: 2026-04-22
Status: Planned, blocked on vendor selection
Owner: Future reservation connector lane
Last review: 2026-04-22 - vendor TBD; working preference is OpenTable (aligns with Phase 7.56 demo signal and Barrio V1.1 Daily Board covers source). API access / partner status not yet secured.

## Goal

Replace the app-side reservation demo/cache path with an official reservation
platform connector that updates the same repository/read-model seam.

## Scope

Phase 8R owns:

- reservation vendor capability profile
- official reservation API transport
- reservation polling / webhook / event strategy
- reservation status mapping into app-owned statuses
- canonical reservation event/party mapping
- writes into `reservation_book_snapshots` and related app-owned cache state
- repository-backed freshness / staleness behavior for reservation data

Phase 8R does not own:

- POS or labor adapters (`Phase 8`)
- auth-aware guest/VIP detail surfaces (`Phase 9` and later Barrio work)
- cross-device shared state (`Phase 10`)
- labor math or benchmark logic

## Runtime Contract

The live reservation path should be:

```text
official reservation API
-> trusted connector / backend worker
-> canonical reservation parties/events
-> reservation book snapshots
-> local SQLite cache
-> ShiftDashboardReadModel
-> COVERS card / future reservation-aware surfaces
```

Forge & Flow should stay aggregate-first:

- `In the books` style aggregate counts in Forge & Flow
- party/VIP/detail surfaces wait for later auth-aware Barrio work

## Source Material

The current demo/local foundation already defines the intended seam:

- [phase_7_56_reservation_book_signal_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/7_56/phase_7_56_reservation_book_signal_plan.md)
- [phase_7_55j_integration_feature_endpoint_inventory.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md)

The `7.56` doc's "Future Phase 8R Scope" section is the direct precursor to
this lane.

## Capability Questions

Before implementation, the selected reservation platform must answer:

- official access path
- auth mode
- sandbox availability
- location mapping
- reservation list endpoint availability
- polling vs webhook support
- rate limits
- party size / status / time / timestamp availability
- status transition mapping
- timezone behavior
- source ownership and fallback rules

## Non-Negotiables

- official integrations only
- no scraping
- no vendor credentials in Flutter
- no mutation of covers/forecast math from widget code
- no guest-detail overreach in Forge & Flow

