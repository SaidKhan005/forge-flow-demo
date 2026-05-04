// Phase 8.S / Wave B — QuickBooks Time labor adapter fixtures.
//
// Source documentation: https://tsheetsteam.github.io/api_docs/
// Retrieval date: 2026-05-04
// API version pinned: v1 (QuickBooks Time / TSheets developer API,
// post-Intuit-rebrand brand)
//
// The `documented_per_quickbooks_time_v1` constant captures every
// documented assumption the engineering slice makes about the vendor
// field shape. The `8.S.QBT.live.sandbox` slice diffs observed vendor
// responses against this constant; any discrepancy lands as a bounded
// fix (not a slice rebuild) per
// `docs/contracts/vendor_adapter_slice_contract.md`.

/// Field-mapping reference captured from the QuickBooks Time
/// developer API documentation as of 2026-05-04. Mirrors the constant
/// of the same name in
/// `lib/integrations/labor/quickbooks_time_labor_adapter.dart`; the
/// adapter test asserts the constants stay in sync.
///
/// The snake_case name follows the
/// `documented_per_<vendor>_<api_version>` shape mandated by
/// `docs/contracts/per_vendor_doc_pack_contract.md`; the lint
/// directive below suppresses the lowerCamelCase rule for this
/// contract-bound name only.
// ignore: constant_identifier_names
const Map<String, Object?> documented_per_quickbooks_time_v1 =
    <String, Object?>{
  'api_version': 'v1 (QuickBooks Time / TSheets developer API; '
      'Intuit-rebranded brand)',
  'shift_start_path': 'timesheets[].start',
  'shift_start_type': 'ISO 8601 with explicit Z (UTC)',
  'shift_end_path': 'timesheets[].end',
  'shift_end_type': 'ISO 8601 with explicit Z (UTC); empty string '
      'when timesheet is open (employee still clocked in)',
  'role_name_path': 'jobcodes[].name (joined to timesheets[].jobcode_id)',
  'role_name_type': 'string',
  'employee_id_path': 'users[].id (joined to timesheets[].user_id)',
  'employee_id_type': 'int (stringified at canonical write)',
  'vendor_entity_id_path': 'timesheets[].id',
  'vendor_entity_id_type': 'int (stringified at canonical write)',
  'vendor_modified_at_path': 'timesheets[].last_modified',
  'vendor_modified_at_type': 'ISO 8601 with explicit Z (UTC)',
  'pay_rate_path': 'users[].pay_rate (when exposed by vendor; per '
      '`oauth_shape.md` requires pay-rate scope)',
  'pay_rate_type': 'decimal string (USD/local currency per user prefs)',
  'covers_source_classification': 'not_applicable',
  'pagination_shape': 'page-numbered (?page=N) with `more` boolean '
      'flag in `results.more`',
  'rate_limit': '~20 requests/sec per account (vendor-documented '
      'soft cap)',
  'webhook_support': 'pollOnly (F&F doctrine: vendor docs do not '
      'expose a webhook delivery surface usable for schedule/punch '
      'changes; adapter polls every 5 minutes per phase 8.S plan)',
  'auth_mode': 'oauth (authorization_code grant via Intuit OAuth 2.0; '
      'public self-serve at developer.intuit.com)',
  'grant_scope': 'operatorWide (one Intuit OAuth realm covers all of '
      'the operator\'s QBT locations; F&F maps each vendor location to '
      'one F&F location_id at connect time)',
  'partnership_program': 'n/a — public Intuit OAuth, no partnership '
      'required',
  'partnership_lead_time': 'n/a',
  'forbidden_employee_ssn_path': 'users[].ssn (vendor exposes; F&F '
      'never reads or persists)',
  'forbidden_employee_full_address_path': 'users[].address (location '
      'home address — privacy)',
  'forbidden_employee_phone_path': 'users[].mobile_number',
  'module_disambiguation_supported': 'time | accounting | payroll',
  'module_supported_by_this_adapter': 'time',
  'module_accounting_redirect_to': 'Phase 8.5 outbound integrations '
      '(QuickBooks Online Accounting)',
  'module_payroll_action': 'refused (standalone Payroll not supported)',
};

