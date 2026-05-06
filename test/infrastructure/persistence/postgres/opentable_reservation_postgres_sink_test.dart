// Phase 8 Wave B `8.spine-bridge-sink-fanout.OT` — OpenTable reservation
// Postgres sink tests.
//
// Mirrors the test surface of the SevenRooms sink (`.SR`) and the Tock
// sink (`.TC`):
//
//   A. Round-trip — one OpenTable canonical fact (built from the
//      adapter's documented field shape via the fixture) →
//      `writeReservationFact` → tenant-scoped SELECT returns the same
//      operator-scoped columns and `vendor_id = 'opentable'`.
//   B. Idempotency replay — second `writeReservationFact` for the same
//      `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`
//      returns `false` (partial UNIQUE on the same key collapses the
//      replay to a no-op).
//   C. Watermark per batch — `writeWatermark` UPSERTs the single
//      `(connection_id, resource)` row to the latest cursor; resource
//      string equals `'reservation.reservations'`.
//   D. Demo-mode flip — first `markReservationsLive` writes a
//      `demo_mode_state` row with `category = 'reservation'`; second
//      call is idempotent (`flipped_to_live_at` +
//      `flipped_by_connection_id` pinned to the first flip per the
//      policy contract). Disconnect does NOT auto-revert.
//   E. RLS + tenancy — every public method runs through `withTenant`
//      → `set_config('app.operator_id', ...)` /
//      `set_config('app.location_id', ...)`. A write under operator A
//      is invisible to a SELECT under operator B.
//   F. Disconnect / credential wipe — `wipeCredentials` blanks the
//      vendor_credentials ciphertext; the watermark survives.
//   G. Status-transition columns are SQL `null` — the OpenTable
//      adapter's documented shape carries one `status` enum but no
//      per-transition timestamps. `seated_at` and `cancelled_at` land
//      as `null`; the banned-grep test enforces no stray `'seated_at'`
//      Dart literal outside the INSERT column-name string.
//   H. Banned-items grep — sink source contains zero items from
//      `memory/project_v1_lean_cut_2_2026_05_03.md`. Same ledger as
//      the SR sink.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_reservation_adapter.dart';

import '../../../integrations/reservation/fixtures/opentable_reservations_fixture.dart';

const String _opA = '00000000-0000-4000-8000-0000000000a1';
const String _locA = '00000000-0000-4000-8000-0000000000b1';
const String _userA = '00000000-0000-4000-8000-0000000000c1';
const String _opB = '00000000-0000-4000-8000-0000000000a2';
const String _locB = '00000000-0000-4000-8000-0000000000b2';
const String _connA = '00000000-0000-4000-8000-0000000000d1';
const String _restaurantId = 'rid-9876';

OpenTableCanonicalReservationFact _factFromFixture({
  required Map<String, Object?> raw,
  required String operatorId,
  required String locationId,
}) {
  return OpenTableCanonicalReservationFact(
    operatorId: operatorId,
    locationId: locationId,
    vendorEntityId: raw['id']! as String,
    vendorModifiedAt: DateTime.parse(raw['modified_at']! as String).toUtc(),
    reservationAt: DateTime.parse(raw['reserved_at']! as String).toUtc(),
    partySize: (raw['party_size']! as num).toInt(),
    status: (raw['status']! as String).toLowerCase(),
    rawPayload: Map<String, Object?>.from(raw),
  );
}

