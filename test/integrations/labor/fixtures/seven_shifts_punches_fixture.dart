// Phase 8.S.7S — 7shifts time-punch fixtures.
//
// Documented per https://developers.7shifts.com (retrieved
// 2026-05-04). Field shapes mirror the v2 reference for time_punches,
// roles, users, and payroll_periods. Every field-mapping assumption
// is flagged `verify_in_live_sandbox: true` so the
// `8.S.7S.live.sandbox` slice can diff observed responses against this
// constant. Mismatches become bounded fixes per
// `docs/contracts/vendor_adapter_slice_contract.md`.
//
// `documentedPerSevenShiftsV2FieldMappingFixture` mirrors the
// `documentedPerSevenShiftsV2FieldMapping` constant in
// `lib/integrations/labor/seven_shifts_labor_adapter.dart`; the test
// asserts the constants stay in sync.

/// Field-mapping reference: vendor field path → canonical field +
/// transform. Mirrors `documentedPerSevenShiftsV2FieldMapping` in the
/// adapter file. Every row carries `verify_in_live_sandbox: true`.
const Map<String, Object?> documentedPerSevenShiftsV2FieldMappingFixture =
    <String, Object?>{
  'api_version': 'v2-2026-05-04',
  'shift_start': <String, Object?>{
    'path': 'time_punch.clocked_in',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
  },
  'shift_end': <String, Object?>{
    'path': 'time_punch.clocked_out',
    'type': 'iso8601_utc_or_null',
    'transform': 'direct_utc_when_not_null',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
  },
  'role_name': <String, Object?>{
    'path': 'time_punch.role.name',
    'type': 'string',
    'transform': 'lowercase',
    'doc_url': 'https://developers.7shifts.com/reference/listroles',
    'verify_in_live_sandbox': true,
  },
  'employee_id': <String, Object?>{
    'path': 'time_punch.user_id',
    'type': 'int',
    'transform': 'to_string',
    'doc_url': 'https://developers.7shifts.com/reference/listusers',
    'verify_in_live_sandbox': true,
  },
  'vendor_entity_id': <String, Object?>{
    'path': 'time_punch.id',
    'type': 'int',
    'transform': 'to_string',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'time_punch.modified',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
  },
  'is_approved': <String, Object?>{
    'path': 'time_punch.approved',
    'type': 'bool',
    'transform': 'direct',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
  },
  'payroll_period_closed_at': <String, Object?>{
    'path': 'payroll_period.closed_at',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developers.7shifts.com/reference/listpayrollperiods',
    'verify_in_live_sandbox': true,
  },
  // 8.spine-bridge.7S.upgrade (2026-05-05) — Hours & Wages report
  // additions. Mirror of the new rows in
  // `documentedPerSevenShiftsV2FieldMapping` so the *.live.sandbox
  // diff stays bi-directional (per the walkthrough's "mirror"
  // trace-summary line).
  'shift_id': <String, Object?>{
    'path': 'time_punch.shift_id',
    'type': 'int',
    'transform': 'to_string',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
  },
  'actual_labor_dollars': <String, Object?>{
    'path': 'reports.hours_and_wages.total_pay',
    'type': 'decimal',
    'transform': 'direct',
    'doc_url':
        'https://developers.7shifts.com/reference/get_reports-hours-and-wages',
    'verify_in_live_sandbox': true,
  },
  'regular_pay': <String, Object?>{
    'path': 'reports.hours_and_wages.regular_pay',
    'type': 'decimal',
    'transform': 'direct',
    'doc_url':
        'https://developers.7shifts.com/reference/get_reports-hours-and-wages',
    'verify_in_live_sandbox': true,
  },
  'overtime_pay': <String, Object?>{
    'path': 'reports.hours_and_wages.overtime_pay',
    'type': 'decimal',
    'transform': 'direct',
    'doc_url':
        'https://developers.7shifts.com/reference/get_reports-hours-and-wages',
    'verify_in_live_sandbox': true,
  },
};

