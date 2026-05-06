// Phase 8 Wave B `8.spine-bridge.1.OT` — OpenTable Postgres sink
// tests.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) sub-lane `.1.OT`. Mirrors the test surface of `.1.LB`
// (Libro reservations):
//
//   A. Round-trip — adapter materialises a canonical fact, sink
//      upserts, tenant-scoped SELECT returns the same canonical-fact
//      columns.
//   B. Idempotency — same vendor entity / vendor_modified_at twice
//      collapses to a single row (partial UNIQUE on
//      `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`).
//   C. Watermark per batch — every `writeWatermark` call upserts the
//      single `(connection_id, resource)` row to the latest cursor.
//   D. Demo-mode flip(reservation) — first watermark commit with
//      records >= 1 flips `demo_mode_state.is_demo = false`; second
//      call is a no-op (`flipped_to_live_at` +
//      `flipped_by_connection_id` pinned to the first flip).
//   E. RLS + tenancy — a write under operator A's tenant context is
//      invisible to operator B's tenant context.
//   F. Adapter pollIncremental smoke — the OpenTable adapter wired
//      with the sink as gateway walks vendor pages, persists
//      canonical facts, and advances the watermark end-to-end.
//   G. Status-enum round-trip — booked / seated / cancelled all
//      land with the correct V1 status string AND the matching
//      transition timestamp (`seated_at`, `cancelled_at`).
//   H. Banned-items grep — sink executable code contains zero V1
//      lean cut 2 banned tokens.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_reservation_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/reservation/fixtures/opentable_reservations_fixture.dart';

const String _opA = '00000000-0000-4000-8000-0000000000a1';
const String _locA = '00000000-0000-4000-8000-0000000000b1';
const String _opB = '00000000-0000-4000-8000-0000000000a2';
const String _locB = '00000000-0000-4000-8000-0000000000b2';
const String _connA = '00000000-0000-4000-8000-0000000000d1';
const String _connB = '00000000-0000-4000-8000-0000000000d2';
const String _restaurantId = 'rid-9876';

OpenTableCanonicalReservationFact _factFromMap(
  Map<String, Object?> raw, {
  required String operatorId,
  required String locationId,
}) {
  final reservedAt = DateTime.parse(raw['reserved_at']! as String).toUtc();
  final modifiedAt = DateTime.parse(raw['modified_at']! as String).toUtc();
  return OpenTableCanonicalReservationFact(
    operatorId: operatorId,
    locationId: locationId,
    vendorEntityId: raw['id']! as String,
    vendorModifiedAt: modifiedAt,
    reservationAt: reservedAt,
    partySize: (raw['party_size']! as num).toInt(),
    status: (raw['status']! as String).toLowerCase(),
    rawPayload: <String, Object?>{
      'id': raw['id'],
      'restaurant_id': raw['restaurant_id'],
      'reserved_at': raw['reserved_at'],
      'modified_at': raw['modified_at'],
      'party_size': raw['party_size'],
      'status': raw['status'],
    },
  );
}