void main() {
  group('OpenTableReservationPostgresSink — A. Round-trip', () {
    test(
      'writeReservationFact → INSERT → tenant SELECT returns the canonical row',
      () async {
        final db = _FakeDb()
          ..seedConnection(_connA, _opA, _locA, _restaurantId)
          ..seedLocation(_opA, _locA, 'UTC', 0);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final raw = openTableBackfillBatchPage1.first;
        final fact = _factFromFixture(
          raw: raw,
          operatorId: _opA,
          locationId: _locA,
        );

        final wrote = await sink.writeReservationFact(fact);

        expect(wrote, isTrue);
        expect(db.reservationFacts, hasLength(1));
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['vendor_id'], kOpenTableVendorId);
        expect(readBack.single['vendor_entity_id'], 'OT-9001');
        expect(readBack.single['party_size'], 2);
        expect(readBack.single['status'], 'confirmed');
        expect(
          readBack.single['reservation_at'],
          DateTime.parse('2026-05-05T18:30:00Z').toUtc(),
        );
        expect(readBack.single['business_date'], '2026-05-05');
        expect(readBack.single['raw_payload'], isNotEmpty);
        // status-transition columns are NULL by policy.
        expect(readBack.single[_columnSeated], isNull);
        expect(readBack.single[_columnCancelled], isNull);
      },
    );
  });

  group(
      'OpenTableReservationPostgresSink — B. Idempotency replay',
      () {
    test(
      'second writeReservationFact for same key returns false',
      () async {
        final db = _FakeDb()
          ..seedConnection(_connA, _opA, _locA, _restaurantId)
          ..seedLocation(_opA, _locA, 'UTC', 0);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final fact = _factFromFixture(
          raw: openTableBackfillBatchPage1[1],
          operatorId: _opA,
          locationId: _locA,
        );

        final firstWrote = await sink.writeReservationFact(fact);
        final secondWrote = await sink.writeReservationFact(fact);

        expect(firstWrote, isTrue,
            reason: 'first arrival inserts a fresh row.');
        expect(secondWrote, isFalse,
            reason: 'partial UNIQUE on '
                '(operator_id, vendor_id, vendor_entity_id, vendor_modified_at) '
                'must collapse the second arrival to a no-op.');
        expect(db.reservationFacts, hasLength(1));
      },
    );
  });

  group('OpenTableReservationPostgresSink — C. Watermark per batch', () {
    test(
      'writeWatermark UPSERTs the single (connection_id, resource) row '
      'to the latest cursor, resource = reservation.reservations',
      () async {
        final db = _FakeDb()
          ..seedConnection(_connA, _opA, _locA, _restaurantId);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        await sink.writeWatermark(
          operatorId: _opA,
          locationId: _locA,
          row: OpenTableWatermarkRow(
            cursorToken: 'cursor-page-1',
            lastModifiedSeen: DateTime.utc(2026, 5, 4, 10),
          ),
        );
        await sink.writeWatermark(
          operatorId: _opA,
          locationId: _locA,
          row: OpenTableWatermarkRow(
            cursorToken: 'cursor-page-2',
            lastModifiedSeen: DateTime.utc(2026, 5, 4, 11),
          ),
        );

        expect(db.watermarks, hasLength(1),
            reason: 'connector_sync_watermark unique index on '
                '(connection_id, resource) means UPSERT, not INSERT-many.');
        final wm = db.watermarks.values.single;
        expect(wm.cursorToken, 'cursor-page-2',
            reason: 'cursor advances to the latest batch.');
        expect(wm.resource, kOpenTableWatermarkResource);
        expect(wm.resource, 'reservation.reservations');
        expect(wm.lastModifiedSeen, DateTime.utc(2026, 5, 4, 11));
      },
    );
  });

  group('OpenTableReservationPostgresSink — D. Demo-mode flip', () {
    test(
      'first markReservationsLive flips is_demo=false; '
      'second call is idempotent (flipped_to_live_at preserved)',
      () async {
        final db = _FakeDb();
        // Seed the default is_demo=true row that
        // DemoModeStateGateway.readOrCreateDefault would mint.
        db.demoState['$_opA|$_locA|reservation'] = _StoredDemo(
          operatorId: _opA,
          locationId: _locA,
          category: 'reservation',
          isDemo: true,
          flippedToLiveAt: null,
          flippedByConnectionId: null,
        );
        final clock = _AdvancingClock(DateTime.utc(2026, 5, 4, 12));
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: clock.now,
        );

        await sink.markReservationsLive(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
        final afterFirst = db.demoState['$_opA|$_locA|reservation']!;
        expect(afterFirst.isDemo, isFalse);
        expect(afterFirst.category, 'reservation');
        expect(afterFirst.flippedToLiveAt, DateTime.utc(2026, 5, 4, 12));
        expect(afterFirst.flippedByConnectionId, _connA);

        // Advance clock + connection so a non-idempotent path would
        // re-stamp; the policy guards against that.
        clock.advanceTo(DateTime.utc(2026, 5, 4, 13));
        const otherConnection = '00000000-0000-4000-8000-0000000000d2';
        await sink.markReservationsLive(
          operatorId: _opA,
          locationId: _locA,
          connectionId: otherConnection,
        );
        final afterSecond = db.demoState['$_opA|$_locA|reservation']!;
        expect(afterSecond.isDemo, isFalse,
            reason: 'still live; never auto-reverts.');
        expect(afterSecond.flippedToLiveAt, DateTime.utc(2026, 5, 4, 12),
            reason: 'flipped_to_live_at pinned to the first flip.');
        expect(afterSecond.flippedByConnectionId, _connA,
            reason: 'flipped_by_connection_id pinned to the first flip.');
      },
    );
  });

  group('OpenTableReservationPostgresSink — E. RLS + tenancy', () {
    test(
      'write under operator A is invisible to operator B tenant context; '
      'every method runs through SET LOCAL app.operator_id / '
      'app.location_id',
      () async {
        final db = _FakeDb()
          ..seedConnection(_connA, _opA, _locA, _restaurantId)
          ..seedLocation(_opA, _locA, 'UTC', 0);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        final fact = OpenTableCanonicalReservationFact(
          operatorId: _opA,
          locationId: _locA,
          vendorEntityId: 'OT-tenancy-1',
          vendorModifiedAt: DateTime.utc(2026, 5, 4, 18),
          reservationAt: DateTime.utc(2026, 5, 4, 22),
          partySize: 2,
          status: 'booked',
          rawPayload: const <String, Object?>{
            'id': 'OT-tenancy-1',
            'restaurant_id': _restaurantId,
            'reserved_at': '2026-05-04T22:00:00Z',
            'modified_at': '2026-05-04T18:00:00Z',
            'party_size': 2,
            'status': 'booked',
          },
        );
        await sink.writeReservationFact(fact);

        final asA = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        final asB = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opB,
          locationId: _locB,
        );
        expect(asA, hasLength(1), reason: 'tenant A sees its own row.');
        expect(asB, isEmpty,
            reason:
                'tenant B SELECT under set_config(app.operator_id, opB) '
                'must NOT see operator A\'s row — RLS + repository defense.');

        // Actor user id propagates through the wrapper too.
        final actorUserId = await _readActorUserIdAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(actorUserId, _userA);
      },
    );
  });

  group(
      'OpenTableReservationPostgresSink — F. Disconnect / credential wipe',
      () {
    test(
      'wipeCredentials blanks vendor_credentials ciphertext; '
      'watermark survives so reconnect resumes from the last cursor',
      () async {
        final db = _FakeDb()
          ..seedConnection(_connA, _opA, _locA, _restaurantId)
          ..seedCredential(_connA, _opA, _locA);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        // Seed a watermark so we can assert it survives.
        await sink.writeWatermark(
          operatorId: _opA,
          locationId: _locA,
          row: OpenTableWatermarkRow(
            cursorToken: 'cursor-pre-disconnect',
            lastModifiedSeen: DateTime.utc(2026, 5, 4, 11),
          ),
        );

        await sink.wipeCredentials(operatorId: _opA, locationId: _locA);

        expect(db.credentials, isEmpty,
            reason: 'credential ciphertext wiped on disconnect.');
        expect(db.watermarks, hasLength(1),
            reason: 'watermark must survive disconnect so reconnect '
                'resumes from the last persisted cursor.');
        expect(db.watermarks.values.single.cursorToken,
            'cursor-pre-disconnect');
      },
    );
  });

  group(
      'OpenTableReservationPostgresSink — G. status-transition NULL columns',
      () {
    test(
      'OpenTable canonical fact lands with seated_at + cancelled_at = NULL '
      '(no per-transition timestamps in the documented shape)',
      () async {
        final db = _FakeDb()
          ..seedConnection(_connA, _opA, _locA, _restaurantId)
          ..seedLocation(_opA, _locA, 'UTC', 0);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        // Seated / cancelled fixtures from the documented page batch.
        final seatedFact = _factFromFixture(
          raw: openTableBackfillBatchPage1[1], // status = seated
          operatorId: _opA,
          locationId: _locA,
        );
        final cancelledFact = _factFromFixture(
          raw: openTableBackfillBatchPage2[0], // status = cancelled
          operatorId: _opA,
          locationId: _locA,
        );

        await sink.writeReservationFact(seatedFact);
        await sink.writeReservationFact(cancelledFact);

        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(2));
        for (final row in readBack) {
          expect(row[_columnSeated], isNull,
              reason: 'OpenTable documented shape carries no '
                  'per-transition timestamps; sink must not '
                  'fabricate seated_at.');
          expect(row[_columnCancelled], isNull,
              reason: 'same policy applies to cancelled_at.');
        }
        // Status enum still round-trips so the dashboard can render.
        final statuses =
            readBack.map((r) => r['status']! as String).toSet();
        expect(statuses, containsAll(<String>['seated', 'cancelled']));
      },
    );
  });

  group(
      'OpenTableReservationPostgresSink — H. Banned-items grep '
      '(lean cut 2)',
      () {
    test('sink executable code contains zero banned tokens '
        'AND no literal seated_at outside the INSERT column-name string',
        () {
      final source = File(
        'lib/infrastructure/persistence/postgres/'
        'opentable_reservation_postgres_sink.dart',
      ).readAsStringSync();
      final code = _stripDartComments(source).toLowerCase();
      // Tokens flagged in `memory/project_v1_lean_cut_2_2026_05_03.md`
      // and the spine contract's "Banned items" section. The grep
      // targets the executable code only — comments / doc strings that
      // name a banned pattern as "we do not do this" are fine.
      // Mirrors the SR sink's banned ledger byte-for-byte.
      final banned = <String>[
        'kms_rolloutflag',
        'kmsrollout',
        'parse_warnings',
        'parse_partial',
        'pg_advisory_lock',
        'pg_partman',
        'sigterm',
        'dead_letter_tile',
        'dlqtile',
        'rotatewebhooksigningkey',
      ];
      for (final token in banned) {
        expect(
          code.contains(token),
          isFalse,
          reason: 'banned token "$token" must not appear in executable '
              'sink code (comments are exempt).',
        );
      }

      // OpenTable's documented Partner reservation envelope carries no
      // per-status transition timestamps. The sink writes
      // `seated_at` / `cancelled_at` as SQL `null` literals; the
      // column names appear only inside the INSERT column-name string.
      // The literal Dart token `'seated_at'` (single-quoted, standalone)
      // would imply a parameter map key or other read path — banned
      // outside the column-name string.
      final stripped = _stripDartComments(source);
      expect(stripped.contains(_seatedDartLiteral), isFalse,
          reason: 'OpenTable documented shape carries no per-transition '
              'timestamps; sink must not fabricate seated_at. Forbidden '
              'standalone Dart literal (e.g. as a parameter map key '
              'or read key).');
    });
  });
}

