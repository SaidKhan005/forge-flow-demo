// Phase 8R.SR — SevenRooms reservation fixtures.
//
// Source documentation:
//   * Marketing overview: https://sevenrooms.com/platform/integrations-apis/
//   * Partner API portal (account-rep gated):
//     https://api-docs.sevenrooms.com/
//   * Reservations endpoint shape (Airship guide):
//     https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms
// Retrieved: 2026-05-04.
//
// These fixtures are the canonical specimen of SevenRooms reservation
// objects the adapter consumes. The
// `documented_per_sevenrooms_v2_2_2026_05` constant Map mirrors the
// field-mapping table in `docs/integrations/sevenrooms/field_mapping.md`
// row-for-row. Codex grades the diff between this constant, the doc
// table, and the field accessors in
// `lib/integrations/reservation/sevenrooms_reservation_adapter.dart`.
// Any change to a vendor field path requires updating all three sites.

/// Field-mapping reference. Mirrors `field_mapping.md` row-for-row.
/// The constant name embeds the API version (`kSevenRoomsApiVersion`)
/// so a vendor shape change surfaces as a renamed constant + diff in
/// git history. Per `docs/contracts/per_vendor_doc_pack_contract.md`,
/// the canonical shape is `documented_per_<vendor>_<api_version>`
/// (snake_case).
// ignore: constant_identifier_names
const Map<String, String> documented_per_sevenrooms_v2_2_2026_05 =
    <String, String>{
  // canonical_field: vendor_field_path
  'vendor_entity_id': 'reservations[].id',
  'reservation_at': 'reservations[].arrival_time',
  'party_size': 'reservations[].party_size',
  'status': 'reservations[].status',
  'vendor_modified_at': 'reservations[].last_updated_at',
  'status_transitions.arrived': 'reservations[].arrived_time',
  'status_transitions.seated': 'reservations[].seated_time',
  'status_transitions.departed': 'reservations[].departed_time',
  'status_transitions.cancelled': 'reservations[].cancellation_time',
};

/// Five-record fixture batch the backfill / sanity-hook tests drive.
/// Timestamps are anchored at 2026-05-04 dinner service (business
/// date 2026-05-04 in `America/Toronto`, 4 AM rollover).
List<Map<String, Object?>> sevenRoomsFiveRecordBatch() => <Map<String, Object?>>[
      _reservation(
        id: 'sr-resv-1001',
        arrivalTime: '2026-05-04T22:30:00.000Z',
        partySize: 2,
        status: 'BOOKED',
        lastUpdatedAt: '2026-05-04T18:00:00.000Z',
      ),
      _reservation(
        id: 'sr-resv-1002',
        arrivalTime: '2026-05-04T22:45:00.000Z',
        partySize: 4,
        status: 'ARRIVED',
        lastUpdatedAt: '2026-05-04T22:50:00.000Z',
        arrivedTime: '2026-05-04T22:48:00.000Z',
      ),
      _reservation(
        id: 'sr-resv-1003',
        arrivalTime: '2026-05-04T23:00:00.000Z',
        partySize: 6,
        status: 'SEATED',
        lastUpdatedAt: '2026-05-04T23:10:00.000Z',
        arrivedTime: '2026-05-04T22:55:00.000Z',
        seatedTime: '2026-05-04T23:05:00.000Z',
      ),
      _reservation(
        id: 'sr-resv-1004',
        arrivalTime: '2026-05-04T23:15:00.000Z',
        partySize: 3,
        status: 'CANCELLED',
        lastUpdatedAt: '2026-05-04T20:00:00.000Z',
        cancellationTime: '2026-05-04T20:00:00.000Z',
      ),
      _reservation(
        id: 'sr-resv-1005',
        arrivalTime: '2026-05-04T23:30:00.000Z',
        partySize: 2,
        status: 'BOOKED',
        lastUpdatedAt: '2026-05-04T19:30:00.000Z',
      ),
    ];

/// Sample reservation for the test-connection screen.
Map<String, Object?> sevenRoomsSampleReservation() => _reservation(
      id: 'sr-resv-sample',
      arrivalTime: '2026-05-04T19:00:00.000Z',
      partySize: 4,
      status: 'BOOKED',
      lastUpdatedAt: '2026-05-04T17:00:00.000Z',
    );

/// Future-dated reservation — exercises the framework's sanity rule 2
/// (`reservation_in_future`) when handed to `pollIncremental`.
Map<String, Object?> sevenRoomsFutureDatedReservation({DateTime? referenceUtc}) {
  final now = referenceUtc ?? DateTime.utc(2026, 5, 4, 12, 0, 0);
  return _reservation(
    id: 'sr-resv-future',
    arrivalTime: now.add(const Duration(days: 5)).toIso8601String(),
    partySize: 2,
    status: 'BOOKED',
    lastUpdatedAt: now.toIso8601String(),
  );
}

/// Malformed reservation — missing `id`. Exercises the adapter's
/// boundary parse-drop path (one `connector_sync_log` row, no
/// canonical fact write).
Map<String, Object?> sevenRoomsMalformedReservation() => <String, Object?>{
      'arrival_time': '2026-05-04T19:00:00.000Z',
      'party_size': 2,
      'status': 'BOOKED',
      'last_updated_at': '2026-05-04T17:00:00.000Z',
    };

Map<String, Object?> _reservation({
  required String id,
  required String arrivalTime,
  required int partySize,
  required String status,
  required String lastUpdatedAt,
  String? arrivedTime,
  String? seatedTime,
  String? departedTime,
  String? cancellationTime,
}) =>
    <String, Object?>{
      'id': id,
      'arrival_time': arrivalTime,
      'party_size': partySize,
      'status': status,
      'last_updated_at': lastUpdatedAt,
      if (arrivedTime != null) 'arrived_time': arrivedTime,
      if (seatedTime != null) 'seated_time': seatedTime,
      if (departedTime != null) 'departed_time': departedTime,
      if (cancellationTime != null) 'cancellation_time': cancellationTime,
      // SevenRooms reservation payloads carry guest profile + payment
      // fields the adapter intentionally ignores per `field_mapping.md`
      // Forbidden fields. Keep them present here so the parse path
      // exercises ignored-field behavior.
      'guest': const <String, Object?>{
        'first_name': 'IGNORED',
        'last_name': 'IGNORED',
        'email': 'IGNORED',
      },
      'notes': 'IGNORED',
      'venue_id': 'sr-venue-7c2f',
    };
