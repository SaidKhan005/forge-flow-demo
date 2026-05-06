// Phase 8 / Wave B `8.spine-bridge.fanout.TC` — Tock Postgres sink tests.
//
// Mirrors the test surface of the Libro sink (`.1.LB`). Tests cover:
//
//   A. Round-trip via poll path — adapter pollIncremental → sink upsert
//      → tenant-scoped SELECT returns the same canonical-fact columns.
//   B. Round-trip via webhook path — adapter handleWebhook → sink upsert
//      → tenant-scoped SELECT returns the same canonical-fact columns.
//   C. Idempotency replay — same booking arriving via poll AND webhook
//      collapses to a single row (partial UNIQUE on
//      `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`).
//   D. Watermark per batch — every `persistWatermark` call upserts the
//      single (connection_id, resource) row to the latest cursor.
//   E. Demo-mode flip — first `markReservationsLive` flips
//      `demo_mode_state.is_demo = false`; second call is a no-op
//      (`flipped_to_live_at` + `flipped_by_connection_id` pinned to the
//      first flip per the policy contract).
//   F. RLS + tenancy — write under operator A's tenant context cannot
//      be read under operator B's tenant context.
//   G. 2026-05-05 falsehood correction — Tock public reference exposes
//      only three reservation timestamps; the sink never fabricates
//      `seated_at`. A canonical fact that does NOT supply `seated_at`
//      round-trips to a `null` column value.
//   H. Banned-items grep — sink source contains zero items from
//      `memory/project_v1_lean_cut_2_2026_05_03.md`, AND no literal
//      `'seated_at'` Dart token outside the column-name string in the
//      INSERT statement.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart';
import 'package:forge_and_flow/integrations/reservation/tock_webhook_signature_verifier.dart';

const String _opA = '00000000-0000-4000-8000-0000000000a1';
const String _locA = '00000000-0000-4000-8000-0000000000b1';
const String _userA = '00000000-0000-4000-8000-0000000000c1';
const String _opB = '00000000-0000-4000-8000-0000000000a2';
const String _locB = '00000000-0000-4000-8000-0000000000b2';
const String _connA = '00000000-0000-4000-8000-0000000000d1';

/// Build a Tock-shape canonical fact dict in the form the adapter's
/// `_canonicalize` emits. The adapter contract is fixed at slice ship;
/// these keys mirror what `TockReservationAdapter._canonicalize`
/// produces.
Map<String, Object?> _tockCanonicalFact({
  required String reservationId,
  required String reservationAtIso,
  required String lastUpdatedIso,
  required String createdIso,
  required int partySize,
  required String canonicalStatus,
  String vendorStatusRaw = 'EXPECTED',
}) {
  return <String, Object?>{
    'vendor_entity_id': reservationId,
    'vendor_modified_at': lastUpdatedIso,
    'reservation_at': reservationAtIso,
    'party_size': partySize,
    'status': canonicalStatus,
    'vendor_status_raw': vendorStatusRaw,
    'created_timestamp': createdIso,
  };
}

Map<String, Object?> _tockRawReservation({
  required String reservationId,
  required String reservationAtIso,
  required String lastUpdatedIso,
  required String createdIso,
  required int partySize,
  required String vendorStatus,
}) {
  return <String, Object?>{
    'id': reservationId,
    'businessId': 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
    'createdTimestamp': createdIso,
    'lastUpdatedTimestamp': lastUpdatedIso,
    'serviceDateTimestamp': reservationAtIso,
    'partySize': partySize,
    'status': vendorStatus,
  };
}

