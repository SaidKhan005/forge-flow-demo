// Phase 8.AL — Aloha (NCR Voyix) checks fixture.
//
// Source: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
// Retrieval date: 2026-05-04
// API version pinned: aloha-v1-2026-05 (NCR Voyix Developer Program —
// Aloha module, per-API access request gated for production).
//
// Purpose: feed `AlohaNcrVoyixApiClient.fetchChecksPage` and
// `AlohaNcrVoyixApiClient.fetchSampleCheck` from offline fixtures so
// the engineering slice (lifecycle = `documented`) can prove every
// framework call without a live HTTP call. The `8.AL.live.sandbox`
// slice diffs observed sandbox responses against
// `documentedPerAlohaNcrVoyixV1` (mirrored below) and treats
// discrepancies as bounded fixes, not slice rebuilds.
//
// V1 lean cut 2 boundaries:
//   * Forbidden fields (guest / cardholder / card_last4) are excluded
//     from the fixture. The adapter never reads them; the fixture not
//     carrying them protects test runs from accidentally teaching the
//     adapter a forbidden path.

import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_adapter.dart';

/// Mirror of the constant in the adapter file. Repeated here so test
/// authors can read either file in isolation. The two MUST stay in
/// sync — diff-on-merge.
const Map<String, Object?> documentedPerAlohaNcrVoyixV1Mirror =
    documentedPerAlohaNcrVoyixV1;

/// Sample Aloha check produced by the documented checks endpoint for
/// the test-connection modal. Hand-shaped per the documented
/// `aloha-v1-2026-05` schema:
///   - `numberOfGuests` is an int (covers source = direct).
///   - `openedAt` / `closedAt` / `modifiedAt` are ISO-8601 with a
///     trailing `Z` (UTC).
///   - `totalAmount` is a decimal-dollar Number.
///   - `checkId` is a stable string id (Aloha `checkId`).
const Map<String, Object?> alohaNcrVoyixSampleCheck = <String, Object?>{
  'checkId': 'chk-2026-05-04-001',
  'siteId': 'site-aloha-001',
  'modifiedAt': '2026-05-04T19:55:00.000Z',
  'openedAt': '2026-05-04T18:30:00.000Z',
  'closedAt': '2026-05-04T19:55:00.000Z',
  'numberOfGuests': 4,
  'totalAmount': 87.20,
  'voided': false,
};

/// Page 1 of a backfill sequence. Three checks, all sane timestamps.
List<Map<String, Object?>> alohaNcrVoyixBackfillPage1Checks() {
  return <Map<String, Object?>>[
    <String, Object?>{
      'checkId': 'p1-check-001',
      'siteId': 'site-aloha-001',
      'modifiedAt': '2026-05-04T18:35:00.000Z',
      'openedAt': '2026-05-04T18:00:00.000Z',
      'closedAt': '2026-05-04T18:35:00.000Z',
      'numberOfGuests': 2,
      'totalAmount': 41.50,
      'voided': false,
    },
    <String, Object?>{
      'checkId': 'p1-check-002',
      'siteId': 'site-aloha-001',
      'modifiedAt': '2026-05-04T18:50:00.000Z',
      'openedAt': '2026-05-04T18:10:00.000Z',
      'closedAt': '2026-05-04T18:50:00.000Z',
      'numberOfGuests': 5,
      'totalAmount': 132.00,
      'voided': false,
    },
    <String, Object?>{
      'checkId': 'p1-check-003',
      'siteId': 'site-aloha-001',
      'modifiedAt': '2026-05-04T19:05:00.000Z',
      'openedAt': '2026-05-04T18:25:00.000Z',
      'closedAt': '2026-05-04T19:05:00.000Z',
      'numberOfGuests': 3,
      'totalAmount': 64.75,
      'voided': false,
    },
  ];
}

/// Page 2 of a backfill sequence. Two checks. One trips the future-
/// dated sanity rule when the test fakes "now" earlier than the
/// fixture's `openedAt`; the other is sane and is expected to write.
List<Map<String, Object?>> alohaNcrVoyixBackfillPage2Checks() {
  return <Map<String, Object?>>[
    <String, Object?>{
      'checkId': 'p2-check-future',
      'siteId': 'site-aloha-001',
      'modifiedAt': '2099-01-01T00:00:00.000Z',
      'openedAt': '2099-01-01T00:00:00.000Z',
      'closedAt': '2099-01-01T01:00:00.000Z',
      'numberOfGuests': 6,
      'totalAmount': 200.00,
      'voided': false,
    },
    <String, Object?>{
      'checkId': 'p2-check-fine',
      'siteId': 'site-aloha-001',
      'modifiedAt': '2026-05-04T19:30:00.000Z',
      'openedAt': '2026-05-04T18:55:00.000Z',
      'closedAt': '2026-05-04T19:30:00.000Z',
      'numberOfGuests': 4,
      'totalAmount': 88.40,
      'voided': false,
    },
  ];
}
