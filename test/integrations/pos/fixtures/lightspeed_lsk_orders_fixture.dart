// Phase 8.LSK — Lightspeed Restaurant K-Series order fixtures.
//
// Source documentation: https://api-docs.lsk.lightspeed.app/
//   * Get Sales: https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales
//   * Get business day sales: https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsalesofabusinessday
// Retrieved: 2026-05-03.
//
// These fixtures are the canonical specimen of Lightspeed K-Series
// sale objects the adapter consumes. The
// `documented_per_lightspeed_lsk_f_v2_2026_05` constant Map mirrors
// the field-mapping table in
// `docs/integrations/lightspeed_lsk/field_mapping.md` row-for-row.
// Codex grades the diff between this constant, the doc table, and
// the field accessors in
// `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart`. Any change
// to a vendor field path requires updating all three sites.

/// Field-mapping reference. Mirrors `field_mapping.md` row-for-row.
/// The constant name embeds the API version
/// (`kLightspeedLskApiVersion`) so a vendor shape change surfaces as
/// a renamed constant + diff in git history. Per
/// `docs/contracts/per_vendor_doc_pack_contract.md`, the canonical
/// shape is `documented_per_<vendor>_<api_version>` (snake_case).
// ignore: constant_identifier_names
const Map<String, String> documented_per_lightspeed_lsk_f_v2_2026_05 =
    <String, String>{
  // canonical_field: vendor_field_path
  'covers': 'sales[].nbCovers',
  'opened_at': 'sales[].timeOfOpening',
  'closed_at': 'sales[].timeClosed',
  'actual_sales': 'sales[].payments[].netAmountWithTax',
  'vendor_entity_id': 'sales[].accountFiscId',
  'vendor_modified_at':
      'sales[].timeClosed (or timeOfOpening when timeClosed absent)',
};

/// Five-record fixture batch the backfill / sanity-hook tests drive.
/// Timestamps are anchored at 2026-05-04 dinner service (business
/// date 2026-05-04 in `America/Toronto`, 4 AM rollover).
List<Map<String, Object?>> lightspeedLskFiveRecordBatch() => <Map<String, Object?>>[
      _sale(
        accountFiscId: 'A65315.17',
        timeOfOpening: '2026-05-04T22:45:00.000Z',
        timeClosed: '2026-05-04T23:42:00.000Z',
        nbCovers: 3.0,
        payments: <Map<String, Object?>>[
          <String, Object?>{'netAmountWithTax': '142.55'},
        ],
      ),
      _sale(
        accountFiscId: 'A65315.18',
        timeOfOpening: '2026-05-04T22:50:00.000Z',
        timeClosed: '2026-05-04T23:55:00.000Z',
        nbCovers: 2.0,
        payments: <Map<String, Object?>>[
          <String, Object?>{'netAmountWithTax': '88.20'},
        ],
      ),
      _sale(
        accountFiscId: 'A65315.19',
        timeOfOpening: '2026-05-04T23:05:00.000Z',
        timeClosed: '2026-05-05T00:18:00.000Z',
        nbCovers: 4.0,
        payments: <Map<String, Object?>>[
          <String, Object?>{'netAmountWithTax': '210.00'},
        ],
      ),
      _sale(
        accountFiscId: 'A65315.20',
        timeOfOpening: '2026-05-04T23:25:00.000Z',
        timeClosed: '2026-05-05T00:35:00.000Z',
        nbCovers: 5.0,
        payments: <Map<String, Object?>>[
          <String, Object?>{'netAmountWithTax': '274.85'},
          <String, Object?>{'netAmountWithTax': '50.00'},
        ],
      ),
      _sale(
        accountFiscId: 'A65315.21',
        timeOfOpening: '2026-05-04T23:40:00.000Z',
        timeClosed: '2026-05-05T00:55:00.000Z',
        nbCovers: 2.0,
        payments: <Map<String, Object?>>[
          <String, Object?>{'netAmountWithTax': '95.40'},
        ],
      ),
    ];

/// Sample order for the test-connection screen. Picks the simplest
/// shape so the operator's first eyeballing covers the high-impact
/// fields.
Map<String, Object?> lightspeedLskSampleOrder() => _sale(
      accountFiscId: 'A65315.17',
      timeOfOpening: '2026-05-04T18:45:00.000Z',
      timeClosed: '2026-05-04T19:42:00.000Z',
      nbCovers: 3.0,
      payments: <Map<String, Object?>>[
        <String, Object?>{'netAmountWithTax': '142.55'},
      ],
    );

/// Future-dated sale — exercises the framework's sanity rule 2
/// (`opened_in_future`) when handed to `pollIncremental`.
Map<String, Object?> lightspeedLskFutureDatedSale({DateTime? referenceUtc}) {
  final now = referenceUtc ?? DateTime.utc(2026, 5, 4, 12, 0, 0);
  return _sale(
    accountFiscId: 'A65315.future',
    timeOfOpening: now.add(const Duration(days: 5)).toIso8601String(),
    timeClosed: now.add(const Duration(days: 5, hours: 1)).toIso8601String(),
    nbCovers: 1.0,
    payments: <Map<String, Object?>>[],
  );
}

/// Malformed sale — missing `accountFiscId`. Exercises the adapter's
/// boundary parse-drop path (one `connector_sync_log` row, no
/// canonical fact write).
Map<String, Object?> lightspeedLskMalformedSale() => <String, Object?>{
      'timeOfOpening': '2026-05-04T18:45:00.000Z',
      'timeClosed': '2026-05-04T19:42:00.000Z',
      'nbCovers': 2.0,
      'payments': <Map<String, Object?>>[],
    };

Map<String, Object?> _sale({
  required String accountFiscId,
  required String timeOfOpening,
  required String timeClosed,
  required double nbCovers,
  required List<Map<String, Object?>> payments,
}) =>
    <String, Object?>{
      'accountFiscId': accountFiscId,
      'timeOfOpening': timeOfOpening,
      'timeClosed': timeClosed,
      'nbCovers': nbCovers,
      'payments': payments,
      // Lightspeed sales emit `salesLines` and other arrays the
      // adapter intentionally ignores per `field_mapping.md` Forbidden
      // fields. Keep them present here so the parse path exercises
      // ignored-field behavior.
      'salesLines': const <Map<String, Object?>>[],
      'staff': const <Map<String, Object?>>[],
    };
