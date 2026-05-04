// Phase 8R.TC — Tock reservations fixture.
//
// Source: https://api.exploretock.com/docs/latest/reservation.html
// Retrieval date: 2026-05-04
// API version pinned: reservation_2026_05_03 (Tock public reservation
// reference; full Premium-tier developer surface gated to credentialed
// accounts).
//
// Purpose: feed `TockApiClient.fetchReservationsPage` and
// `TockApiClient.fetchSampleReservation` from offline fixtures so the
// engineering slice (lifecycle = `documented`) can prove every
// framework call without a live HTTP call. The `*.live.sandbox` slice
// diffs observed sandbox responses against
// `documentedPerTockReservation20260504` (mirrored below) and treats
// discrepancies as bounded fixes, not slice rebuilds.
//
// Per-transition timestamps (`arrived_at`, `seated_at`, `left_at`,
// `canceled_at`) are NOT included in any fixture: Tock's public
// reservation reference omits them, and the engineering slice ships
// without an assumption about their availability. The
// `*.live.sandbox` slice will diff observed payloads against this
// gap and add fields if present.
//
// V1 lean cut 2 boundaries:
//   * Forbidden fields (guest first/last name, email, phone, payment
//     instrument) are excluded from the fixture. The adapter never
//     reads them; the fixture not carrying them protects test runs
//     from accidentally teaching the adapter a forbidden path.

import 'package:forge_and_flow/integrations/reservation/tock_reservation_adapter.dart';

/// Mirror of the constant in the adapter file. Repeated here so test
/// authors can read either file in isolation. The two MUST stay in
/// sync — diff-on-merge.
const Map<String, Object?> documentedPerTockReservation20260504Mirror =
    documentedPerTockReservation20260504;

/// Sample reservation produced by `reservations/search` for the
/// test-connection modal. Hand-shaped per the documented Tock
/// reservation schema:
///   - `partySize` is an int (no covers field; party_size is the
///     reservation analog).
///   - `serviceDateTimestamp` / `createdTimestamp` /
///     `lastUpdatedTimestamp` are ISO-8601 with a trailing `Z` (UTC).
///   - `status` is one of EXPECTED / ARRIVED / SEATED / LEFT /
///     NO_SHOW / CANCELLED.
const Map<String, Object?> tockSampleReservation = <String, Object?>{
  'id': 'res_d1f9cd4a-4f4b-4d6e-9b7d-9a4f1f7c8e21',
  'businessId': 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
  'createdTimestamp': '2026-05-01T14:22:00.000Z',
  'lastUpdatedTimestamp': '2026-05-04T19:10:00.000Z',
  'serviceDateTimestamp': '2026-05-04T19:00:00.000Z',
  'partySize': 4,
  'status': 'SEATED',
};

/// Page 1 of a backfill sequence. Three reservations across the four
/// statuses we expect to see most often (EXPECTED / SEATED / LEFT).
List<Map<String, Object?>> tockBackfillPage1Reservations() {
  return <Map<String, Object?>>[
    <String, Object?>{
      'id': 'p1-res-001',
      'businessId': 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'createdTimestamp': '2026-05-01T10:00:00.000Z',
      'lastUpdatedTimestamp': '2026-05-04T18:35:00.000Z',
      'serviceDateTimestamp': '2026-05-04T18:30:00.000Z',
      'partySize': 2,
      'status': 'EXPECTED',
    },
    <String, Object?>{
      'id': 'p1-res-002',
      'businessId': 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'createdTimestamp': '2026-05-01T11:00:00.000Z',
      'lastUpdatedTimestamp': '2026-05-04T18:50:00.000Z',
      'serviceDateTimestamp': '2026-05-04T18:45:00.000Z',
      'partySize': 5,
      'status': 'SEATED',
    },
    <String, Object?>{
      'id': 'p1-res-003',
      'businessId': 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'createdTimestamp': '2026-05-01T12:00:00.000Z',
      'lastUpdatedTimestamp': '2026-05-04T19:05:00.000Z',
      'serviceDateTimestamp': '2026-05-04T19:00:00.000Z',
      'partySize': 3,
      'status': 'LEFT',
    },
  ];
}

/// Page 2 of a backfill sequence. Two reservations. One trips the
/// future-dated sanity rule when the test fakes "now" earlier than the
/// fixture's `serviceDateTimestamp`; the other is sane and is expected
/// to write.
List<Map<String, Object?>> tockBackfillPage2Reservations() {
  return <Map<String, Object?>>[
    <String, Object?>{
      'id': 'p2-res-future',
      'businessId': 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'createdTimestamp': '2099-01-01T00:00:00.000Z',
      'lastUpdatedTimestamp': '2099-01-01T00:00:00.000Z',
      'serviceDateTimestamp': '2099-01-01T01:00:00.000Z',
      'partySize': 6,
      'status': 'EXPECTED',
    },
    <String, Object?>{
      'id': 'p2-res-fine',
      'businessId': 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'createdTimestamp': '2026-05-01T13:00:00.000Z',
      'lastUpdatedTimestamp': '2026-05-04T19:30:00.000Z',
      'serviceDateTimestamp': '2026-05-04T19:25:00.000Z',
      'partySize': 4,
      'status': 'NO_SHOW',
    },
  ];
}
