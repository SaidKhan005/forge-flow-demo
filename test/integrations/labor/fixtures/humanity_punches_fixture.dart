// Phase 8.S.HM — Humanity (TCP) shift / punch fixtures.
//
// Documented per the Humanity v1 API at
// <https://platform.humanity.com/v1.0> retrieved 2026-05-04. The
// constant `documentedPerHumanityV10FieldMappingFixture` mirrors
// `documentedPerHumanityV10FieldMapping` in
// `lib/integrations/labor/humanity_labor_adapter.dart`; the test
// "field-mapping constant mirrors fixture" pins the two in sync.
//
// Live HTTP is the responsibility of `8.S.HM.live.sandbox` and
// `8.S.HM.live.prod`; this slice exercises every code path against
// these fixtures.

/// Field-mapping reference: vendor field path → canonical field +
/// transform. Mirrors `documentedPerHumanityV10FieldMapping` in the
/// adapter file.
const Map<String, Object?> documentedPerHumanityV10FieldMappingFixture =
    <String, Object?>{
  'api_version': 'v1.0',
  'shift_start': <String, Object?>{
    'path': 'shifts.in_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://platform.humanity.com/v1.0/shifts',
  },
  'shift_end': <String, Object?>{
    'path': 'shifts.out_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://platform.humanity.com/v1.0/shifts',
  },
  'role_name': <String, Object?>{
    'path': 'positions.name',
    'type': 'string',
    'transform': 'direct',
    'doc_url': 'https://platform.humanity.com/v1.0/positions',
  },
  'employee_id': <String, Object?>{
    'path': 'employees.id',
    'type': 'string_or_int',
    'transform': 'direct',
    'doc_url': 'https://platform.humanity.com/v1.0/employees',
  },
  'vendor_entity_id': <String, Object?>{
    'path': 'shifts.id',
    'type': 'string_or_int',
    'transform': 'direct',
    'doc_url': 'https://platform.humanity.com/v1.0/shifts',
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'shifts.updated',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://platform.humanity.com/v1.0/shifts',
  },
};

/// Sample test-connection shift shape. Numbers are deliberately
/// human-readable (employee 7777, position 'Server', clearly within
/// today's service period) so an operator running `testConnection`
/// from the admin widget can eyeball the result and confirm the
/// field mapping.
const Map<String, Object?> humanitySampleShift = <String, Object?>{
  'id': 'HUM-12345',
  'employee_id': 'EMP-7777',
  'position_name': 'Server',
  'in_time': '2026-05-04T16:00:00Z',
  'out_time': '2026-05-04T22:30:00Z',
  'updated': '2026-05-04T11:45:00Z',
  // FORBIDDEN — adapter MUST NOT persist these per privacy policy.
  // Recorded here so the canonicalizer's "persists only allowed
  // fields" behavior is testable.
  'employee_email': 'employee@example.com',
  'employee_phone': '+15551234567',
};

/// Backfill batch — 5 shifts walked across 2 pages (3 + 2). Each
/// row's `updated` strictly increases so the watermark advances
/// monotonically.
const List<Map<String, Object?>> humanityBackfillBatchPage1 =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 'HUM-9001',
    'employee_id': 'EMP-100',
    'position_name': 'Server',
    'in_time': '2026-05-01T16:00:00Z',
    'out_time': '2026-05-01T22:00:00Z',
    'updated': '2026-04-30T18:05:00Z',
  },
  <String, Object?>{
    'id': 'HUM-9002',
    'employee_id': 'EMP-101',
    'position_name': 'Cook',
    'in_time': '2026-05-01T11:00:00Z',
    'out_time': '2026-05-01T19:00:00Z',
    'updated': '2026-05-01T18:55:00Z',
  },
  <String, Object?>{
    'id': 'HUM-9003',
    'employee_id': 'EMP-102',
    'position_name': 'Bartender',
    'in_time': '2026-05-01T17:00:00Z',
    'out_time': '2026-05-02T01:00:00Z',
    'updated': '2026-05-01T19:25:00Z',
  },
];

const List<Map<String, Object?>> humanityBackfillBatchPage2 =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 'HUM-9004',
    'employee_id': 'EMP-103',
    'position_name': 'Host',
    'in_time': '2026-05-02T16:00:00Z',
    'out_time': '2026-05-02T22:00:00Z',
    'updated': '2026-05-02T18:10:00Z',
  },
  <String, Object?>{
    'id': 'HUM-9005',
    'employee_id': 'EMP-104',
    'position_name': 'Server',
    'in_time': '2026-05-02T17:00:00Z',
    'out_time': '2026-05-02T23:00:00Z',
    'updated': '2026-05-02T19:48:00Z',
  },
];

/// Future-dated row used to drive the framework's vendor timestamp
/// sanity guard (rule: opened_in_future).
const Map<String, Object?> humanityFutureDatedShift = <String, Object?>{
  'id': 'HUM-9999',
  'employee_id': 'EMP-999',
  'position_name': 'Server',
  // Reads as 60+ days into the future relative to `nowFixed` in the
  // adapter test harness.
  'in_time': '2026-07-15T16:00:00Z',
  'out_time': '2026-07-15T22:00:00Z',
  'updated': '2026-07-15T16:00:00Z',
};
