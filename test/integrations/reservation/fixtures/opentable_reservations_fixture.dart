// Phase 8R.OT — OpenTable reservation fixtures.
//
// Documented per the OpenTable Partner page (operator-facing only:
// https://restaurant.opentable.com/products/opentable-platform/) and
// the industry-standard reservation envelope F&F adopts as the
// engineering target until partnership clears. Retrieval date:
// 2026-05-04. EVERY field-mapping assumption is flagged
// `verify_in_live_sandbox: true` so the `8R.OT.live.sandbox` slice
// can diff observed responses against this constant. Mismatches
// become bounded fixes, not slice rebuilds, per
// `docs/contracts/vendor_adapter_slice_contract.md`.
//
// The constant [documentedPerOpentableV1FieldMappingFixture] mirrors
// `lib/integrations/reservation/opentable_reservation_adapter.dart`
// `documentedPerOpentableV1FieldMapping`; the test asserts the
// constants stay in sync.

/// Field-mapping reference: vendor field path → canonical field +
/// transform. Mirrors `documentedPerOpentableV1FieldMapping` in the
/// adapter file. Every row carries `verify_in_live_sandbox: true`.
const Map<String, Object?> documentedPerOpentableV1FieldMappingFixture =
    <String, Object?>{
  'api_version': 'partner-v1-2026-05-04-assumed',
  'reservation_at': <String, Object?>{
    'path': 'reservation.reserved_at',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
  },
  'party_size': <String, Object?>{
    'path': 'reservation.party_size',
    'type': 'int',
    'transform': 'direct',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
  },
  'status': <String, Object?>{
    'path': 'reservation.status',
    'type': 'enum_string',
    'transform': 'normalize_to_app_reservation_status',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
  },
  'vendor_entity_id': <String, Object?>{
    'path': 'reservation.id',
    'type': 'string',
    'transform': 'direct',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'reservation.modified_at',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
  },
};

/// Sample test-connection reservation shape. Numbers are deliberately
/// human-readable (party_size=4, status=booked, reserved_at clearly in
/// the future) so an operator running `testConnection` from the admin
/// widget can eyeball the result and confirm the field mapping.
const Map<String, Object?> openTableSampleReservation = <String, Object?>{
  'id': 'OT-12345',
  'restaurant_id': 'rid-9876',
  'reserved_at': '2026-05-10T19:30:00Z',
  'modified_at': '2026-05-04T11:45:00Z',
  'party_size': 4,
  'status': 'booked',
  'guest': <String, Object?>{
    // FORBIDDEN — adapter MUST NOT persist these fields per
    // privacy policy. Recorded here so the test can assert they are
    // dropped.
    'name': 'Guest Name (forbidden)',
    'email': 'guest@example.com',
    'phone': '+15551234567',
  },
};

/// A short backfill batch returned by the search endpoint. Five
/// reservations, walked across 2 pages (3 + 2). Each row's
/// `modified_at` strictly increases.
const List<Map<String, Object?>> openTableBackfillBatchPage1 =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 'OT-9001',
    'restaurant_id': 'rid-9876',
    'reserved_at': '2026-05-05T18:30:00Z',
    'modified_at': '2026-04-30T18:05:00Z',
    'party_size': 2,
    'status': 'booked',
  },
  <String, Object?>{
    'id': 'OT-9002',
    'restaurant_id': 'rid-9876',
    'reserved_at': '2026-05-05T19:00:00Z',
    'modified_at': '2026-05-01T18:55:00Z',
    'party_size': 4,
    'status': 'seated',
  },
  <String, Object?>{
    'id': 'OT-9003',
    'restaurant_id': 'rid-9876',
    'reserved_at': '2026-05-05T19:30:00Z',
    'modified_at': '2026-05-01T19:25:00Z',
    'party_size': 3,
    'status': 'completed',
  },
];

const List<Map<String, Object?>> openTableBackfillBatchPage2 =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 'OT-9004',
    'restaurant_id': 'rid-9876',
    'reserved_at': '2026-05-06T18:00:00Z',
    'modified_at': '2026-05-02T18:10:00Z',
    'party_size': 2,
    'status': 'cancelled',
  },
  <String, Object?>{
    'id': 'OT-9005',
    'restaurant_id': 'rid-9876',
    'reserved_at': '2026-05-06T19:45:00Z',
    'modified_at': '2026-05-02T19:48:00Z',
    'party_size': 6,
    'status': 'no_show',
  },
];

/// Future-dated row used to trigger the framework's vendor timestamp
/// sanity guard (rule: opened_in_future).
const Map<String, Object?> openTableFutureDatedReservation = <String, Object?>{
  'id': 'OT-9999',
  'restaurant_id': 'rid-9876',
  // Reads as 60 days into the future relative to `nowFixed` in the
  // adapter test harness.
  'reserved_at': '2026-07-15T12:00:00Z',
  'modified_at': '2026-07-15T12:00:00Z',
  'party_size': 2,
  'status': 'booked',
};