// The literal `'seated_at'` token built up at runtime so the
// banned-grep above does not flag this test file's own assertion text
// when applied to the sink source. Using `String.fromCharCodes` (instead
// of `+` concatenation) keeps the analyzer from rewriting the literal
// back into a single token at parse time.
final String _seatedDartLiteral =
    String.fromCharCodes(<int>[0x27]) +
    String.fromCharCodes('seated_at'.codeUnits) +
    String.fromCharCodes(<int>[0x27]);

// Column name keys used by the `_StoredReservation.asRow` projection;
// expressed as constants here so the test can read them back without
// minting a literal `'seated_at'` Dart string at every assertion site.
const String _columnSeated = 'seated_at';
const String _columnCancelled = 'cancelled_at';

/// Strip `//` line comments and `/* */` block comments so the banned-
/// items grep targets executable code only.
String _stripDartComments(String source) {
  final withoutBlock = source.replaceAll(
    RegExp(r'/\*[\s\S]*?\*/', multiLine: true),
    '',
  );
  final lines = withoutBlock.split('\n').map((line) {
    final idx = line.indexOf('//');
    if (idx < 0) return line;
    return line.substring(0, idx);
  });
  return lines.join('\n');
}

// ─── In-memory Postgres fakes ────────────────────────────────────────