/// Sample test-connection time punch. Numbers are deliberately
/// human-readable (role 'server', is_approved true, clocked_in/out an
/// hour apart) so an operator running `testConnection` from the admin
/// widget can eyeball the result and confirm the field mapping.
const Map<String, Object?> sevenShiftsSamplePunch = <String, Object?>{
  'id': 712001,
  'user_id': 99001,
  'role': <String, Object?>{
    'id': 401,
    'name': 'Server',
  },
  'clocked_in': '2026-05-03T18:30:00Z',
  'clocked_out': '2026-05-03T23:45:00Z',
  'approved': true,
  'modified': '2026-05-04T00:05:00Z',
  // FORBIDDEN — adapter MUST NOT persist these fields per privacy
  // policy. Recorded here so the test can assert they are dropped.
  'user': <String, Object?>{
    'email': 'employee@example.com',
    'phone': '+15551234567',
    'dob': '1990-01-01',
  },
};

/// A short backfill batch returned by the time-punch endpoint. Five
/// punches walked across 2 pages (3 + 2). Each row's `modified`
/// strictly increases.
const List<Map<String, Object?>> sevenShiftsBackfillBatchPage1 =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 712101,
    'user_id': 99001,
    'role': <String, Object?>{'id': 401, 'name': 'Server'},
    'clocked_in': '2026-04-30T18:00:00Z',
    'clocked_out': '2026-04-30T23:30:00Z',
    'approved': true,
    'modified': '2026-04-30T23:35:00Z',
  },
  <String, Object?>{
    'id': 712102,
    'user_id': 99002,
    'role': <String, Object?>{'id': 402, 'name': 'Bartender'},
    'clocked_in': '2026-05-01T17:00:00Z',
    'clocked_out': '2026-05-01T22:30:00Z',
    'approved': true,
    'modified': '2026-05-01T22:32:00Z',
  },
  <String, Object?>{
    'id': 712103,
    'user_id': 99003,
    'role': <String, Object?>{'id': 403, 'name': 'Line Cook'},
    'clocked_in': '2026-05-01T15:00:00Z',
    'clocked_out': '2026-05-01T22:00:00Z',
    // Not yet approved — `approved` stays `false` until manager
    // signs off in the 7shifts portal.
    'approved': false,
    'modified': '2026-05-01T22:05:00Z',
  },
];

const List<Map<String, Object?>> sevenShiftsBackfillBatchPage2 =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 712104,
    'user_id': 99001,
    'role': <String, Object?>{'id': 401, 'name': 'Server'},
    'clocked_in': '2026-05-02T18:30:00Z',
    'clocked_out': '2026-05-02T23:45:00Z',
    'approved': true,
    'modified': '2026-05-02T23:50:00Z',
  },
  <String, Object?>{
    'id': 712105,
    'user_id': 99002,
    'role': <String, Object?>{'id': 402, 'name': 'Bartender'},
    'clocked_in': '2026-05-02T17:00:00Z',
    // Open punch — operator forgot to clock out; canonical fact
    // stores null shift_end and the next poll re-emits the row when
    // it closes.
    'clocked_out': null,
    'approved': false,
    'modified': '2026-05-02T17:01:00Z',
  },
];

/// Future-dated punch used to trigger the framework's vendor
/// timestamp sanity guard (rule: `opened_in_future`).
const Map<String, Object?> sevenShiftsFutureDatedPunch = <String, Object?>{
  'id': 799999,
  'user_id': 99001,
  'role': <String, Object?>{'id': 401, 'name': 'Server'},
  // Reads as ~2 months into the future relative to `nowFixed` in the
  // adapter test harness.
  'clocked_in': '2026-07-15T12:00:00Z',
  'clocked_out': '2026-07-15T18:00:00Z',
  'approved': false,
  'modified': '2026-07-15T18:00:01Z',
};

/// Latest closed payroll period returned by
/// `GET /v2/company/{company_id}/payroll_periods?status=closed`.
final DateTime sevenShiftsLatestPayrollPeriodClosedAt =
    DateTime.utc(2026, 5, 3, 8, 0, 0);
