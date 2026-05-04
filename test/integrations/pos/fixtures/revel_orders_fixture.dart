// Phase 8.RV — Revel Systems order fixtures.
//
// Documented per
// `https://developer.revelsystems.com/revelsystems/docs/webhooks` and
// the integration-management endpoints documented in the same portal.
// Retrieval date: 2026-05-03.
//
// The constant [documentedPerRevelV1FieldMapping] mirrors
// `lib/integrations/pos/revel_pos_adapter.dart` `documentedPerRevelV1`
// — the engineering slice's source of truth for what every canonical
// fact field is documented to map to. The `8.RV.live.sandbox` slice
// will diff observed sandbox responses against this map; mismatches
// become bounded fixes (not slice rebuilds).

/// Field-mapping reference: vendor field path → canonical field
/// + transform. Mirrors `documentedPerRevelV1` in the adapter file.
const Map<String, Object?> documentedPerRevelV1FieldMapping =
    <String, Object?>{
  'api_version': 'v1-2026-05-03',
  'covers': <String, Object?>{
    'path': 'order.number_of_people',
    'type': 'int',
    'transform': 'direct',
    'doc_url':
        'https://developer.revelsystems.com/revelsystems/docs/webhooks',
  },
  'opened_at': <String, Object?>{
    'path': 'order.created_date',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developer.revelsystems.com/revelsystems/docs/webhooks',
  },
  'closed_at': <String, Object?>{
    'path': 'order.updated_date',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developer.revelsystems.com/revelsystems/docs/webhooks',
  },
  'actual_sales': <String, Object?>{
    'path': 'order.final_total',
    'type': 'string_or_number_dollars',
    'transform': 'parse_to_num',
    'doc_url':
        'https://developer.revelsystems.com/revelsystems/docs/webhooks',
  },
  'vendor_entity_id': <String, Object?>{
    'path': 'order.id',
    'type': 'int_or_string',
    'transform': 'to_string',
    'doc_url':
        'https://developer.revelsystems.com/revelsystems/docs/webhooks',
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'order.updated_date',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developer.revelsystems.com/revelsystems/docs/webhooks',
  },
};

/// Sample test-connection order shape. The numbers are deliberately
/// human-readable (covers=3, total=64.30) so an operator running
/// `testConnection` from the admin widget can eyeball the result and
/// confirm the field mapping without reading vendor docs.
const Map<String, Object?> revelSampleOrder = <String, Object?>{
  'id': 8842301,
  'local_id': 'A-0142',
  'created_date': '2026-05-02T18:45:00Z',
  'updated_date': '2026-05-02T19:31:00Z',
  'final_total': '64.30',
  'subtotal': '57.40',
  'tax': '6.90',
  'number_of_people': 3,
  'closed': true,
  'dining_option': 1,
  'uuid': '00000000-0000-4000-8000-aaaaaaaaaaaa',
  'establishment_id': 4421,
  'instance_name': 'demo-instance',
};

/// A short batch returned by the integrations list endpoint during
/// backfill. Five orders, walked across 2 pages (3 + 2). Each row's
/// `updated_date` strictly increases.
const List<Map<String, Object?>> revelBackfillBatchPage1 = <Map<String, Object?>>[
  <String, Object?>{
    'id': 9001,
    'local_id': 'A-0001',
    'created_date': '2026-04-30T17:00:00Z',
    'updated_date': '2026-04-30T18:05:00Z',
    'final_total': '42.10',
    'number_of_people': 2,
    'closed': true,
    'establishment_id': 4421,
    'instance_name': 'demo-instance',
  },
  <String, Object?>{
    'id': 9002,
    'local_id': 'A-0002',
    'created_date': '2026-05-01T17:30:00Z',
    'updated_date': '2026-05-01T18:55:00Z',
    'final_total': '120.00',
    'number_of_people': 4,
    'closed': true,
    'establishment_id': 4421,
    'instance_name': 'demo-instance',
  },
  <String, Object?>{
    'id': 9003,
    'local_id': 'A-0003',
    'created_date': '2026-05-01T18:00:00Z',
    'updated_date': '2026-05-01T19:25:00Z',
    'final_total': '88.50',
    'number_of_people': 3,
    'closed': true,
    'establishment_id': 4421,
    'instance_name': 'demo-instance',
  },
];

const List<Map<String, Object?>> revelBackfillBatchPage2 = <Map<String, Object?>>[
  <String, Object?>{
    'id': 9004,
    'local_id': 'A-0004',
    'created_date': '2026-05-02T17:00:00Z',
    'updated_date': '2026-05-02T18:10:00Z',
    'final_total': '65.20',
    'number_of_people': 2,
    'closed': true,
    'establishment_id': 4421,
    'instance_name': 'demo-instance',
  },
  <String, Object?>{
    'id': 9005,
    'local_id': 'A-0005',
    'created_date': '2026-05-02T18:30:00Z',
    'updated_date': '2026-05-02T19:48:00Z',
    'final_total': '54.00',
    'number_of_people': 2,
    'closed': true,
    'establishment_id': 4421,
    'instance_name': 'demo-instance',
  },
];

/// Future-dated row used to trigger the framework's vendor timestamp
/// sanity guard (rule 2: opened_in_future).
const Map<String, Object?> revelFutureDatedOrder = <String, Object?>{
  'id': 9999,
  'local_id': 'A-9999',
  // Reads as 30 days into the future relative to `nowFixed` in the
  // adapter test harness.
  'created_date': '2026-06-15T12:00:00Z',
  'updated_date': '2026-06-15T13:00:00Z',
  'final_total': '50.00',
  'number_of_people': 2,
  'closed': true,
  'establishment_id': 4421,
  'instance_name': 'demo-instance',
};