void main() {
  group('OpenTablePostgresSink — A. Round-trip', () {
    test(
      'writeReservationFact → tenant SELECT returns canonical-fact columns',
      () async {
        final db = _FakeDb()..seedConnection(_opA, _locA, _connA, _restaurantId);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final fact = _factFromMap(
          openTableBackfillBatchPage1.first,
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
        expect(readBack.single['vendor_entity_id'], fact.vendorEntityId);
        expect(readBack.single['party_size'], fact.partySize);
        // 'booked' from OpenTable maps to 'confirmed' in V1 vocab.
        expect(readBack.single['status'], 'confirmed');
        expect(readBack.single['reservation_at'], fact.reservationAt);
        expect(readBack.single['vendor_modified_at'], fact.vendorModifiedAt);
        expect(readBack.single['business_date'],
            fact.reservationAt.toIso8601String().substring(0, 10));
        expect(readBack.single['raw_payload'], isNotEmpty);
      },
    );
  });

  group('OpenTablePostgresSink — B. Idempotency', () {
    test(
      'same vendor entity + vendor_modified_at twice collapses to one row',
      () async {
        final db = _FakeDb()..seedConnection(_opA, _locA, _connA, _restaurantId);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final fact = _factFromMap(
          openTableBackfillBatchPage1.first,
          operatorId: _opA,
          locationId: _locA,
        );

        final firstWrote = await sink.writeReservationFact(fact);
        final secondWrote = await sink.writeReservationFact(fact);

        expect(firstWrote, isTrue,
            reason: 'first arrival inserts a fresh row.');
        expect(secondWrote, isFalse,
            reason: 'partial UNIQUE on '
                '(operator_id, vendor_id, vendor_entity_id, '
                'vendor_modified_at) must collapse the second arrival.');
        expect(db.reservationFacts, hasLength(1),
            reason: 'idempotent replay must yield exactly one row.');
      },
    );
  });

  group('OpenTablePostgresSink — C. Watermark per batch', () {
    test(
      'writeWatermark UPSERTs the single (connection_id, resource) row '
      'to the latest cursor',
      () async {
        final db = _FakeDb()..seedConnection(_opA, _locA, _connA, _restaurantId);
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
            reason: 'unique index on (connection_id, resource) means '
                'UPSERT, not INSERT-many.');
        final wm = db.watermarks.values.single;
        expect(wm.cursorToken, 'cursor-page-2');
        expect(wm.resource, openTableWatermarkResource);
        expect(wm.lastModifiedSeen, DateTime.utc(2026, 5, 4, 11));
      },
    );
  });

  group('OpenTablePostgresSink — D. Demo-mode flip(reservation)', () {
    test(
      'first writeWatermark with records >= 1 flips is_demo=false; '
      'second call is idempotent (flipped_to_live_at preserved)',
      () async {
        final db = _FakeDb()..seedConnection(_opA, _locA, _connA, _restaurantId);
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

        // First batch: write one fact then advance watermark.
        await sink.writeReservationFact(
          _factFromMap(
            openTableBackfillBatchPage1.first,
            operatorId: _opA,
            locationId: _locA,
          ),
        );
        await sink.writeWatermark(
          operatorId: _opA,
          locationId: _locA,
          row: OpenTableWatermarkRow(
            cursorToken: 'cursor-1',
            lastModifiedSeen: DateTime.utc(2026, 5, 4, 11),
          ),
        );
        final afterFirst = db.demoState['$_opA|$_locA|reservation']!;
        expect(afterFirst.isDemo, isFalse);
        expect(afterFirst.flippedToLiveAt, DateTime.utc(2026, 5, 4, 12));
        expect(afterFirst.flippedByConnectionId, _connA);

        // Advance clock + simulate a later batch with another insert.
        clock.advanceTo(DateTime.utc(2026, 5, 4, 13));
        await sink.writeReservationFact(
          _factFromMap(
            openTableBackfillBatchPage1[1],
            operatorId: _opA,
            locationId: _locA,
          ),
        );
        await sink.writeWatermark(
          operatorId: _opA,
          locationId: _locA,
          row: OpenTableWatermarkRow(
            cursorToken: 'cursor-2',
            lastModifiedSeen: DateTime.utc(2026, 5, 4, 12),
          ),
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

  group('OpenTablePostgresSink — E. RLS + tenancy', () {
    test(
      'write under operator A is invisible to operator B tenant context',
      () async {
        final db = _FakeDb()
          ..seedConnection(_opA, _locA, _connA, _restaurantId)
          ..seedConnection(_opB, _locB, _connB, _restaurantId);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        await sink.writeReservationFact(
          _factFromMap(
            openTableBackfillBatchPage1.first,
            operatorId: _opA,
            locationId: _locA,
          ),
        );

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
        expect(asA, hasLength(1),
            reason: 'tenant A sees its own row.');
        expect(asB, isEmpty,
            reason:
                'tenant B SELECT under set_config(app.operator_id, opB) '
                'must NOT see operator A\'s row — RLS + repository defense.');
      },
    );
  });

  group('OpenTablePostgresSink — F. Adapter pollIncremental smoke', () {
    test(
      'OpenTable adapter wired with the sink walks vendor pages, '
      'persists canonical facts, and advances the watermark',
      () async {
        final db = _FakeDb()
          ..seedConnection(_opA, _locA, _connA, _restaurantId)
          ..seedAccessToken(_opA, _locA, 'access-token-001');
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final transport = _FakeOpenTableTransport()
          ..pages = <OpenTableReservationsPage>[
            OpenTableReservationsPage(
              records: openTableBackfillBatchPage1,
              nextCursor: 'cursor-page-2',
              lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
            ),
            OpenTableReservationsPage(
              records: openTableBackfillBatchPage2,
              nextCursor: null,
              lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
            ),
          ];
        final adapter = OpenTableReservationAdapter(
          transport: transport,
          gateway: sink,
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        Future<bool> alwaysOk({
          required String vendorEventId,
          required Map<String, Object?> payload,
          required bool isDeliberateBackfill,
        }) async =>
            true;

        final result = await adapter.pollIncremental(
          PollIncrementalCommand(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: _opA,
            vendorId: kOpenTableVendorId,
            lastModifiedSeen: DateTime.utc(2026, 5, 4, 11),
            sanityHook: alwaysOk,
          ),
        );

        expect(
          result.recordsWritten,
          openTableBackfillBatchPage1.length +
              openTableBackfillBatchPage2.length,
        );
        expect(db.reservationFacts, hasLength(5));
        // Watermark advanced to the last page's cursor.
        expect(db.watermarks.values.single.cursorToken, 'cursor-page-2');
      },
    );
  });

  group('OpenTablePostgresSink — G. Status-enum round-trip', () {
    test(
      'booked/seated/cancelled land with V1 status + transition timestamps',
      () async {
        final db = _FakeDb()..seedConnection(_opA, _locA, _connA, _restaurantId);
        final sink = OpenTableReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        // Page1: OT-9001 booked, OT-9002 seated, OT-9003 completed
        // Page2: OT-9004 cancelled, OT-9005 no_show
        for (final raw in <Map<String, Object?>>[
          ...openTableBackfillBatchPage1,
          ...openTableBackfillBatchPage2,
        ]) {
          await sink.writeReservationFact(
            _factFromMap(raw, operatorId: _opA, locationId: _locA),
          );
        }

        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(5));
        Map<String, Object?> rowOf(String entityId) =>
            readBack.firstWhere((r) => r['vendor_entity_id'] == entityId);

        // Booked → confirmed; no transition timestamps.
        final booked = rowOf('OT-9001');
        expect(booked['status'], 'confirmed');
        expect(booked['seated_at'], isNull);
        expect(booked['cancelled_at'], isNull);
        expect(booked['vendor_modified_at'],
            DateTime.parse('2026-04-30T18:05:00Z').toUtc());

        // Seated → seated; seated_at = vendor_modified_at.
        final seated = rowOf('OT-9002');
        expect(seated['status'], 'seated');
        expect(seated['seated_at'],
            DateTime.parse('2026-05-01T18:55:00Z').toUtc());
        expect(seated['cancelled_at'], isNull);

        // Completed → unknown (V1 column vocab does not carry
        // 'completed').
        final completed = rowOf('OT-9003');
        expect(completed['status'], 'unknown');
        expect(completed['seated_at'], isNull);
        expect(completed['cancelled_at'], isNull);

        // Cancelled → cancelled; cancelled_at = vendor_modified_at.
        final cancelled = rowOf('OT-9004');
        expect(cancelled['status'], 'cancelled');
        expect(cancelled['cancelled_at'],
            DateTime.parse('2026-05-02T18:10:00Z').toUtc());
        expect(cancelled['seated_at'], isNull);

        // No-show → no_show; no transition timestamps.
        final noShow = rowOf('OT-9005');
        expect(noShow['status'], 'no_show');
        expect(noShow['seated_at'], isNull);
        expect(noShow['cancelled_at'], isNull);
      },
    );
  });

  group('OpenTablePostgresSink — H. Banned-items grep (lean cut 2)', () {
    test('sink executable code contains zero banned tokens', () {
      final source = File(
        'lib/infrastructure/persistence/postgres/'
        'opentable_reservation_postgres_sink.dart',
      ).readAsStringSync();
      final code = _stripDartComments(source).toLowerCase();
      // Tokens flagged in `memory/project_v1_lean_cut_2_2026_05_03.md`
      // and the spine contract's "Banned items" section. The grep
      // targets executable code only — comments / doc strings that
      // name a banned pattern as "we do not do this" are fine.
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
    });
  });
}

// ─── Comment stripper ───────────────────────────────────────────────

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

// ─── Tenant SELECT helpers ──────────────────────────────────────────

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

// ─── In-memory Postgres fakes ────────────────────────────────────────

class _FakeDb {
  final List<_StoredReservation> reservationFacts = <_StoredReservation>[];
  final Map<String, _StoredWatermark> watermarks = <String, _StoredWatermark>{};
  final List<_StoredLog> syncLogs = <_StoredLog>[];
  final Map<String, _StoredDemo> demoState = <String, _StoredDemo>{};
  final List<_StoredConnection> connections = <_StoredConnection>[];
  final List<_StoredCredential> credentials = <_StoredCredential>[];

  void seedConnection(
    String operatorId,
    String locationId,
    String connectionId,
    String restaurantId,
  ) {
    connections.add(
      _StoredConnection(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: kOpenTableVendorId,
        connectionId: connectionId,
        restaurantId: restaurantId,
        status: 'connected',
      ),
    );
  }

  void seedAccessToken(
    String operatorId,
    String locationId,
    String token,
  ) {
    credentials.add(
      _StoredCredential(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: kOpenTableVendorId,
        accessToken: token,
        isActive: true,
      ),
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
    required this.seatedAt,
    required this.cancelledAt,
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
  final DateTime? seatedAt;
  final DateTime? cancelledAt;
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
        'seated_at': seatedAt,
        'cancelled_at': cancelledAt,
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
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.connectionId,
    required this.restaurantId,
    required this.status,
  });

  final String operatorId;
  final String locationId;
  final String vendorId;
  final String connectionId;
  String restaurantId;
  String status;
}

class _StoredCredential {
  _StoredCredential({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.accessToken,
    required this.isActive,
  });

  final String operatorId;
  final String locationId;
  final String vendorId;
  String? accessToken;
  bool isActive;
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

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
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

    if (lower.contains('select current_setting')) {
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
        lower.contains('returning')) {
      // upsertConnection branch — RETURNING connection_id.
      return _upsertConnectionReturning(parameters);
    }

    if (lower.contains('select connection_id') &&
        lower.contains('from public.connector_connection')) {
      final operatorId = parameters['operator_id'];
      final locationId = parameters['location_id'];
      final vendorId = parameters['vendor_id'];
      final match = db.connections.where((c) =>
          c.operatorId == operatorId &&
          c.locationId == locationId &&
          c.vendorId == vendorId);
      if (match.isEmpty) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'connection_id': match.first.connectionId},
      ];
    }

    if (lower.contains('select metadata') &&
        lower.contains('from public.connector_connection')) {
      final operatorId = parameters['operator_id'];
      final locationId = parameters['location_id'];
      final vendorId = parameters['vendor_id'];
      final match = db.connections.where((c) =>
          c.operatorId == operatorId &&
          c.locationId == locationId &&
          c.vendorId == vendorId);
      if (match.isEmpty) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'metadata': <String, Object?>{
            'restaurant_id': match.first.restaurantId,
          },
        },
      ];
    }

    if (lower.contains('select access_token_ciphertext') &&
        lower.contains('from public.vendor_credentials')) {
      final operatorId = parameters['operator_id'];
      final locationId = parameters['location_id'];
      final vendorId = parameters['vendor_id'];
      final match = db.credentials.where((c) =>
          c.operatorId == operatorId &&
          (c.locationId == locationId) &&
          c.vendorId == vendorId &&
          c.isActive);
      if (match.isEmpty) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'access_token_ciphertext': match.first.accessToken},
      ];
    }

    if (lower.contains('from public.connector_sync_watermark')) {
      final operatorId = parameters['operator_id'];
      final locationId = parameters['location_id'];
      final vendorId = parameters['vendor_id'];
      final resource = parameters['resource'];
      // Simulate the join: find the watermark whose connection_id
      // matches a connector_connection row for the (operator,
      // location, vendor) triple AND whose resource matches.
      final matchingConn = db.connections.where((c) =>
          c.operatorId == operatorId &&
          c.locationId == locationId &&
          c.vendorId == vendorId);
      if (matchingConn.isEmpty) return const <PostgresRow>[];
      final connId = matchingConn.first.connectionId;
      final wm = db.watermarks.values.where(
        (w) => w.connectionId == connId && w.resource == resource,
      );
      if (wm.isEmpty) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'cursor_token': wm.first.cursorToken,
          'last_modified_seen': wm.first.lastModifiedSeen,
        },
      ];
    }

    if (lower.contains('from public.reservation_facts')) {
      // Honor SET LOCAL tenancy: only return rows visible to the
      // current (operator_id, location_id) — same scope as the RLS
      // policy.
      return db.reservationFacts
          .where((r) =>
              r.operatorId == _operatorId && r.locationId == _locationId)
          .map((r) => r.asRow())
          .toList(growable: false);
    }

    return const <PostgresRow>[];
  }

  List<PostgresRow> _upsertConnectionReturning(
    PostgresParameters parameters,
  ) {
    final operatorId = parameters['operator_id']! as String;
    final locationId = parameters['location_id']! as String;
    final vendorId = parameters['vendor_id']! as String;
    final existing = db.connections.firstWhere(
      (c) =>
          c.operatorId == operatorId &&
          c.locationId == locationId &&
          c.vendorId == vendorId,
      orElse: () => _StoredConnection(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        connectionId: '00000000-0000-4000-8000-0000000000d1',
        restaurantId: '',
        status: 'connected',
      ),
    );
    if (!db.connections.contains(existing)) {
      db.connections.add(existing);
    }
    return <PostgresRow>[
      <String, Object?>{'connection_id': existing.connectionId},
    ];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
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
          seatedAt: parameters['seated_at'] as DateTime?,
          cancelledAt: parameters['cancelled_at'] as DateTime?,
          rawPayload: parameters['raw_payload']! as String,
        ),
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

    if (lower.contains('update public.vendor_credentials')) {
      final operatorId = parameters['operator_id'];
      final locationId = parameters['location_id'];
      final vendorId = parameters['vendor_id'];
      var hits = 0;
      for (final c in db.credentials) {
        if (c.operatorId == operatorId &&
            (c.locationId == locationId) &&
            c.vendorId == vendorId) {
          c.accessToken = null;
          c.isActive = false;
          hits += 1;
        }
      }
      return hits;
    }

    if (lower.contains('update public.connector_connection')) {
      final operatorId = parameters['operator_id'];
      final locationId = parameters['location_id'];
      final vendorId = parameters['vendor_id'];
      var hits = 0;
      for (final c in db.connections) {
        if (c.operatorId == operatorId &&
            c.locationId == locationId &&
            c.vendorId == vendorId) {
          c.status = 'disconnected';
          hits += 1;
        }
      }
      return hits;
    }

    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}

