// Phase 8 — Square SearchOrders + RetrieveOrder fixtures.
//
// Source: https://developer.squareup.com/reference/square/orders-api/search-orders
// (retrieved 2026-05-03).
// Source: https://developer.squareup.com/reference/square/objects/Order
// (retrieved 2026-05-03).
//
// API version pinned: 2024-01-18.
//
// Every field-mapping assumption the adapter makes is captured in
// `documented_per_square_2024_01_18` below and mirrored in
// `docs/integrations/square/field_mapping.md`. The `*.live.sandbox`
// slice will diff observed sandbox responses against this constant.
//
// Covers handling: Square's Order resource has NO guest-count field
// (verified at the second URL above 2026-05-03). The fixtures
// deliberately omit any `covers` row; the adapter writes
// `covers_source = 'forecast_fallback'` on every canonical fact.

/// Field-mapping contract — same shape as the const declared in the
/// adapter source so test code can pin the documented mapping.
/// Snake-case naming is intentional per the
/// `documented_per_<vendor>_<api_version>` doc-pack contract.
// ignore: constant_identifier_names
const Map<String, String> documented_per_square_2024_01_18_fixture = <String, String>{
  'opened_at': 'order.created_at',
  'closed_at': 'order.closed_at',
  'actual_sales': 'order.total_money.amount (cents → dollars)',
  'vendor_entity_id': 'order.id',
  'vendor_modified_at': 'order.updated_at',
  'covers':
      '<not_populated; covers_source = forecast_fallback per Square Order schema>',
};

/// Sample SearchOrders response — three orders across two locations,
/// covering the "open + close in the same window" case (`order_1`),
/// the "still-open order" case (no `closed_at`, `order_2`), and the
/// "voided order with negative net" case (`order_3`).
const Map<String, Object?> sampleSearchOrdersResponse = <String, Object?>{
  'orders': <Map<String, Object?>>[
    <String, Object?>{
      'id': 'sq_ord_001',
      'location_id': 'L_RESTAURANT_A',
      'created_at': '2026-05-03T17:30:00Z',
      'updated_at': '2026-05-03T18:45:00Z',
      'closed_at': '2026-05-03T18:45:00Z',
      'total_money': <String, Object?>{
        'amount': 4250, // cents → 42.50
        'currency': 'CAD',
      },
      'state': 'COMPLETED',
    },
    <String, Object?>{
      'id': 'sq_ord_002',
      'location_id': 'L_RESTAURANT_A',
      'created_at': '2026-05-03T19:00:00Z',
      'updated_at': '2026-05-03T19:00:00Z',
      'total_money': <String, Object?>{
        'amount': 1900,
        'currency': 'CAD',
      },
      'state': 'OPEN',
    },
    <String, Object?>{
      'id': 'sq_ord_003',
      'location_id': 'L_RESTAURANT_B',
      'created_at': '2026-05-03T20:15:00Z',
      'updated_at': '2026-05-03T20:30:00Z',
      'closed_at': '2026-05-03T20:30:00Z',
      'total_money': <String, Object?>{
        'amount': 0,
        'currency': 'CAD',
      },
      'state': 'CANCELED',
    },
  ],
  'cursor': 'NEXT_PAGE_CURSOR_TOKEN',
};

/// Empty trailing page — adapter exits the do/while when cursor is
/// null/empty.
const Map<String, Object?> sampleEmptyTrailingPage = <String, Object?>{
  'orders': <Map<String, Object?>>[],
  'cursor': null,
};

/// Future-dated order — exercises sanity rule 2 (`opened_in_future`).
/// Adapter passes this through the sanity hook; hook returns false;
/// adapter skips the canonical write.
Map<String, Object?> futureDatedOrder({required DateTime now}) {
  final futureCreated = now.add(const Duration(hours: 6)).toUtc();
  return <String, Object?>{
    'id': 'sq_ord_future_001',
    'location_id': 'L_RESTAURANT_A',
    'created_at': futureCreated.toIso8601String(),
    'updated_at': futureCreated.toIso8601String(),
    'total_money': <String, Object?>{
      'amount': 1000,
      'currency': 'CAD',
    },
    'state': 'OPEN',
  };
}

/// Sample RetrieveOrder response — used by the webhook handler when
/// the inbound payload only carried `data.id`.
const Map<String, Object?> sampleRetrieveOrderResponse = <String, Object?>{
  'order': <String, Object?>{
    'id': 'sq_ord_004',
    'location_id': 'L_RESTAURANT_A',
    'created_at': '2026-05-03T21:00:00Z',
    'updated_at': '2026-05-03T21:30:00Z',
    'closed_at': '2026-05-03T21:30:00Z',
    'total_money': <String, Object?>{
      'amount': 2750,
      'currency': 'CAD',
    },
    'state': 'COMPLETED',
  },
};

/// Locations response — the connect flow + test-connection modal.
const List<Map<String, Object?>> sampleLocations = <Map<String, Object?>>[
  <String, Object?>{
    'id': 'L_RESTAURANT_A',
    'name': 'Restaurant A',
    'timezone': 'America/Toronto',
    'currency': 'CAD',
  },
  <String, Object?>{
    'id': 'L_RESTAURANT_B',
    'name': 'Restaurant B',
    'timezone': 'America/Toronto',
    'currency': 'CAD',
  },
];

/// Helper — returns a deep copy so tests can mutate without
/// contaminating subsequent runs.
Map<String, Object?> cloneOrder(Map<String, Object?> order) {
  final clone = Map<String, Object?>.from(order);
  final tm = order['total_money'];
  if (tm is Map) {
    clone['total_money'] = Map<String, Object?>.from(
      tm.map((k, v) => MapEntry(k.toString(), v)),
    );
  }
  return clone;
}
