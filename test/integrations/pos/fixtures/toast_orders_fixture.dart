// Phase 8.TS — Toast orders fixture.
//
// Source: https://doc.toasttab.com/openapi/orders/orders-bulk-v2
// Retrieval date: 2026-05-03
// API version pinned: orders/v2 (Toast Standard / Partner API tier).
//
// Purpose: feed `ToastApiClient.fetchOrdersPage` and
// `ToastApiClient.fetchSampleOrder` from offline fixtures so the
// engineering slice (lifecycle = `documented`) can prove every
// framework call without a live HTTP call. The `*.live.sandbox`
// slice diffs observed sandbox responses against
// `documentedPerToastV2` (mirrored below) and treats discrepancies
// as bounded fixes, not slice rebuilds.
//
// V1 lean cut 2 boundaries:
//   * Forbidden fields (customer / cardholder / card_last4) are
//     excluded from the fixture. The adapter never reads them; the
//     fixture not carrying them protects test runs from accidentally
//     teaching the adapter a forbidden path.

import 'package:forge_and_flow/integrations/pos/toast_pos_adapter.dart';

/// Mirror of the constant in the adapter file. Repeated here so test
/// authors can read either file in isolation. The two MUST stay in
/// sync — diff-on-merge.
const Map<String, Object?> documentedPerToastV2Mirror = documentedPerToastV2;

/// Sample order produced by `ordersBulk` for the test-connection
/// modal. Hand-shaped per the documented Toast `orders/v2` schema:
///   - `numberOfGuests` is an int (covers source = direct).
///   - `openedDate` / `closedDate` / `modifiedDate` are ISO-8601 with
///     a trailing `Z` (UTC).
///   - `totalAmount` is a decimal-dollar Number.
const Map<String, Object?> toastSampleOrder = <String, Object?>{
  'guid': 'd1f9cd4a-4f4b-4d6e-9b7d-9a4f1f7c8e21',
  'restaurantGuid': '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
  'modifiedDate': '2026-05-04T19:55:00.000Z',
  'openedDate': '2026-05-04T18:30:00.000Z',
  'closedDate': '2026-05-04T19:55:00.000Z',
  'numberOfGuests': 4,
  'totalAmount': 87.20,
  'voided': false,
};

/// Page 1 of a backfill sequence. Three orders, all sane timestamps.
List<Map<String, Object?>> toastBackfillPage1Orders() {
  return <Map<String, Object?>>[
    <String, Object?>{
      'guid': 'p1-order-001',
      'restaurantGuid': '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'modifiedDate': '2026-05-04T18:35:00.000Z',
      'openedDate': '2026-05-04T18:00:00.000Z',
      'closedDate': '2026-05-04T18:35:00.000Z',
      'numberOfGuests': 2,
      'totalAmount': 41.50,
      'voided': false,
    },
    <String, Object?>{
      'guid': 'p1-order-002',
      'restaurantGuid': '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'modifiedDate': '2026-05-04T18:50:00.000Z',
      'openedDate': '2026-05-04T18:10:00.000Z',
      'closedDate': '2026-05-04T18:50:00.000Z',
      'numberOfGuests': 5,
      'totalAmount': 132.00,
      'voided': false,
    },
    <String, Object?>{
      'guid': 'p1-order-003',
      'restaurantGuid': '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'modifiedDate': '2026-05-04T19:05:00.000Z',
      'openedDate': '2026-05-04T18:25:00.000Z',
      'closedDate': '2026-05-04T19:05:00.000Z',
      'numberOfGuests': 3,
      'totalAmount': 64.75,
      'voided': false,
    },
  ];
}

/// Page 2 of a backfill sequence. Two orders. One trips the future-
/// dated sanity rule when the test fakes "now" earlier than the
/// fixture's `openedDate`; the other is sane and is expected to write.
List<Map<String, Object?>> toastBackfillPage2Orders() {
  return <Map<String, Object?>>[
    <String, Object?>{
      'guid': 'p2-order-future',
      'restaurantGuid': '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'modifiedDate': '2099-01-01T00:00:00.000Z',
      'openedDate': '2099-01-01T00:00:00.000Z',
      'closedDate': '2099-01-01T01:00:00.000Z',
      'numberOfGuests': 6,
      'totalAmount': 200.00,
      'voided': false,
    },
    <String, Object?>{
      'guid': 'p2-order-fine',
      'restaurantGuid': '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
      'modifiedDate': '2026-05-04T19:30:00.000Z',
      'openedDate': '2026-05-04T18:55:00.000Z',
      'closedDate': '2026-05-04T19:30:00.000Z',
      'numberOfGuests': 4,
      'totalAmount': 88.40,
      'voided': false,
    },
  ];
}
