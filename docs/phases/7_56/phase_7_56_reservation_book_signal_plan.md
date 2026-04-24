# Phase 7.56 - Reservation Book Signal Demo

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Planned

## Purpose

Add a small reservation-book signal to the Forge & Flow Shift screen without starting live vendor transport.

The immediate user-facing change is on the existing Shift COVERS card:

```text
COVERS
140
Forecast 220
In the books 72
-80  Light
```

`In the books` means unseated reservation covers remaining in the reservation book for the current open shift.

This phase is a demo/local app-side foundation. Official OpenTable or other reservation-platform integration belongs to a later `Phase 8R` connector lane after official platform access and a capability profile exist.

## Roadmap Placement

- `Phase 7.56` sits after Phase 7.55 release stabilization and before live vendor adapter work.
- It is not Phase 8 because it does not connect to a live reservation platform.
- It is not Phase 9.75 because it does not build the full Staff Daily Companion reservations, VIPs, daily board, or pre-shift briefing surfaces.
- It creates the app-owned model, persistence path, read-model field, and UI contract that later phases can reuse.
- Under the newer planning architecture:
  - reservation data remains contextual by default
  - if reservations later feed forecast demand, they should feed
    `DemandForecastContext`
  - published weekly plan truth should still flow through
    `WeeklyPlanSnapshot`, not around it

## Current Codebase Fit

The Shift screen already renders a COVERS card from repository-backed current-state:

```text
open_shift_snapshots
-> OpenShiftSnapshot
-> ShiftDashboardNotifier
-> ShiftDashboardReadModel
-> InputMetricCard
```

The new reservation signal should follow the same pattern:

```text
reservation_book_snapshots
-> ReservationBookSnapshotRepository
-> ShiftDashboardNotifier
-> ShiftDashboardReadModel.inTheBooksCovers
-> COVERS card support line
```

The feature must not reintroduce screen-owned demo truth.

## Definition Of "In The Books"

`In the books` is the sum of party sizes for reservation records attached to the current shift's restaurant, business date, and daypart where the party has not yet been seated.

Count these app-normalized statuses:

- `booked`
- `confirmed`
- `arrived`
- `waiting`

Do not count:

- `seated`
- `completed`
- `cancelled`
- `no_show`

Rationale:

- `currentCovers` means covers already flowing through the open shift snapshot.
- `forecastCovers` means the planning target for the shift.
- `inTheBooksCovers` means expected reserved covers that are still ahead of the floor.

These are related signals, but they are not interchangeable.

## Architecture Decisions

### 1. Official integrations only

All live reservation integrations must use official vendor access.

Do not implement:

- scraping
- browser automation against vendor portals
- storing shared restaurant login credentials in the Flutter app
- direct mobile calls that expose vendor API secrets
- unofficial reverse-engineered endpoints

The long-term live path must use a trusted backend, connector worker, Cloud Function, or equivalent server-side boundary for vendor credentials and API calls.

### 2. Generic app-owned domain model

Do not name app-domain models after OpenTable.

Use generic names such as:

- `ReservationBookSnapshot`
- `ReservationParty`
- `ReservationStatus`
- `ReservationBookRepository`

OpenTable, Resy, SevenRooms, Tock, Toast Tables, or any future provider should map into the same canonical reservation model.

### 3. Reservation data is not actual covers

`inTheBooksCovers` must not mutate:

- `OpenShiftSnapshot.currentCovers`
- `OpenShiftSnapshot.forecastCovers`
- `ClosedShiftInput.covers`
- `ShiftFact.covers`
- `ShiftRecord.covers`

The reservation book signal is an operational context line, not a source fact for historical shift truth.

### 4. No labor formula changes

This phase must not change:

- `LaborModel`
- CPLH or SPLH formulas
- PPA formulas
- dollar gap math
- OPZ logic
- primary lever thresholds
- forecast-vs-actual cover variance logic

The COVERS card may display `In the books`, but lever math continues to compare current/actual covers against forecast covers.

### 5. SQLite is a local cache/read model

For Phase 7.56, SQLite stores seeded demo reservation-book data.

For live integration later, SQLite remains a device-local cache/read model. It must not become the credential authority, permission authority, or official vendor system of record.

### 6. Source ownership remains explicit

Reservation platform owns reservation party status and party size when the official integration exposes those fields.

The app owns:

- daypart mapping
- status normalization
- aggregation into `inTheBooksCovers`
- Shift card display
- stale/missing-data behavior

Widgets must not decide source precedence. Any vendor-specific status or field mapping belongs below the repository/read-model boundary.

### 7. Missing data behavior

Phase 7.56 demo behavior:

- If a reservation book snapshot exists, show `In the books X`.
- If no snapshot exists, hide the line.

Later live behavior may show a stale/unavailable state if a reservation connector is configured but not current. That state should come from repository-backed sync metadata, not widget guesses.

### 8. Provenance and freshness are required

