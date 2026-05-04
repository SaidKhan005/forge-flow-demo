// Phase 8R.LB — Libro reservations fixture (engineering slice).
//
// Source documentation: https://libroreserve.github.io/api-documentation/
// Retrieved: 2026-05-04 (pinned in
// docs/integrations/libro/api_consumed.md).
//
// `documented_per_libro_v1` is the contract-of-record for the Libro
// adapter's field-mapping. Every row in
// `docs/integrations/libro/field_mapping.md` MUST appear here as a
// `<vendor_path>` constant; every constant here MUST appear in that
// table. The `8R.LB.live.sandbox` slice diffs observed sandbox
// payloads against this map.

import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';

/// Contract-of-record for Libro v1 reservation field mapping. Mirrors
/// `docs/integrations/libro/field_mapping.md`.
///
/// Naming pinned by `docs/contracts/per_vendor_doc_pack_contract.md`
/// — `documented_per_<vendor>_<api_version>` is the required shape so
/// Codex can grep across adapters. lowerCamelCase lint disabled by
/// contract.
// ignore: constant_identifier_names
const Map<String, Object?> documented_per_libro_v1 = <String, Object?>{
  'api_version': 'v1',
  'doc_url': 'https://libroreserve.github.io/api-documentation/',
  'retrieved_at': '2026-05-04',
  // Vendor → canonical field map.
  'fields': <String, Object?>{
    'id': <String, String>{
      'canonical': 'vendor_entity_id',
      'transform': 'direct',
      'type': 'string',
    },
    'venue_id': <String, String>{
      'canonical': 'connector_connection.metadata.venue_id',
      'transform': 'direct',
      'type': 'string',
    },
    'size': <String, String>{
      'canonical': 'party_size',
      'transform': 'direct',
      'type': 'int',
    },
    'status': <String, String>{
      'canonical': 'status',
      'transform': 'normalize_via_LibroReservationAdapter._normalizeStatus',
      'type': 'enum<string>',
    },
    'reservation_at': <String, String>{
      'canonical': 'reservation_at',
      'transform':
          'project_via_iana_using_vendor_timestamp_policy.libro=asLocationLocal',
      'type': 'iso8601_no_tz',
    },
    'updated_at': <String, String>{
      'canonical': 'vendor_modified_at',
      'transform':
          'project_via_iana_using_vendor_timestamp_policy.libro=asLocationLocal',
      'type': 'iso8601_no_tz',
    },
    'created_at': <String, String>{
      'canonical': 'status_transitions.expected',
      'transform': 'project_via_iana',
      'type': 'iso8601_no_tz',
    },
    'confirmed_at': <String, String>{
      'canonical': 'status_transitions.confirmed',
      'transform': 'project_via_iana',
      'type': 'iso8601_no_tz',
    },
    'arrived_at': <String, String>{
      'canonical': 'status_transitions.arrived',
      'transform': 'project_via_iana',
      'type': 'iso8601_no_tz',
    },
    'seated_at': <String, String>{
      'canonical': 'status_transitions.seated',
      'transform': 'project_via_iana',
      'type': 'iso8601_no_tz',
    },
    'completed_at': <String, String>{
      'canonical': 'status_transitions.completed',
      'transform': 'project_via_iana',
      'type': 'iso8601_no_tz',
    },
    'canceled_at': <String, String>{
      'canonical': 'status_transitions.canceled',
      'transform': 'project_via_iana',
      'type': 'iso8601_no_tz',
    },
    'notes': <String, String>{
      'canonical': '<forbidden — operator-supplied free text>',
      'transform': 'drop',
      'type': 'string',
    },
  },
  // Status vocabulary documented per Libro v1.
  'status_vocabulary': <String>[
    'pending',
    'confirmed',
    'arrived',
    'seated',
    'completed',
    'canceled',
    'no_show',
  ],
  // Pagination shape: cursor pagination via `next_cursor` token in the
  // page envelope (see api_consumed.md).
  'pagination': <String, String>{
    'shape': 'cursor',
    'cursor_field': 'next_cursor',
    'page_size_param': 'page_size',
    'updated_since_param': 'updated_since',
    'updated_before_param': 'updated_before',
  },
  // Covers source classification — reservations have no `covers`
  // field; the COVERS card is the POS adapter's job. The reservation
  // adapter contributes the "In the Books" aggregate count, not
  // covers.
  'covers_source': 'not_applicable',
};

/// Sample one-page payload — `created` reservation 2 hours ahead.
const Map<String, Object?> libroReservationPagePayloadCreated =
    <String, Object?>{
  'reservations': <Map<String, Object?>>[
    <String, Object?>{
      'id': 'lbr-evt-7c2f-001',
      'venue_id': 'venue-toronto-yorkville',
      'size': 4,
      'status': 'pending',
      'reservation_at': '2026-05-04T19:00:00',
      'created_at': '2026-05-04T11:30:00',
      'updated_at': '2026-05-04T11:30:00',
      'notes': 'window seat preferred',
    },
  ],
  'next_cursor': null,
};

/// Sample two-page payload — page 1 of 2 (`next_cursor` present).
const Map<String, Object?> libroReservationPagePayloadFirstOfTwo =
    <String, Object?>{
  'reservations': <Map<String, Object?>>[
    <String, Object?>{
      'id': 'lbr-evt-7c2f-002',
      'venue_id': 'venue-toronto-yorkville',
      'size': 2,
      'status': 'confirmed',
      'reservation_at': '2026-05-04T18:30:00',
      'created_at': '2026-05-04T10:15:00',
      'confirmed_at': '2026-05-04T10:20:00',
      'updated_at': '2026-05-04T10:20:00',
    },
  ],
  'next_cursor': 'cursor-page-2',
};

const Map<String, Object?> libroReservationPagePayloadSecondOfTwo =
    <String, Object?>{
  'reservations': <Map<String, Object?>>[
    <String, Object?>{
      'id': 'lbr-evt-7c2f-003',
      'venue_id': 'venue-toronto-yorkville',
      'size': 6,
      'status': 'seated',
      'reservation_at': '2026-05-04T17:45:00',
      'created_at': '2026-05-04T09:00:00',
      'confirmed_at': '2026-05-04T09:01:00',
      'arrived_at': '2026-05-04T17:42:00',
      'seated_at': '2026-05-04T17:46:00',
      'updated_at': '2026-05-04T17:46:00',
    },
  ],
  'next_cursor': null,
};

/// Helper: build a `LibroReservationDto` from a fixture map.
LibroReservationDto fixtureDtoFromMap(Map<String, Object?> map) =>
    LibroReservationDto.fromMap(map);
