// Phase 8 (`8.CL`) — Clover orders fixture pack.
//
// Source documentation:
//   * REST API v3 reference: https://docs.clover.com/reference/orders
//   * Orders modifiedTime filter (90-day cap):
//     https://docs.clover.com/docs/working-with-list-endpoints
//   * Order shape:
//     https://docs.clover.com/reference/orderget
// Retrieval date: 2026-05-03
//
// Every canonical-fact field the [CloverPosAdapter] writes is captured
// here as a `documented_per_clover_v3_2026_05_03` constant Map. The
// `*.live.sandbox` slice diffs observed responses against these
// constants; mismatches become bounded fixes (not slice rebuilds).

import 'dart:typed_data';

/// Stable adapter API-version pin. Bump when Clover ships a versioned
/// breaking change AND the `*.live.sandbox` slice has re-verified.
const String cloverApiVersion = 'v3_2026_05_03';

/// Documented Clover field-shape map. Every row in
/// `docs/integrations/clover/field_mapping.md` has a counterpart key
/// here so Codex can diff the two without parsing markdown.
///
/// The constant name follows the
/// `documented_per_<vendor>_<api_version>` shape mandated by
/// `docs/contracts/per_vendor_doc_pack_contract.md`; the analyzer
/// lowerCamelCase lint is silenced because the contract is the
/// authority.
// ignore: constant_identifier_names
const Map<String, Object?> documented_per_clover_v3_2026_05_03 =
    <String, Object?>{
  // Vendor entity id — stable Clover order id.
  'vendor_entity_id_path': 'order.id',
  'vendor_entity_id_type': 'string',

  // Open / close timestamps. Clover emits epoch milliseconds (UTC).
  // `createdTime` is the order-open instant; `modifiedTime` is the
  // last-state-change instant which we adopt as `closed_at` when
  // `state == 'paid'` per documented ambiguity call (see field_mapping.md).
  'opened_at_path': 'order.createdTime',
  'opened_at_type': 'epoch_millis_utc',
  'closed_at_path': 'order.modifiedTime',
  'closed_at_type': 'epoch_millis_utc',
  'closed_at_state_gate': 'paid',
  'vendor_modified_at_path': 'order.modifiedTime',
  'vendor_modified_at_type': 'epoch_millis_utc',

  // Total amount. Clover stores amounts in the merchant's currency
  // smallest unit (cents for USD/CAD). Convert to dollars at adapter
  // boundary so canonical `actual_sales` is consistent with other
  // POS adapters.
  'actual_sales_path': 'order.total',
  'actual_sales_type': 'int_smallest_unit',
  'actual_sales_transform': 'cents_to_dollars',

  // Covers. Clover does NOT expose a guest-count field on /orders;
  // adapter records `covers = null` and `covers_source =
  // forecast_fallback`. Verified per
  // https://docs.clover.com/reference/orderget (no `guests` key in the
  // response schema).
  'covers_field_exposed': false,
  'covers_source_value': 'forecast_fallback',

  // Merchant / location binding. Clover's per-merchant grant scope
  // means the connection metadata stores `merchant_id` (Clover's
  // `mId`).
  'binding_path': 'merchant.id',
  'binding_metadata_key': 'merchant_id',
};

/// One sample Clover order body — the shape `/v3/merchants/{mId}/orders`
/// returns inside `elements`. Used by tests as an authoritative
/// sample the field mapping is graded against.
const Map<String, Object?> sampleCloverOrder = <String, Object?>{
  'id': 'CLV-ORDER-7HXJ-2026-05-02-001',
  'createdTime': 1777747500000, // 2026-05-02T18:45:00Z
  'modifiedTime': 1777750980000, // 2026-05-02T19:43:00Z
  'state': 'paid',
  'total': 3140, // cents = $31.40
  'currency': 'USD',
  'merchant': <String, Object?>{
    'id': 'CLV-MERCH-CCD13C7B',
  },
};

/// Forecast-fallback reference: the canonical fact the adapter writes
/// from `sampleCloverOrder`. Tests assert the adapter produces this
/// exact shape so the doc pack and the code stay in sync.
const Map<String, Object?> sampleCanonicalFactFromCloverOrder =
    <String, Object?>{
  'vendor_entity_id': 'CLV-ORDER-7HXJ-2026-05-02-001',
  'opened_at_iso': '2026-05-02T18:45:00.000Z',
  'closed_at_iso': '2026-05-02T19:43:00.000Z',
  'actual_sales': 31.40,
  'covers': null,
  'covers_source': 'forecast_fallback',
  'vendor_modified_at_iso': '2026-05-02T19:43:00.000Z',
};

/// A page of two orders mid-backfill — used by the watermark-resume
/// test to assert that batch-1 cursor commit precedes batch-2 read.
const List<Map<String, Object?>> sampleCloverOrdersPageOne =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 'CLV-ORDER-PAGE1-A',
    'createdTime': 1777676000000, // 2026-05-01 mid-day
    'modifiedTime': 1777679600000,
    'state': 'paid',
    'total': 1875,
    'currency': 'USD',
    'merchant': <String, Object?>{'id': 'CLV-MERCH-CCD13C7B'},
  },
  <String, Object?>{
    'id': 'CLV-ORDER-PAGE1-B',
    'createdTime': 1777683200000,
    'modifiedTime': 1777686800000,
    'state': 'paid',
    'total': 4220,
    'currency': 'USD',
    'merchant': <String, Object?>{'id': 'CLV-MERCH-CCD13C7B'},
  },
];

const List<Map<String, Object?>> sampleCloverOrdersPageTwo =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 'CLV-ORDER-PAGE2-A',
    'createdTime': 1777686900000,
    'modifiedTime': 1777690500000,
    'state': 'paid',
    'total': 2960,
    'currency': 'USD',
    'merchant': <String, Object?>{'id': 'CLV-MERCH-CCD13C7B'},
  },
];

/// Documented merchant-id used across fixtures. Real merchant ids are
/// 13-char alphanumeric per Clover's public API examples.
const String fixtureMerchantId = 'CLV-MERCH-CCD13C7B';

/// Helper: build a stable raw-body byte sequence the webhook signature
/// fixture can sign + the verifier test can re-sign + compare.
Uint8List cloverFixtureRawBody(String json) =>
    Uint8List.fromList(json.codeUnits);