The reservation snapshot should retain:

- source system
- source location or shift id when available
- last vendor event time when available
- local updated timestamp

Future live connector work must use watermarks/import runs like the existing POS/labor adapter foundation.

### 9. Privacy and role boundaries

Phase 7.56 should display only aggregate counts on Forge & Flow.

Do not add guest names, phone numbers, notes, VIP labels, or party details to Forge & Flow in this phase.

Party details, VIPs, and reservation notes belong to later Barrio Staff Daily Companion surfaces and must be permission-aware after Phase 9 auth.

### 10. One restaurant/location scope

The current integration scope remains one restaurant/location. All records should still carry `restaurantId` so the feature stays aligned with future onboarding, sync, and multi-location growth.

## Proposed Phase 7.56 Data Model

Minimum domain model:

```dart
class ReservationBookSnapshot {
  final String restaurantId;
  final String businessDate;
  final String daypart;
  final int unseatedCovers;
  final int unseatedPartyCount;
  final String? sourceSystem;
  final String? sourceServiceId;
  final String? lastEventAt;
  final String updatedAt;
}
```

Minimum SQLite table:

```sql
CREATE TABLE reservation_book_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  restaurant_id TEXT NOT NULL,
  business_date TEXT NOT NULL,
  daypart TEXT NOT NULL,
  unseated_covers INTEGER NOT NULL,
  unseated_party_count INTEGER NOT NULL,
  source_system TEXT,
  source_service_id TEXT,
  last_event_at TEXT,
  updated_at TEXT NOT NULL,
  UNIQUE(restaurant_id, business_date, daypart)
)
```

Repository query needed by Shift:

```dart
Future<ReservationBookSnapshot?> getForShift(
  String restaurantId,
  String businessDate,
  String daypart,
);
```

## Prompt 7.56a Scope

In scope:

- Add `ReservationBookSnapshot` domain model.
- Add `ReservationBookSnapshotRepository` interface.
- Add SQLite DAO and repository implementation.
- Add `reservation_book_snapshots` table and migration.
- Seed demo data for the current open shift.
- Load the reservation snapshot in `ShiftDashboardNotifier`.
- Add optional `inTheBooksCovers` to `ShiftDashboardReadModel`.
- Render `In the books X` beneath the existing COVERS card forecast line.
- Add focused tests for persistence, read model, and Shift card rendering.

Out of scope:

- Live OpenTable API calls.
- Any other live reservation platform calls.
- Backend functions or API credentials.
- Guest names or reservation detail rows.
- Push notifications.
- Barrio Daily Companion screens.
- Auth, roles, permissions, or any remote backend (Supabase Postgres / Firebase Auth land in Phase 9).
- Changes to labor formulas or lever detection.

## Future Phase 8R Scope

### Prompt 8R.1 - Reservation Connector Capability Profile

Before live implementation, document the official reservation platform:

- vendor name
- official access path
- auth mode
- sandbox availability
- location mapping
- reservation list endpoint availability
- live status update mechanism
- polling or webhook support
- rate limits
- field availability for party size, status, time, guest name, notes, tags, and VIP markers
- status mapping into app statuses
- timestamp and timezone behavior
- source ownership and fallback behavior

### Prompt 8R.2 - Official Reservation Connector

Once official access exists:

```text
official reservation API
-> trusted backend or connector worker
-> raw import records
-> canonical reservation parties/events
-> reservation book snapshots
-> local SQLite cache
-> ShiftDashboardReadModel
-> COVERS card
```

The live connector should update the same cache and read-model field created in Phase 7.56.

## Verification Plan

Phase 7.56 should pass:

- `flutter test test/reservation_book_snapshot_repository_test.dart`
- `flutter test test/shift_dashboard_notifier_test.dart`
- `flutter test test/shift_visual_widget_test.dart`
- `flutter test`

Specific assertions:

- seeded demo reservation snapshot exists for the current open shift
- `getForShift` returns the expected unseated cover count
- `ShiftDashboardReadModel` includes the expected `inTheBooksCovers`
- COVERS card renders `In the books X`
- COVERS card hides the line when no snapshot exists
- primary lever and labor math remain unchanged

## Open Questions

- Should the first demo value be a fixed seeded count or assembled from seeded reservation parties?
- Should Phase 7.56 include a detail-ready canonical `ReservationParty`, or wait until Phase 8R?
- Should future Forge & Flow continue showing only aggregate counts while Barrio owns party/VIP detail?
- Should stale reservation sync produce a visible Shift warning once the live connector exists?

## Non-Negotiables

- Official integrations only.
- Generic app-owned reservation models only.
- No vendor credentials in Flutter.
- No screen-owned demo constants.
- No mutation of actual covers or forecast covers.
- No changes to labor math.
- Aggregate-only display in Forge & Flow for Phase 7.56.
- Party/VIP detail waits for auth-aware Barrio surfaces.
