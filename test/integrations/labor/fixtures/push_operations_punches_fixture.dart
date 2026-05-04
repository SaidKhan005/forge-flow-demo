// Phase 8.S / Wave B — Push Operations scheduling adapter fixtures.
//
// Source documentation: https://developers.pushoperations.com/
// Retrieval date: 2026-05-04
// API version pinned: v1 (Push Operations REST API at /api/v1/...)
//
// The `documented_per_push_operations_v1` constant captures every
// documented assumption the engineering slice makes about the vendor
// field shape. The `8.S.PU.live.sandbox` slice diffs observed vendor
// responses against this constant; any discrepancy lands as a bounded
// fix (not a slice rebuild).

/// Documented field-mapping constants captured from the Push
/// Operations REST API documentation as of 2026-05-04. Every canonical
/// field the adapter populates has a row in this map; the per-vendor
/// doc pack at `docs/integrations/push_operations/field_mapping.md`
/// mirrors this constant in human-readable form.
///
/// The snake_case name follows the
/// `documented_per_<vendor>_<api_version>` shape mandated by
/// `docs/contracts/per_vendor_doc_pack_contract.md`; the lint
/// directive below suppresses the lowerCamelCase rule for this
/// contract-bound name only.
// ignore: constant_identifier_names
const Map<String, Object?> documented_per_push_operations_v1 =
    <String, Object?>{
  'shift_start_path': 'shifts[].start_at',
  'shift_start_type': 'ISO 8601 UTC (with explicit Z)',
  'shift_end_path': 'shifts[].end_at',
  'shift_end_type': 'ISO 8601 UTC (with explicit Z)',
  'role_name_path': 'shifts[].position_name',
  'role_name_type': 'string (free-form vendor-defined position label)',
  'employee_id_path': 'shifts[].employee_id',
  'employee_id_type': 'int (stringified at canonical write)',
  'vendor_entity_id_path': 'shifts[].id',
  'vendor_entity_id_type': 'int (stringified at canonical write)',
  'vendor_modified_at_path': 'shifts[].updated_at',
  'vendor_modified_at_type': 'ISO 8601 UTC (with explicit Z)',
  'covers_source_classification': 'not_applicable',
  'pagination_shape':
      'page+limit (default limit=100, max page size; short page = end)',
  'pagination_labour_endpoint':
      'date-range with 2-day max window (separate from page+limit)',
  'rate_limit': 'partner-issued; vendor does not publish a single '
      'numeric cap, partner approval may raise per use case',
  'webhook_support':
      'pollOnly (vendor does not document webhook delivery)',
  'auth_mode':
      'keyPaste (partner-issued bearer token; static credential, no '
          'OAuth hop, no refresh-token rotation)',
  'grant_scope':
      'operatorWide (one bearer token covers the operator\'s entire '
          'Push Operations company across locations)',
  'partnership_program': 'Push Operations partner approval',
  'partnership_lead_time': '4-6 weeks',
};

/// One representative Push Operations `shifts[]` record used by the
/// `testConnection` and idempotency / sanity / watermark tests.
///
/// The values follow the field-mapping constant above; `start_at` and
/// `end_at` are explicit-Z ISO-8601 instants the adapter parses via
/// `DateTime.parse(...).toUtc()`.
const Map<String, Object?> samplePushOperationsShift = <String, Object?>{
  'id': 800101,
  'employee_id': 5512,
  'position_name': 'Server',
  'start_at': '2026-05-02T16:00:00.000Z',
  'end_at': '2026-05-02T23:30:00.000Z',
  'updated_at': '2026-05-02T15:45:00.000Z',
};

/// A second sample shift (different `id`) so multi-record tests can
/// run without colliding on the canonical UNIQUE.
const Map<String, Object?> secondPushOperationsShift = <String, Object?>{
  'id': 800102,
  'employee_id': 5519,
  'position_name': 'Line Cook',
  'start_at': '2026-05-02T17:30:00.000Z',
  'end_at': '2026-05-03T01:15:00.000Z',
  'updated_at': '2026-05-02T17:15:00.000Z',
};

/// A future-dated shift used to drive the sanity-hook reject path. The
/// framework's `VendorTimestampSanity` flags `shift_start > now() + 1
/// hour` (where the framework treats `start_at` as the labor-side
/// equivalent of `opened_at` for sanity); the adapter must skip the
/// canonical write when the hook returns `false`.
const Map<String, Object?> futureDatedPushOperationsShift =
    <String, Object?>{
  'id': 999001,
  'employee_id': 5599,
  'position_name': 'Server',
  'start_at': '2027-05-02T16:00:00.000Z',
  'end_at': '2027-05-02T23:30:00.000Z',
  'updated_at': '2027-05-02T15:45:00.000Z',
};
