// Phase 8.S / Wave B — Agendrix scheduling adapter fixtures.
//
// Source documentation: https://developers.agendrix.com/en/documentation
// Retrieval date: 2026-05-04
// API version pinned: v2 (Agendrix Public REST API)
//
// The `documented_per_agendrix_v2` constant captures every documented
// assumption the engineering slice makes about the vendor field shape.
// The `8.S.AG.live.sandbox` slice diffs observed vendor responses
// against this constant; any discrepancy lands as a bounded fix
// (not a slice rebuild).

/// Documented field-mapping constants captured from the Agendrix
/// Public API documentation as of 2026-05-04. Every canonical field
/// the adapter populates has a row in this map; the per-vendor doc
/// pack at `docs/integrations/agendrix/field_mapping.md` mirrors this
/// constant in human-readable form.
///
/// The snake_case name follows the
/// `documented_per_<vendor>_<api_version>` shape mandated by
/// `docs/contracts/per_vendor_doc_pack_contract.md`; the lint
/// directive below suppresses the lowerCamelCase rule for this
/// contract-bound name only.
// ignore: constant_identifier_names
const Map<String, Object?> documented_per_agendrix_v2 = <String, Object?>{
  'shift_start_path': 'time_entries[].start_time',
  'shift_start_type': 'ISO 8601 UTC (with explicit Z)',
  'shift_end_path': 'time_entries[].end_time',
  'shift_end_type': 'ISO 8601 UTC (with explicit Z)',
  'role_name_path': 'time_entries[].position.name',
  'role_name_type': 'string',
  'employee_id_path': 'time_entries[].user_id',
  'employee_id_type': 'string (Agendrix user id)',
  'vendor_entity_id_path': 'time_entries[].id',
  'vendor_entity_id_type': 'string (Agendrix time entry id)',
  'vendor_modified_at_path': 'time_entries[].updated_at',
  'vendor_modified_at_type': 'ISO 8601 UTC (with explicit Z)',
  'covers_source_classification': 'not_applicable (labor adapter)',
  'wage_source_classification':
      'app_fallback (Agendrix exposes per-position pay only; not per-shift)',
  'pagination_shape':
      'cursor token (server-issued; empty string = end of listing)',
  'rate_limit':
      '~120 requests/min per organization (vendor-soft cap inferred '
          'from documentation; production limits confirmed at *.live)',
  'webhook_support': 'pollOnly (vendor does not document webhooks)',
  'auth_mode': 'oauth (authorization code; bearer access token)',
  'grant_scope':
      'operatorWide (a single OAuth grant covers every Agendrix '
          'location bound to the operator organization)',
  'partnership_program':
      'n/a — public OAuth (self-serve at developer portal)',
  'partnership_lead_time': 'none (self-serve dev portal with Playground)',
};

/// One representative Agendrix `time_entries[]` record used by the
/// `testConnection` and idempotency / sanity / watermark tests.
///
/// The values follow the field-mapping constant above; `position.name`
/// is `'Server'`, `start_time` and `end_time` are explicit-Z ISO-8601
/// instants the adapter parses via `DateTime.parse(...).toUtc()`.
const Map<String, Object?> sampleAgendrixTimeEntry = <String, Object?>{
  'id': 'te_412901',
  'user_id': 'usr_98231',
  'position': <String, Object?>{
    'id': 'pos_foh_server',
    'name': 'Server',
  },
  'start_time': '2026-05-02T15:00:00.000Z',
  'end_time': '2026-05-02T22:30:00.000Z',
  'updated_at': '2026-05-02T22:32:14.000Z',
};

/// A second sample time entry (different `id`) so multi-record
/// tests can run without colliding on the canonical UNIQUE.
const Map<String, Object?> secondAgendrixTimeEntry = <String, Object?>{
  'id': 'te_412902',
  'user_id': 'usr_98232',
  'position': <String, Object?>{
    'id': 'pos_boh_line',
    'name': 'Line Cook',
  },
  'start_time': '2026-05-02T16:30:00.000Z',
  'end_time': '2026-05-02T23:45:00.000Z',
  'updated_at': '2026-05-02T23:48:01.000Z',
};

/// A future-dated time entry used to drive the sanity-hook reject
/// path. The framework's `VendorTimestampSanity` flags
/// `shift_start > now() + 1 hour` as `shift_in_future`; the adapter
/// must skip the canonical write when the hook returns `false`.
const Map<String, Object?> futureDatedAgendrixTimeEntry = <String, Object?>{
  'id': 'te_999001',
  'user_id': 'usr_98231',
  'position': <String, Object?>{
    'id': 'pos_foh_server',
    'name': 'Server',
  },
  'start_time': '2027-05-02T15:00:00.000Z',
  'end_time': '2027-05-02T22:30:00.000Z',
  'updated_at': '2027-05-02T22:32:14.000Z',
};