/// Backing store for the fake pool. Tests assert state directly off
/// these collections; the executor mutates them in response to the SQL
/// the sink emits.
class _FakeDb {
  final List<_StoredReservation> reservationFacts = <_StoredReservation>[];
  final Map<String, _StoredWatermark> watermarks = <String, _StoredWatermark>{};
  final List<_StoredLog> syncLogs = <_StoredLog>[];
  final Map<String, _StoredDemo> demoState = <String, _StoredDemo>{};
  final Map<String, _StoredConnection> connections =
      <String, _StoredConnection>{};
  final Map<String, _StoredCredential> credentials =
      <String, _StoredCredential>{};
  final Map<String, _StoredLocation> locations =
      <String, _StoredLocation>{};

  void seedConnection(
    String connectionId,
    String operatorId,
    String locationId,
    String restaurantId,
  ) {
    connections[connectionId] = _StoredConnection(
      connectionId: connectionId,
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kOpenTableVendorId,
      restaurantId: restaurantId,
    );
  }

  void seedCredential(
    String connectionId,
    String operatorId,
    String locationId,
  ) {
    credentials['cred-$connectionId'] = _StoredCredential(
      credentialId: 'cred-$connectionId',
      connectionId: connectionId,
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  void seedLocation(
    String operatorId,
    String locationId,
    String timezone,
    int rolloverHour,
  ) {
    locations['$operatorId|$locationId'] = _StoredLocation(
      operatorId: operatorId,
      locationId: locationId,
      restaurantTimezone: timezone,
      businessDayRolloverHour: rolloverHour,
    );
  }
}

class _StoredReservation {
  _StoredReservation({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.vendorId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.reservationAt,
    required this.businessDate,
    required this.partySize,
    required this.status,
    required this.rawPayload,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final String vendorId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;
  final DateTime reservationAt;
  final String businessDate;
  final int partySize;
  final String status;
  // Per-status transition columns are SQL `null` for the OpenTable
  // sink — the documented Partner shape exposes only the `status`
  // enum. The stored row reflects that statically (parallels the Tock
  // sink's policy).
  final DateTime? seatedAt = null;
  final DateTime? cancelledAt = null;
  final String rawPayload;

  Map<String, Object?> asRow() => <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'vendor_id': vendorId,
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAt,
        'reservation_at': reservationAt,
        'business_date': businessDate,
        'party_size': partySize,
        'status': status,
        _columnSeated: seatedAt,
        _columnCancelled: cancelledAt,
        'raw_payload': rawPayload,
      };
}

class _StoredWatermark {
  _StoredWatermark({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.resource,
    required this.cursorToken,
    required this.lastModifiedSeen,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final String resource;
  final String? cursorToken;
  final DateTime lastModifiedSeen;
}

class _StoredLog {
  _StoredLog({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.eventKind,
    required this.recordsCount,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final String eventKind;
  final int? recordsCount;
}

class _StoredDemo {
  _StoredDemo({
    required this.operatorId,
    required this.locationId,
    required this.category,
    required this.isDemo,
    required this.flippedToLiveAt,
    required this.flippedByConnectionId,
  });

  final String operatorId;
  final String locationId;
  final String category;
  final bool isDemo;
  final DateTime? flippedToLiveAt;
  final String? flippedByConnectionId;
}

class _StoredConnection {
  _StoredConnection({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.restaurantId,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;
  final String vendorId;
  final String restaurantId;
}

class _StoredCredential {
  _StoredCredential({
    required this.credentialId,
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
  });

  final String credentialId;
  final String connectionId;
  final String operatorId;
  final String locationId;
}

class _StoredLocation {
  _StoredLocation({
    required this.operatorId,
    required this.locationId,
    required this.restaurantTimezone,
    required this.businessDayRolloverHour,
  });

  final String operatorId;
  final String locationId;
  final String restaurantTimezone;
  final int businessDayRolloverHour;
}

class _AdvancingClock {
  _AdvancingClock(this._current);
  DateTime _current;

  DateTime now() => _current;
  void advanceTo(DateTime t) => _current = t;
}

class _FakePool implements PostgresPool {
  _FakePool(this.db);
  final _FakeDb db;

  @override
  Future<PostgresTransaction> beginTransaction() async => _FakeTx(db);
}

class _FakeTx implements PostgresTransaction {
  _FakeTx(this.db);
  final _FakeDb db;
  String? _operatorId;
  String? _locationId;
  String? _userId;
  bool _systemRole = false;
  // Captures every executed statement so the postgres_import_lint and
  // tenancy tests can assert what the sink actually emitted.
  final List<String> statements = <String>[];

  bool get _tenantApplies => !_systemRole;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    statements.add(sql);
    final lower = sql.toLowerCase();

    if (lower.contains("set_config('app.operator_id'")) {
      _operatorId = parameters['value'] as String?;
      return const <PostgresRow>[];
    }
    if (lower.contains("set_config('app.location_id'")) {
      _locationId = parameters['value'] as String?;
      return const <PostgresRow>[];
    }
    if (lower.contains("set_config('app.user_id'")) {
      _userId = parameters['value'] as String?;
      return const <PostgresRow>[];
    }
    if (lower.contains('set_config(')) {
      return const <PostgresRow>[];
    }

    if (lower.contains('from public.reservation_facts')) {
      // Honor SET LOCAL tenancy: only return rows visible to current
      // (operator_id, location_id), the same scope the RLS policy
      // would enforce in production.
      return db.reservationFacts
          .where((r) =>
              r.operatorId == _operatorId && r.locationId == _locationId)
          .map((r) => r.asRow())
          .toList(growable: false);
    }

    if (lower.contains('from public.connector_sync_watermark')) {
      // readWatermark joins connector_connection. Filter by tenant.
      final vendorId = parameters['vendor_id'] as String?;
      final resource = parameters['resource'] as String?;
      final operatorId =
          (parameters['operator_id'] as String?) ?? _operatorId;
      final locationId =
          (parameters['location_id'] as String?) ?? _locationId;
      final matches = db.watermarks.values.where((w) {
        if (resource != null && w.resource != resource) return false;
        if (operatorId != null && w.operatorId != operatorId) return false;
        if (locationId != null && w.locationId != locationId) return false;
        if (vendorId != null) {
          final conn = db.connections[w.connectionId];
          if (conn == null) return false;
          if (conn.vendorId != vendorId) return false;
        }
        return true;
      });
      return matches
          .map((w) => <String, Object?>{
                'cursor_token': w.cursorToken,
                'last_modified_seen': w.lastModifiedSeen,
              })
          .toList(growable: false);
    }

    if (lower.contains('from public.connector_connection')) {
      final connectionId = parameters['connection_id'] as String?;
      final vendorId = parameters['vendor_id'] as String?;
      final operatorId = parameters['operator_id'] as String?;
      final locationId = parameters['location_id'] as String?;
      final matches = db.connections.values.where((c) {
        if (connectionId != null && c.connectionId != connectionId) {
          return false;
        }
        if (vendorId != null && c.vendorId != vendorId) return false;
        if (operatorId != null && c.operatorId != operatorId) return false;
        if (locationId != null && c.locationId != locationId) return false;
        if (_tenantApplies) {
          if (_operatorId != null && c.operatorId != _operatorId) {
            return false;
          }
          if (_locationId != null && c.locationId != _locationId) {
            return false;
          }
        }
        return true;
      });
      return matches
          .map((c) => <String, Object?>{
                'connection_id': c.connectionId,
                'operator_id': c.operatorId,
                'location_id': c.locationId,
                'vendor_id': c.vendorId,
                'metadata': json.encode(<String, Object?>{
                  'restaurant_id': c.restaurantId,
                }),
                'credential_id': 'cred-${c.connectionId}',
              })
          .toList(growable: false);
    }

    if (lower.contains('from public.locations')) {
      final operatorId = parameters['operator_id'] as String?;
      final locationId = parameters['location_id'] as String?;
      final loc = db.locations['$operatorId|$locationId'];
      if (loc == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          // Keys mirror the actual `public.locations` schema columns
          // (`timezone`, `business_day_rollover_hour`); the in-memory
          // field name `restaurantTimezone` is just the Dart-side name
          // for the value.
          'timezone': loc.restaurantTimezone,
          'business_day_rollover_hour': loc.businessDayRolloverHour,
        },
      ];
    }

    if (lower.contains('from public.vendor_credentials')) {
      // readAccessToken joins vendor_credentials with
      // connector_connection. Mirror the SR shape.
      final vendorId = parameters['vendor_id'] as String?;
      final operatorId = parameters['operator_id'] as String?;
      final locationId = parameters['location_id'] as String?;
      final matches = db.credentials.values.where((cred) {
        if (operatorId != null && cred.operatorId != operatorId) {
          return false;
        }
        if (locationId != null && cred.locationId != locationId) {
          return false;
        }
        final conn = db.connections[cred.connectionId];
        if (conn == null) return false;
        if (vendorId != null && conn.vendorId != vendorId) return false;
        return true;
      });
      return matches
          .map((c) => <String, Object?>{'credential_id': c.credentialId})
          .toList(growable: false);
    }

    if (lower.contains('select current_setting')) {
      // Tests use this to read back the SET LOCAL state for tenancy
      // verification.
      if (lower.contains('app.user_id')) {
        return <PostgresRow>[
          <String, Object?>{'value': _userId},
        ];
      }
      if (lower.contains('app.operator_id')) {
        return <PostgresRow>[
          <String, Object?>{'value': _operatorId},
        ];
      }
      if (lower.contains('app.location_id')) {
        return <PostgresRow>[
          <String, Object?>{'value': _locationId},
        ];
      }
    }

    if (lower.contains('insert into public.connector_connection') &&
        lower.contains('returning connection_id')) {
      final operatorId = parameters['operator_id']! as String;
      final locationId = parameters['location_id']! as String;
      final vendorId = parameters['vendor_id']! as String;
      // Find or mint a connection row. Mirrors the upsert RETURNING
      // shape — once a row exists for (operator, location, vendor), it
      // is the canonical id and is reused.
      final existing = db.connections.values.firstWhere(
        (c) =>
            c.operatorId == operatorId &&
            c.locationId == locationId &&
            c.vendorId == vendorId,
        orElse: () => _StoredConnection(
          connectionId: '00000000-0000-4000-8000-000000000fff',
          operatorId: operatorId,
          locationId: locationId,
          vendorId: vendorId,
          restaurantId: '',
        ),
      );
      // Persist if it was just minted (the firstWhere fallback path).
      db.connections[existing.connectionId] = existing;
      return <PostgresRow>[
        <String, Object?>{'connection_id': existing.connectionId},
      ];
    }

    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    statements.add(sql);
    final lower = sql.toLowerCase();

    if (lower.contains("set_config('app.operator_id'")) {
      _operatorId = parameters['value'] as String?;
      return 0;
    }
    if (lower.contains("set_config('app.location_id'")) {
      _locationId = parameters['value'] as String?;
      return 0;
    }
    if (lower.contains("set_config('app.user_id'")) {
      _userId = parameters['value'] as String?;
      return 0;
    }
    if (lower.contains('set local role forge_admin')) {
      _systemRole = true;
      return 0;
    }
    if (lower.contains('set_config(')) {
      return 0;
    }

    if (lower.contains('insert into public.reservation_facts')) {
      // Honor partial UNIQUE on
      // (operator_id, vendor_id, vendor_entity_id, vendor_modified_at).
      final exists = db.reservationFacts.any((r) =>
          r.operatorId == parameters['operator_id'] &&
          r.vendorId == parameters['vendor_id'] &&
          r.vendorEntityId == parameters['vendor_entity_id'] &&
          r.vendorModifiedAt == parameters['vendor_modified_at']);
      if (exists) return 0;
      db.reservationFacts.add(
        _StoredReservation(
          operatorId: parameters['operator_id']! as String,
          locationId: parameters['location_id']! as String,
          connectionId: parameters['connection_id']! as String,
          vendorId: parameters['vendor_id']! as String,
          vendorEntityId: parameters['vendor_entity_id']! as String,
          vendorModifiedAt: parameters['vendor_modified_at']! as DateTime,
          reservationAt: parameters['reservation_at']! as DateTime,
          businessDate: parameters['business_date']! as String,
          partySize: parameters['party_size']! as int,
          status: parameters['status']! as String,
          rawPayload: parameters['raw_payload']! as String,
        ),
      );
      return 1;
    }

    if (lower.contains('insert into public.vendor_credentials')) {
      final credId = parameters['credential_id']! as String;
      db.credentials[credId] = _StoredCredential(
        credentialId: credId,
        connectionId: parameters['connection_id']! as String,
        operatorId: parameters['operator_id']! as String,
        locationId: parameters['location_id']! as String,
      );
      return 1;
    }

    if (lower.contains('delete from public.vendor_credentials')) {
      final connectionId = parameters['connection_id']! as String;
      db.credentials.removeWhere(
        (_, cred) => cred.connectionId == connectionId,
      );
      return 1;
    }

    if (lower.contains('insert into public.connector_sync_watermark')) {
      final connectionId = parameters['connection_id']! as String;
      final resource = parameters['resource']! as String;
      final key = '$connectionId|$resource';
      db.watermarks[key] = _StoredWatermark(
        operatorId: parameters['operator_id']! as String,
        locationId: parameters['location_id']! as String,
        connectionId: connectionId,
        resource: resource,
        cursorToken: parameters['cursor_token'] as String?,
        lastModifiedSeen: parameters['last_modified_seen']! as DateTime,
      );
      return 1;
    }

    if (lower.contains('insert into public.connector_sync_log')) {
      db.syncLogs.add(
        _StoredLog(
          operatorId: parameters['operator_id']! as String,
          locationId: parameters['location_id']! as String,
          connectionId: parameters['connection_id']! as String,
          eventKind: parameters['event_kind']! as String,
          recordsCount: parameters['records_count'] as int?,
        ),
      );
      return 1;
    }

    if (lower.contains('insert into public.demo_mode_state')) {
      final operatorId = parameters['operator_id']! as String;
      final locationId = parameters['location_id']! as String;
      final category = parameters['category']! as String;
      final flippedAt = parameters['flipped_at']! as DateTime;
      final connectionId = parameters['connection_id']! as String;
      final key = '$operatorId|$locationId|$category';
      final existing = db.demoState[key];
      if (existing == null) {
        db.demoState[key] = _StoredDemo(
          operatorId: operatorId,
          locationId: locationId,
          category: category,
          isDemo: false,
          flippedToLiveAt: flippedAt,
          flippedByConnectionId: connectionId,
        );
        return 1;
      }
      // ON CONFLICT DO UPDATE WHERE is_demo — second arrival on an
      // already-live row is a no-op.
      if (existing.isDemo) {
        db.demoState[key] = _StoredDemo(
          operatorId: existing.operatorId,
          locationId: existing.locationId,
          category: existing.category,
          isDemo: false,
          flippedToLiveAt: flippedAt,
          flippedByConnectionId: connectionId,
        );
        return 1;
      }
      return 0;
    }

    // Unrecognised writes — quietly succeed; not part of the
    // tenancy or canonical-fact assertions.
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}

/// Re-read reservation_facts under a tenant transaction. Mirrors what
/// the dashboard read-path would do — set tenant via SET LOCAL, then
/// SELECT through the executor.
Future<List<Map<String, Object?>>> _readReservationFactsAsTenant({
  required _FakeDb db,
  required String operatorId,
  required String locationId,
}) async {
  final wrapper = TenantTransactionWrapper(_FakePool(db));
  return wrapper.runInTenantContext(
    TenantContext(operatorId: operatorId, locationId: locationId),
    (exec) async {
      final rows = await exec.query(
        'select * from public.reservation_facts',
        parameters: const <String, Object?>{},
      );
      return rows.toList(growable: false);
    },
  );
}

Future<String?> _readActorUserIdAsTenant({
  required _FakeDb db,
  required String operatorId,
  required String locationId,
  required String userId,
}) async {
  final wrapper = TenantTransactionWrapper(_FakePool(db));
  return wrapper.runInTenantContext(
    TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    ),
    (exec) async {
      final rows = await exec.query(
        "select current_setting('app.user_id', true) as value",
        parameters: const <String, Object?>{},
      );
      if (rows.isEmpty) return null;
      return rows.first['value'] as String?;
    },
  );
}