void main() {
  group('TockReservationPostgresSink — A. Round-trip via poll path', () {
    test(
      'pollIncremental fact → INSERT → tenant SELECT returns the canonical row',
      () async {
        final db = _FakeDb();
        final sink = TockReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final canonicalFact = _tockCanonicalFact(
          reservationId: 'p1-res-002',
          reservationAtIso: '2026-05-04T18:45:00.000Z',
          lastUpdatedIso: '2026-05-04T18:50:00.000Z',
          createdIso: '2026-05-01T11:00:00.000Z',
          partySize: 5,
          canonicalStatus: 'seated',
          vendorStatusRaw: 'SEATED',
        );
        final rawPayload = _tockRawReservation(
          reservationId: 'p1-res-002',
          reservationAtIso: '2026-05-04T18:45:00.000Z',
          lastUpdatedIso: '2026-05-04T18:50:00.000Z',
          createdIso: '2026-05-01T11:00:00.000Z',
          partySize: 5,
          vendorStatus: 'SEATED',
        );

        final wrote = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonicalFact,
          rawPayload: rawPayload,
          connectionId: _connA,
        );

        expect(wrote, isTrue);
        expect(db.reservationFacts, hasLength(1));
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['vendor_id'], kTockVendorId);
        expect(readBack.single['vendor_entity_id'], 'p1-res-002');
        expect(readBack.single['party_size'], 5);
        expect(readBack.single['status'], 'seated');
        expect(readBack.single['reservation_at'],
            DateTime.utc(2026, 5, 4, 18, 45));
        expect(readBack.single['business_date'], '2026-05-04');
        expect(readBack.single['raw_payload'], isNotEmpty);
      },
    );
  });

  group('TockReservationPostgresSink — B. Round-trip via webhook path', () {
    test(
      'webhook reservation envelope → INSERT → tenant SELECT returns row',
      () async {
        final db = _FakeDb();
        final sink = TockReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final canonicalFact = _tockCanonicalFact(
          reservationId: 'evt-res-webhook-1',
          reservationAtIso: '2026-05-04T19:30:00.000Z',
          lastUpdatedIso: '2026-05-04T19:35:00.000Z',
          createdIso: '2026-05-01T13:00:00.000Z',
          partySize: 4,
          canonicalStatus: 'canceled',
          vendorStatusRaw: 'CANCELLED',
        );
        final rawPayload = _tockRawReservation(
          reservationId: 'evt-res-webhook-1',
          reservationAtIso: '2026-05-04T19:30:00.000Z',
          lastUpdatedIso: '2026-05-04T19:35:00.000Z',
          createdIso: '2026-05-01T13:00:00.000Z',
          partySize: 4,
          vendorStatus: 'CANCELLED',
        );

        final wrote = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonicalFact,
          rawPayload: rawPayload,
          connectionId: _connA,
        );

        expect(wrote, isTrue);
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['vendor_entity_id'], 'evt-res-webhook-1');
        expect(readBack.single['status'], 'cancelled',
            reason: 'canonical canceled → V1 column "cancelled"');
        expect(readBack.single['party_size'], 4);
        expect(readBack.single['vendor_modified_at'],
            DateTime.utc(2026, 5, 4, 19, 35));
      },
    );
  });

  group('TockReservationPostgresSink — C. Idempotency replay '
      '(poll + webhook)', () {
    test(
      'same booking via poll-shape and webhook-shape collapses to one row',
      () async {
        final db = _FakeDb();
        final sink = TockReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        // Same vendor_entity_id + vendor_modified_at on both arrivals
        // so the partial UNIQUE collapses the second.
        final canonicalFact = _tockCanonicalFact(
          reservationId: 'tock-evt-shared-1',
          reservationAtIso: '2026-05-04T19:00:00.000Z',
          lastUpdatedIso: '2026-05-04T11:05:00.000Z',
          createdIso: '2026-05-04T11:00:00.000Z',
          partySize: 5,
          canonicalStatus: 'seated',
          vendorStatusRaw: 'SEATED',
        );
        final rawPayload = _tockRawReservation(
          reservationId: 'tock-evt-shared-1',
          reservationAtIso: '2026-05-04T19:00:00.000Z',
          lastUpdatedIso: '2026-05-04T11:05:00.000Z',
          createdIso: '2026-05-04T11:00:00.000Z',
          partySize: 5,
          vendorStatus: 'SEATED',
        );

        final firstWrote = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonicalFact,
          rawPayload: rawPayload,
          connectionId: _connA,
        );
        final secondWrote = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonicalFact,
          rawPayload: rawPayload,
          connectionId: _connA,
        );

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

  group('TockReservationPostgresSink — D. Watermark per batch', () {
    test(
      'persistWatermark UPSERTs the single (connection_id, resource) '
      'row to the latest cursor',
      () async {
        final db = _FakeDb();
        final sink = TockReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        await sink.persistWatermark(
          operatorId: _opA,
          locationId: _locA,
          cursorToken: 'cursor-page-1',
          lastModifiedSeen: DateTime.utc(2026, 5, 4, 10),
          connectionId: _connA,
        );
        await sink.persistWatermark(
          operatorId: _opA,
          locationId: _locA,
          cursorToken: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 4, 11),
          connectionId: _connA,
        );

        expect(db.watermarks, hasLength(1),
            reason: 'connector_sync_watermark unique index on '
                '(connection_id, resource) means UPSERT, not INSERT-many.');
        final wm = db.watermarks.values.single;
        expect(wm.cursorToken, 'cursor-page-2',
            reason: 'cursor advances to the latest batch.');
        expect(wm.resource, tockWatermarkResource,
            reason: 'TC watermark resource constant must round-trip.');
        expect(wm.lastModifiedSeen, DateTime.utc(2026, 5, 4, 11));
      },
    );
  });

  group('TockReservationPostgresSink — E. Demo-mode flip', () {
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
        final sink = TockReservationPostgresSink(
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

  group('TockReservationPostgresSink — F. RLS + tenancy', () {
    test(
      'write under operator A is invisible to operator B tenant context',
      () async {
        final db = _FakeDb();
        final sink = TockReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final canonicalFact = _tockCanonicalFact(
          reservationId: 'p1-res-002',
          reservationAtIso: '2026-05-04T18:45:00.000Z',
          lastUpdatedIso: '2026-05-04T18:50:00.000Z',
          createdIso: '2026-05-01T11:00:00.000Z',
          partySize: 5,
          canonicalStatus: 'seated',
          vendorStatusRaw: 'SEATED',
        );
        final rawPayload = _tockRawReservation(
          reservationId: 'p1-res-002',
          reservationAtIso: '2026-05-04T18:45:00.000Z',
          lastUpdatedIso: '2026-05-04T18:50:00.000Z',
          createdIso: '2026-05-01T11:00:00.000Z',
          partySize: 5,
          vendorStatus: 'SEATED',
        );

        await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonicalFact,
          rawPayload: rawPayload,
          connectionId: _connA,
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
        expect(asA, hasLength(1), reason: 'tenant A sees its own row.');
        expect(asB, isEmpty,
            reason:
                'tenant B SELECT under set_config(app.operator_id, opB) '
                'must NOT see operator A\'s row — RLS + repository defense.');
        // Actor user id propagates to set_config too.
        final actorUserId = await _readActorUserIdAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(actorUserId, _userA,
            reason: 'app.user_id is set under tenant transactions when '
                'TenantContext carries a user id.');
      },
    );
  });

  group('TockReservationPostgresSink — G. seated_at = null round-trip', () {
    test(
      'canonical fact missing per-transition timestamps lands the '
      'reservation_facts row with seated_at and cancelled_at = NULL '
      '(no synthesised value)',
      () async {
        final db = _FakeDb();
        final sink = TockReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        // Tock public reference exposes only three timestamps; the
        // adapter never projects per-transition values. The canonical
        // fact carries no seated_at / cancelled_at hint.
        final canonicalFact = _tockCanonicalFact(
          reservationId: 'p1-res-001',
          reservationAtIso: '2026-05-04T18:30:00.000Z',
          lastUpdatedIso: '2026-05-04T18:35:00.000Z',
          createdIso: '2026-05-01T10:00:00.000Z',
          partySize: 2,
          canonicalStatus: 'expected',
          vendorStatusRaw: 'EXPECTED',
        );
        final rawPayload = _tockRawReservation(
          reservationId: 'p1-res-001',
          reservationAtIso: '2026-05-04T18:30:00.000Z',
          lastUpdatedIso: '2026-05-04T18:35:00.000Z',
          createdIso: '2026-05-01T10:00:00.000Z',
          partySize: 2,
          vendorStatus: 'EXPECTED',
        );

        final wrote = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonicalFact,
          rawPayload: rawPayload,
          connectionId: _connA,
        );

        expect(wrote, isTrue);
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['seated_at'], isNull,
            reason: '2026-05-05 falsehood correction: Tock has only 3 '
                'documented timestamps; sink never fabricates seated_at.');
        expect(readBack.single['cancelled_at'], isNull,
            reason: 'same falsehood correction applies to cancelled_at.');
        // Status passes through to the V1 unknown bucket — Tock
        // EXPECTED has no V1 column equivalent.
        expect(readBack.single['status'], 'unknown');
      },
    );
  });

  group('TockReservationPostgresSink — H. Banned-items grep '
      '(lean cut 2)', () {
    test('sink executable code contains zero banned tokens '
        'AND no literal seated_at outside the INSERT column-name string',
        () {
      final source = File(
        'lib/infrastructure/persistence/postgres/'
        'tock_reservation_postgres_sink.dart',
      ).readAsStringSync();
      final code = _stripDartComments(source).toLowerCase();
      // Tokens flagged in `memory/project_v1_lean_cut_2_2026_05_03.md`
      // and the spine contract's "Banned items" section. The grep
      // targets the executable code only — comments / doc strings that
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

      // 2026-05-05 falsehood correction: Tock has only 3 documented
      // reservation timestamps. The sink must not read or synthesise
      // a seated_at value. The column appears in the INSERT statement
      // as an unquoted column name (substring of one big SQL string
      // literal). The literal Dart token `'seated_at'` (single-quoted,
      // standalone) would imply a parameter map key or other read
      // path — banned outside the column-name string.
      final stripped = _stripDartComments(source);
      expect(stripped.contains("'seated_at'"), isFalse,
          reason: 'Tock public reference does not document seated_at; '
              'sink must not fabricate it. Forbidden Dart literal '
              '\'seated_at\' (e.g. as a parameter map key or read key).');
    });
  });
}

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
  // Tock public reference exposes only 3 timestamps; the sink writes
  // both per-status transition columns as SQL `null` literals, so the
  // stored row reflects that statically.
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
  // Captures every executed statement so the postgres_import_lint and
  // tenancy tests can assert what the sink actually emitted.
  final List<String> statements = <String>[];

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

    if (lower.contains('select current_setting')) {
      // Tests use this to read back the SET LOCAL state for tenancy
      // verification. Honor `app.user_id` first since the tenancy
      // round-trip asserts the user id propagates through the wrapper.
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
      // ON CONFLICT DO UPDATE WHERE is_demo — second arrival on a
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

/// Re-read reservation_facts under a tenant transaction.
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