// ─── Minimal fake transport (Test F only) ────────────────────────────

class _FakeOpenTableTransport implements OpenTableTransport {
  List<OpenTableReservationsPage> _pages = <OpenTableReservationsPage>[];
  int _pageCursor = 0;

  set pages(List<OpenTableReservationsPage> next) {
    _pages = next;
    _pageCursor = 0;
  }

  @override
  Future<OpenTableTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  }) async =>
      OpenTableTokenResponse(
        accessToken: 'access-token-fake',
        refreshToken: 'refresh-token-fake',
        expiresAt: DateTime.utc(2026, 5, 5),
      );

  @override
  Future<OpenTableTokenResponse> refresh({required String refreshToken}) async =>
      OpenTableTokenResponse(
        accessToken: 'access-token-fake',
        refreshToken: 'refresh-token-fake',
        expiresAt: DateTime.utc(2026, 5, 5),
      );

  @override
  Future<void> revoke({required String accessToken}) async {}

  @override
  Future<OpenTableReservationsPage> listReservations({
    required String accessToken,
    required String restaurantId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    if (_pageCursor >= _pages.length) {
      return OpenTableReservationsPage(
        records: const <Map<String, Object?>>[],
        nextCursor: null,
        lastModifiedSeen: modifiedSince,
      );
    }
    final page = _pages[_pageCursor];
    _pageCursor += 1;
    return page;
  }

  @override
  Future<Map<String, Object?>> fetchReservation({
    required String accessToken,
    required String restaurantId,
    required String reservationId,
  }) async =>
      const <String, Object?>{};

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String restaurantId,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async =>
      'opentable-sub-fake';

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String restaurantId,
    required String subscriptionId,
  }) async {}

  @override
  Future<Map<String, Object?>> sampleReservation({
    required String accessToken,
    required String restaurantId,
  }) async =>
      const <String, Object?>{};
}
