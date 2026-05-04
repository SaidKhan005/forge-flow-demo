// Phase 8 / Wave B — Oracle MICROS Simphony POS adapter fixtures.
//
// Source documentation: https://docs.oracle.com/en/industries/food-beverage/simphony/
// Retrieval date: 2026-05-04
// API version pinned: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
//
// The `documented_per_oracle_micros_simphony_v2` constant captures
// every documented assumption the engineering slice makes about the
// vendor field shape. The `8.OR.live.sandbox` slice diffs observed
// vendor responses against this constant; any discrepancy lands as a
// bounded fix (not a slice rebuild).

/// Documented field-mapping constants captured from the Oracle MICROS
/// Simphony STSGen2 Cloud API documentation as of 2026-05-04. Every
/// canonical field the adapter populates has a row in this map; the
/// per-vendor doc pack at `docs/integrations/oracle_micros_simphony/
/// field_mapping.md` mirrors this constant in human-readable form.
///
/// The snake_case name follows the
/// `documented_per_<vendor>_<api_version>` shape mandated by
/// `docs/contracts/per_vendor_doc_pack_contract.md`; the lint
/// directive below suppresses the lowerCamelCase rule for this
/// contract-bound name only.
// ignore: constant_identifier_names
const Map<String, Object?> documented_per_oracle_micros_simphony_v2 =
    <String, Object?>{
  'covers_path': 'guestChecks[].numOfGst',
  'covers_type': 'int',
  'covers_source_classification': 'direct',
  'opened_at_path': 'guestChecks[].opnUTC',
  'opened_at_type': 'ISO 8601 UTC (with explicit Z)',
  'closed_at_path': 'guestChecks[].clsdUTC',
  'closed_at_type': 'ISO 8601 UTC (with explicit Z)',
  'actual_sales_path': 'guestChecks[].subTtlCents',
  'actual_sales_type': 'int (cents)',
  'actual_sales_transform': 'cents -> dollars',
  'vendor_entity_id_path': 'guestChecks[].chkNum',
  'vendor_entity_id_type': 'int (stringified at canonical write)',
  'vendor_modified_at_path': 'guestChecks[].lastUpdatedUTC',
  'vendor_modified_at_type': 'ISO 8601 UTC (with explicit Z)',
  'pagination_shape': 'cursor token (server-issued; empty string = end)',
  'rate_limit': '60 requests/min per organization (vendor-documented '
      'soft limit; partner activation may raise)',
  'webhook_support': 'pollOnly (vendor does not document webhooks)',
  'auth_mode': 'oauth (client_credentials grant; bearer access token)',
  'grant_scope': 'perLocation (each F&F location maps to one Simphony '
      '`locRef` via the OAuth token claim)',
  'partnership_program': 'Simphony Partner Integration Program',
  'partnership_lead_time': '8-16 weeks',
};

/// One representative Simphony `guestChecks[]` record used by the
/// `testConnection` and idempotency / sanity / watermark tests.
///
/// The values follow the field-mapping constant above; covers = 5,
/// `subTtlCents = 12485` projects to `actual_sales = 124.85`,
/// `opened_at` and `closed_at` are explicit-Z ISO-8601 instants the
/// adapter parses via `DateTime.parse(...).toUtc()`.
const Map<String, Object?> sampleSimphonyGuestCheck = <String, Object?>{
  'chkNum': 412901,
  'numOfGst': 5,
  'opnUTC': '2026-05-02T22:45:00.000Z',
  'clsdUTC': '2026-05-02T23:32:14.000Z',
  'subTtlCents': 12485,
  'lastUpdatedUTC': '2026-05-02T23:32:14.000Z',
};

/// A second sample guest check (different `chkNum`) so multi-record
/// tests can run without colliding on the canonical UNIQUE.
const Map<String, Object?> secondSimphonyGuestCheck = <String, Object?>{
  'chkNum': 412902,
  'numOfGst': 2,
  'opnUTC': '2026-05-02T23:05:00.000Z',
  'clsdUTC': '2026-05-02T23:48:01.000Z',
  'subTtlCents': 5790,
  'lastUpdatedUTC': '2026-05-02T23:48:01.000Z',
};

/// A future-dated guest check used to drive the sanity-hook reject
/// path. The framework's `VendorTimestampSanity` flags `opened_at >
/// now() + 1 hour` as `opened_in_future`; the adapter must skip the
/// canonical write when the hook returns `false`.
const Map<String, Object?> futureDatedSimphonyGuestCheck = <String, Object?>{
  'chkNum': 999001,
  'numOfGst': 3,
  'opnUTC': '2027-05-02T00:00:00.000Z',
  'clsdUTC': '2027-05-02T01:00:00.000Z',
  'subTtlCents': 6500,
  'lastUpdatedUTC': '2027-05-02T01:00:00.000Z',
};
