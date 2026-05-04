// Phase 8.S.ADP — ADP punches / time-events fixtures.
//
// Documented per the ADP developer-portal API catalog
// (https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog),
// retrieval date 2026-05-04. Same portal hosts the Workforce Manager
// (WFM) catalog. EVERY field-mapping assumption is flagged
// `verify_in_live_sandbox: true` so the `8.S.ADP.live.sandbox` slice
// can diff observed responses against this constant. Mismatches
// become bounded fixes, not slice rebuilds, per
// `docs/contracts/vendor_adapter_slice_contract.md`.
//
// The constant [documentedPerAdpV1FieldMappingFixture] mirrors
// `lib/integrations/labor/adp_labor_adapter.dart`
// `documentedPerAdpV1FieldMapping`; the test asserts the constants
// stay in sync.

/// Field-mapping reference: vendor field path → canonical field +
/// transform. Mirrors `documentedPerAdpV1FieldMapping` in the adapter
/// file. Every row carries `verify_in_live_sandbox: true`.
const Map<String, Object?> documentedPerAdpV1FieldMappingFixture =
    <String, Object?>{
  'api_version': 'v1-2026-05-04-assumed',
  'shift_start': <String, Object?>{
    'path': 'time_event.entry_date_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
  },
  'shift_end': <String, Object?>{
    'path': 'time_event.exit_date_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
  },
  'role_name': <String, Object?>{
    'path': 'worker.position.position_title',
    'type': 'string',
    'transform': 'direct',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
  },
  'employee_id': <String, Object?>{
    'path': 'worker.associate_oid',
    'type': 'string',
    'transform': 'direct',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
  },
  'vendor_entity_id': <String, Object?>{
    'path': 'time_event.id',
    'type': 'string',
    'transform': 'direct',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'time_event.last_modified_date_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
  },
};

/// Sample test-connection time event. Numbers are deliberately
/// human-readable (role=Server, shift_start clearly today, shift_end
/// 8 hours later) so an operator running `testConnection` from the
/// admin widget can eyeball the result and confirm the field mapping.
/// Includes a fully-populated `worker` block so the canonicalizer can
/// resolve `role_name` + `employee_id`.
const Map<String, Object?> adpSampleTimeEvent = <String, Object?>{
  'id': 'ADP-TE-12345',
  'entry_date_time': '2026-05-04T15:00:00Z',
  'exit_date_time': '2026-05-04T23:00:00Z',
  'last_modified_date_time': '2026-05-04T23:00:30Z',
  'worker': <String, Object?>{
    'associate_oid': 'G3WXX1Y2Z3A4B5C6',
    'position': <String, Object?>{
      'position_title': 'Server',
    },
  },
};

/// A short backfill batch returned by the time-events endpoint. Five
/// punches walked across 2 pages (3 + 2). Each row's
/// `last_modified_date_time` strictly increases.
const List<Map<String, Object?>> adpBackfillBatchPage1 =
    <Map<String, Object?>>[
  <String, Object?>{
    'time_event': <String, Object?>{
      'id': 'ADP-TE-9001',
      'entry_date_time': '2026-04-30T18:00:00Z',
      'exit_date_time': '2026-05-01T02:00:00Z',
      'last_modified_date_time': '2026-05-01T02:00:30Z',
    },
    'worker': <String, Object?>{
      'associate_oid': 'G3W001',
      'position': <String, Object?>{'position_title': 'Server'},
    },
  },
  <String, Object?>{
    'time_event': <String, Object?>{
      'id': 'ADP-TE-9002',
      'entry_date_time': '2026-05-01T11:00:00Z',
      'exit_date_time': '2026-05-01T19:30:00Z',
      'last_modified_date_time': '2026-05-01T19:30:45Z',
    },
    'worker': <String, Object?>{
      'associate_oid': 'G3W002',
      'position': <String, Object?>{'position_title': 'Cook'},
    },
  },
  <String, Object?>{
    'time_event': <String, Object?>{
      'id': 'ADP-TE-9003',
      'entry_date_time': '2026-05-01T16:00:00Z',
      'exit_date_time': null,
      'last_modified_date_time': '2026-05-01T19:25:00Z',
    },
    'worker': <String, Object?>{
      'associate_oid': 'G3W003',
      // Workforce Manager-shape: jobTitle on workAssignment instead
      // of position.position_title. The canonicalizer falls back to
      // the WFM path when WFN-style is absent.
      'workAssignment': <String, Object?>{'jobTitle': 'Bartender'},
    },
  },
];

const List<Map<String, Object?>> adpBackfillBatchPage2 =
    <Map<String, Object?>>[
  <String, Object?>{
    'time_event': <String, Object?>{
      'id': 'ADP-TE-9004',
      'entry_date_time': '2026-05-02T11:00:00Z',
      'exit_date_time': '2026-05-02T19:00:00Z',
      'last_modified_date_time': '2026-05-02T19:00:10Z',
    },
    'worker': <String, Object?>{
      'associate_oid': 'G3W004',
      'position': <String, Object?>{'position_title': 'Server'},
    },
  },
  <String, Object?>{
    'time_event': <String, Object?>{
      'id': 'ADP-TE-9005',
      'entry_date_time': '2026-05-02T17:00:00Z',
      'exit_date_time': '2026-05-03T01:30:00Z',
      'last_modified_date_time': '2026-05-03T01:30:48Z',
    },
    'worker': <String, Object?>{
      'associate_oid': 'G3W005',
      'position': <String, Object?>{'position_title': 'Dishwasher'},
    },
  },
];

/// Future-dated row used to trigger the framework's vendor timestamp
/// sanity guard (rule: opened_in_future).
const Map<String, Object?> adpFutureDatedTimeEvent = <String, Object?>{
  'time_event': <String, Object?>{
    'id': 'ADP-TE-9999',
    // Reads as 60 days into the future relative to `nowFixed` in the
    // adapter test harness.
    'entry_date_time': '2026-07-15T12:00:00Z',
    'exit_date_time': '2026-07-15T20:00:00Z',
    'last_modified_date_time': '2026-07-15T20:00:30Z',
  },
  'worker': <String, Object?>{
    'associate_oid': 'G3W999',
    'position': <String, Object?>{'position_title': 'Server'},
  },
};
