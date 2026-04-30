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

## Frontend Exposure

Phase 8R follows the same transport-only discipline as Phase 8.
Operator-facing UX is the connect / configure / monitor flow for the
reservation vendor (OpenTable preferred). Detail surfaces (party-level,
VIP, comp tracking) explicitly wait for later auth-aware Barrio work
per the Scope above.

**Operator-facing surfaces this phase requires:**

- Settings → Integrations → Reservation connector card (extends the
  same `lib/screens/settings/settings_integrations_section.dart`
  established in Phase 8). One card per supported vendor (OpenTable
  first).
- Connect flow: vendor OAuth or API key entry, webhook URL display,
  "Test connection" button, connection-status indicator.
- Last-sync timestamp + last-error display per connector.
- COVERS card on Shift continues to render aggregate counts; gains
  freshness indicator pulled from connector status.

**Admin (11A) surfaces this phase requires:** reservation connector
admin covered by `11A.4` Integration management.

**UX sub-slice family:** `8R.UX.0`

- `8R.UX.0` — reservation connect flow + status panel + COVERS
  freshness indicator.

**Demo-mode walkthrough:**

- Launch app → Settings → Integrations → Reservation card → Connect
  → vendor sandbox auth → status "Connected" → Test connection →
  green toast → Shift COVERS card shows aggregate count + last-sync
  timestamp.
- Disconnect → status flips to "Not configured" → COVERS card shows
  fallback (demo or empty) with clear "Reservations not connected"
  copy.

Walkthrough evidence required at slice acceptance per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Source Material

The current demo/local foundation already defines the intended seam:

- [phase_7_56_reservation_book_signal_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_56/phase_7_56_reservation_book_signal_plan.md)
- [phase_7_55j_integration_feature_endpoint_inventory.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md)

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