/// One representative QBT `timesheets[]` record used by the
/// `testConnection` and idempotency / sanity / watermark tests. The
/// values are deliberately human-readable: `shift_start =
/// 2026-05-04T11:00:00Z`, `shift_end = 2026-05-04T19:30:00Z`,
/// `role_name = 'server'` so an operator running `testConnection`
/// from the admin widget can eyeball the result and confirm field
/// mapping.
const Map<String, Object?> sampleQuickBooksTimePunch = <String, Object?>{
  'id': 901001,
  'user_id': 8001,
  'jobcode_id': 5001,
  'role_name': 'server',
  'start': '2026-05-04T11:00:00Z',
  'end': '2026-05-04T19:30:00Z',
  'duration': 30600,
  'last_modified': '2026-05-04T19:31:12Z',
  'type': 'regular',
  'on_the_clock': false,
  'notes': '',
};

/// A second sample punch (different `id`) so multi-record tests can
/// run without colliding on the canonical UNIQUE.
const Map<String, Object?> secondQuickBooksTimePunch = <String, Object?>{
  'id': 901002,
  'user_id': 8002,
  'jobcode_id': 5002,
  'role_name': 'cook',
  'start': '2026-05-04T10:00:00Z',
  'end': '2026-05-04T18:00:00Z',
  'duration': 28800,
  'last_modified': '2026-05-04T18:02:00Z',
  'type': 'regular',
  'on_the_clock': false,
  'notes': '',
};

/// Backfill page 1 — three punches the multi-page test walks across.
const List<Map<String, Object?>> quickBooksTimeBackfillPage1 =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 902001,
    'user_id': 8001,
    'jobcode_id': 5001,
    'role_name': 'server',
    'start': '2026-04-30T15:00:00Z',
    'end': '2026-04-30T22:30:00Z',
    'duration': 27000,
    'last_modified': '2026-04-30T22:31:00Z',
    'type': 'regular',
    'on_the_clock': false,
  },
  <String, Object?>{
    'id': 902002,
    'user_id': 8002,
    'jobcode_id': 5002,
    'role_name': 'cook',
    'start': '2026-05-01T09:00:00Z',
    'end': '2026-05-01T17:00:00Z',
    'duration': 28800,
    'last_modified': '2026-05-01T17:01:00Z',
    'type': 'regular',
    'on_the_clock': false,
  },
  <String, Object?>{
    'id': 902003,
    'user_id': 8003,
    'jobcode_id': 5003,
    'role_name': 'manager',
    'start': '2026-05-01T11:00:00Z',
    'end': '2026-05-01T20:00:00Z',
    'duration': 32400,
    'last_modified': '2026-05-01T20:05:00Z',
    'type': 'regular',
    'on_the_clock': false,
  },
];

/// Backfill page 2 — two more punches.
const List<Map<String, Object?>> quickBooksTimeBackfillPage2 =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 902004,
    'user_id': 8004,
    'jobcode_id': 5001,
    'role_name': 'server',
    'start': '2026-05-02T11:00:00Z',
    'end': '2026-05-02T19:30:00Z',
    'duration': 30600,
    'last_modified': '2026-05-02T19:31:00Z',
    'type': 'regular',
    'on_the_clock': false,
  },
  <String, Object?>{
    'id': 902005,
    'user_id': 8005,
    'jobcode_id': 5002,
    'role_name': 'cook',
    'start': '2026-05-02T10:00:00Z',
    'end': '2026-05-02T18:00:00Z',
    'duration': 28800,
    'last_modified': '2026-05-02T18:02:00Z',
    'type': 'regular',
    'on_the_clock': false,
  },
];

/// A future-dated punch used to drive the sanity-hook reject path.
/// The framework's `VendorTimestampSanity` flags `shift_start > now() +
/// 1 hour` as `opened_in_future`; the adapter must skip the canonical
/// write when the hook returns `false`.
const Map<String, Object?> futureDatedQuickBooksTimePunch =
    <String, Object?>{
  'id': 999001,
  'user_id': 8099,
  'jobcode_id': 5099,
  'role_name': 'server',
  'start': '2027-05-02T11:00:00Z',
  'end': '2027-05-02T19:30:00Z',
  'duration': 30600,
  'last_modified': '2027-05-02T19:31:00Z',
  'type': 'regular',
  'on_the_clock': false,
};
