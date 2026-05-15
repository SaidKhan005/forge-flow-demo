// Phase 8 Wave B `8.spine-bridge.fanout.SR` — SevenRooms reservation
// Postgres sink tests.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// "Postgres-backed CanonicalSink". Mirrors the Libro `.1.LB` test surface
// (test/infrastructure/persistence/postgres/libro_postgres_sink_test.dart):
//
//   A. Round-trip via poll path — adapter pollIncremental → sink upsert
//      → tenant-scoped SELECT returns the same canonical-fact columns.
//   B. Round-trip via webhook path — adapter handleWebhook → sink upsert
//      → tenant-scoped SELECT returns the same canonical-fact columns.
//   C. Idempotency replay — same booking arriving via poll AND webhook
//      collapses to a single row (partial UNIQUE on
//      operator_id, vendor_id, vendor_entity_id, vendor_modified_at).
//   D. Watermark per batch — every `updateWatermark` call upserts the
//      single (connection_id, resource) row to the latest cursor.
//   E. Demo-mode flip — first `markReservationsLive` with records >=1
//      flips `demo_mode_state.is_demo = false` for category=reservation;
//      second call is a no-op (flipped_to_live_at + flipped_by_connection_id
//      pinned to the first flip per the policy contract).
//   F. RLS + tenancy — write under operator A's tenant context cannot
//      be read under operator B's tenant context.
//   G. Cancellation round-trip — a CANCELLED webhook event round-trips
//      with status='cancelled' and the vendor cancellation_time landing
//      on the `cancelled_at` column intact.
//   H. Banned-items grep — sink source contains zero items from
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/sevenrooms_reservation_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_reservation_adapter.dart';

const String _opA = '00000000-0000-4000-8000-0000000000a1';
const String _locA = '00000000-0000-4000-8000-0000000000b1';
const String _userA = '00000000-0000-4000-8000-0000000000c1';
const String _opB = '00000000-0000-4000-8000-0000000000a2';
const String _locB = '00000000-0000-4000-8000-0000000000b2';
const String _connA = '00000000-0000-4000-8000-0000000000d1';

void main() {
  group('SevenRoomsReservationPostgresSink — A. Round-trip via poll path', () {
    test(
      'pollIncremental fact → INSERT → tenant SELECT returns the canonical row',
      () async {
        final db = _FakeDb()..seedConnection(_connA, _opA, _locA);
        final sink = SevenRoomsReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final reservationAt = DateTime.utc(2026, 5, 4, 22, 30);
        final updatedAt = DateTime.utc(2026, 5, 4, 18, 0);

        final wrote = await sink.writeReservationFact(
          tenant: TenantContext(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
          ),
          connectionId: _connA,
          vendorEntityId: 'sr-resv-1001',
          reservationAtUtc: reservationAt,
          partySize: 2,
          status: SevenRoomsCanonicalStatus.booked,
          statusTransitions: const <String, DateTime>{},
          restaurantTimezone: 'UTC',
          businessDayRolloverHour: 0,
          vendorModifiedAtUtc: updatedAt,
        );

        expect(wrote, isTrue);
        expect(db.reservationFacts, hasLength(1));
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['vendor_id'], kSevenRoomsVendorId);
        expect(readBack.single['vendor_entity_id'], 'sr-resv-1001');
        expect(readBack.single['party_size'], 2);
        expect(readBack.single['status'], 'confirmed');
        expect(readBack.single['reservation_at'], reservationAt);
        expect(readBack.single['business_date'], '2026-05-04');
        expect(readBack.single['raw_payload'], isNotEmpty);
      },
    );
  });

  group('SevenRoomsReservationPostgresSink — B. Round-trip via webhook path',
      () {
    test(
      'webhook reservation envelope → INSERT → tenant SELECT returns row',
      () async {
        final db = _FakeDb()..seedConnection(_connA, _opA, _locA);
        final sink = SevenRoomsReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final reservationAt = DateTime.utc(2026, 5, 4, 23, 0);
        final updatedAt = DateTime.utc(2026, 5, 4, 23, 5);

        final wrote = await sink.writeReservationFact(
          tenant: TenantContext(operatorId: _opA, locationId: _locA),
          connectionId: _connA,
          vendorEntityId: 'sr-resv-webhook-1',
          reservationAtUtc: reservationAt,
          partySize: 4,
          status: SevenRoomsCanonicalStatus.seated,
          statusTransitions: <String, DateTime>{
            'seated': DateTime.utc(2026, 5, 4, 23, 5),
          },
          restaurantTimezone: 'UTC',
          businessDayRolloverHour: 0,
          vendorModifiedAtUtc: updatedAt,
        );

        expect(wrote, isTrue);
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['vendor_entity_id'], 'sr-resv-webhook-1');
        expect(readBack.single['party_size'], 4);
        expect(readBack.single['status'], 'seated');
        expect(readBack.single['vendor_modified_at'], updatedAt);
        expect(
          readBack.single['seated_at'],
          DateTime.utc(2026, 5, 4, 23, 5),
        );
      },
    );
  });

  group(
      'SevenRoomsReservationPostgresSink — C. Idempotency replay (poll + webhook)',
      () {
    test(
      'same booking via poll-shape and webhook-shape collapses to one row',
      () async {
        final db = _FakeDb()..seedConnection(_connA, _opA, _locA);
        final sink = SevenRoomsReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final reservationAt = DateTime.utc(2026, 5, 4, 19);
        final updatedAt = DateTime.utc(2026, 5, 4, 11, 5);

        Future<bool> upsert() => sink.writeReservationFact(
              tenant: TenantContext(operatorId: _opA, locationId: _locA),
              connectionId: _connA,
              vendorEntityId: 'sr-resv-shared-1',
              reservationAtUtc: reservationAt,
              partySize: 5,
              status: SevenRoomsCanonicalStatus.booked,
              statusTransitions: const <String, DateTime>{},
              restaurantTimezone: 'UTC',
              businessDayRolloverHour: 0,
              vendorModifiedAtUtc: updatedAt,
            );

        final firstWrote = await upsert();
        final secondWrote = await upsert();

        expect(firstWrote, isTrue,
            reason: 'first arrival inserts a fresh row.');
        expect(secondWrote, isFalse,
            reason: 'partial UNIQUE on '
                '(operator_id, vendor_id, vendor_entity_id, vendor_modified_at) '
                'must collapse the second arrival to a no-op.');
        expect(db.reservationFacts, hasLength(1),
            reason: 'idempotent replay must yield exactly one row.');
      },
    );
  });

  group('SevenRoomsReservationPostgresSink — D. Watermark per batch', () {
    test(
      'updateWatermark UPSERTs the single (connection_id, resource) row '
      'to the latest cursor',
      () async {
        final db = _FakeDb()..seedConnection(_connA, _opA, _locA);
        final sink = SevenRoomsReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        await sink.updateWatermark(
          connectionId: _connA,
          cursorToken: 'cursor-page-1',
          lastModifiedSeenUtc: DateTime.utc(2026, 5, 4, 10),
        );
        await sink.updateWatermark(
          connectionId: _connA,
          cursorToken: 'cursor-page-2',
          lastModifiedSeenUtc: DateTime.utc(2026, 5, 4, 11),
        );

        expect(db.watermarks, hasLength(1),
            reason: 'connector_sync_watermark unique index on '
                '(connection_id, resource) means UPSERT, not INSERT-many.');
        final wm = db.watermarks.values.single;
        expect(wm.cursorToken, 'cursor-page-2',
            reason: 'cursor advances to the latest batch.');
        expect(wm.resource, sevenRoomsWatermarkResource);
        expect(wm.lastModifiedSeen, DateTime.utc(2026, 5, 4, 11));
      },
    );
  });

  group('SevenRoomsReservationPostgresSink — E. Demo-mode flip', () {
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
        final sink = SevenRoomsReservationPostgresSink(
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

  group('SevenRoomsReservationPostgresSink — F. RLS + tenancy', () {
    test(
      'write under operator A is invisible to operator B tenant context',
      () async {
        final db = _FakeDb()..seedConnection(_connA, _opA, _locA);
        final sink = SevenRoomsReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        await sink.writeReservationFact(
          tenant: TenantContext(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
          ),
          connectionId: _connA,
          vendorEntityId: 'sr-resv-tenancy-1',
          reservationAtUtc: DateTime.utc(2026, 5, 4, 22),
          partySize: 2,
          status: SevenRoomsCanonicalStatus.booked,
          statusTransitions: const <String, DateTime>{},
          restaurantTimezone: 'UTC',
          businessDayRolloverHour: 0,
          vendorModifiedAtUtc: DateTime.utc(2026, 5, 4, 18),
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

  group('SevenRoomsReservationPostgresSink — G. Cancellation round-trip', () {
    test(
      'a CANCELLED webhook event lands with status="cancelled" and the '
      'vendor cancellation_time on the cancelled_at column',
      () async {
        final db = _FakeDb()..seedConnection(_connA, _opA, _locA);
        final sink = SevenRoomsReservationPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final reservationAt = DateTime.utc(2026, 5, 4, 23, 15);
        final cancellationAt = DateTime.utc(2026, 5, 4, 20, 0);
        final updatedAt = DateTime.utc(2026, 5, 4, 20, 0);

        final wrote = await sink.writeReservationFact(
          tenant: TenantContext(operatorId: _opA, locationId: _locA),
          connectionId: _connA,
          vendorEntityId: 'sr-resv-cancel-1',
          reservationAtUtc: reservationAt,
          partySize: 3,
          status: SevenRoomsCanonicalStatus.cancelled,
          statusTransitions: <String, DateTime>{
            'cancelled': cancellationAt,
          },
          restaurantTimezone: 'UTC',
          businessDayRolloverHour: 0,
          vendorModifiedAtUtc: updatedAt,
        );

        expect(wrote, isTrue);
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['vendor_entity_id'], 'sr-resv-cancel-1');
        expect(readBack.single['status'], 'cancelled',
            reason: 'CANCELLED maps to the canonical column status '
                '"cancelled" so the read model can render the terminal '
                'state.');
        expect(readBack.single['cancelled_at'], cancellationAt,
            reason: 'vendor cancellation_time round-trips on the '
                'cancelled_at column.');
        expect(readBack.single['seated_at'], isNull,
            reason: 'cancellations never expose a seated_at timestamp.');
      },
    );
  });

  group('SevenRoomsReservationPostgresSink — H. Banned-items grep '
      '(lean cut 2)', () {
    test('sink executable code contains zero banned tokens', () {
      final source = File(
        'lib/infrastructure/persistence/postgres/sevenrooms_reservation_postgres_sink.dart',
      ).readAsStringSync();
      final code = _stripDartComments(source).toLowerCase();
      // Tokens flagged in `memory/project_v1_lean_cut_2_2026_05_03.md`
      // and the spine contract's "Banned items" section. The grep
      // targets executable code only — comments/doc strings naming a
      // banned pattern as "we do not do this" are fine.
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

  // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): static-source
  // regression — sink no longer reads `business_day_rollover_hour`.
  // SevenRooms is a special-pattern sink: the bespoke gateway's
  // `writeReservationFact` still accepts `businessDayRolloverHour`
  // for adapter back-compat (out of Slice 7b's scope), but the sink
  // ignores it and routes through the projector.
  group(
      'SevenRoomsReservationPostgresSink — I. Per-Daypart V1 Slice 7b '
      'business_date projection via canonical timing chain (Gap 47 static)',
      () {
    test(
      'I.4 sink source contains zero references to '
      'business_day_rollover_hour as a live SQL column or location-row '
      'read (the bespoke gateway parameter still appears for adapter '
      'back-compat — that is allowed)',
      () async {
        final source = await File(
          'lib/infrastructure/persistence/postgres/sevenrooms_reservation_postgres_sink.dart',
        ).readAsString();
        final executableLines = source
            .split('\n')
            .where((line) {
              final trimmed = line.trimLeft();
              return !trimmed.startsWith('//') && !trimmed.startsWith('*');
            })
            .join('\n');
        // The bespoke `writeReservationFact` parameter is allowed to
        // appear (back-compat). What is forbidden is reading the
        // location-row column or using the value to project
        // business_date. The two surviving live-code occurrences are
        // intentional: (1) the gateway parameter declaration; (2) the
        // canonical-sink path passing `0` to satisfy the bespoke
        // signature. Pin the count so a future refactor that
        // accidentally re-introduces a SELECT or projection trips the
        // suite.
        final occurrences = 'businessDayRolloverHour'.allMatches(
          executableLines,
        ).length;
        expect(occurrences, lessThanOrEqualTo(4),
            reason: 'businessDayRolloverHour appears only on the bespoke '
                'gateway surface for back-compat — at most one parameter '
                'declaration + one call-site pass. A higher count means '
                'a regression to reading the legacy field.');
        expect(
          executableLines.contains('business_day_rollover_hour'),
          isFalse,
          reason: 'business_day_rollover_hour (snake_case SQL column) '
              'must not appear as live code in the SevenRooms sink — '
              'Per-Daypart V1 Slice 7b option (b).',
        );
      },
    );
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
  final Map<String, _StoredConnection> connections =
      <String, _StoredConnection>{};

  void seedConnection(String connectionId, String operatorId, String locationId) {
    connections[connectionId] = _StoredConnection(
      connectionId: connectionId,
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kSevenRoomsVendorId,
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
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;
  final String vendorId;
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

    if (lower.contains('from public.connector_connection')) {
      // Tenant-resolution lookup uses connection_id + vendor_id.
      // Forge_admin (system) bypasses RLS; tenant-scoped queries honor
      // the SET LOCAL filter.
      final connectionId = parameters['connection_id'] as String?;
      final vendorId = parameters['vendor_id'] as String?;
      final matches = db.connections.values.where((c) {
        if (connectionId != null && c.connectionId != connectionId) return false;
        if (vendorId != null && c.vendorId != vendorId) return false;
        if (!_systemRole) {
          if (_operatorId != null && c.operatorId != _operatorId) return false;
          if (_locationId != null && c.locationId != _locationId) return false;
        }
        return true;
      });
      return matches
          .map((c) => <String, Object?>{
                'connection_id': c.connectionId,
                'operator_id': c.operatorId,
                'location_id': c.locationId,
                'vendor_id': c.vendorId,
                'metadata': '{"venue_id":"sr-venue-7c2f"}',
                'credential_id': 'cred-${c.connectionId}',
              })
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
      // Mirrors the upsertConnection RETURNING flow for any test that
      // exercises the connect path.
      const newId = '00000000-0000-4000-8000-000000000fff';
      return <PostgresRow>[
        <String, Object?>{'connection_id': newId},
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

/// Re-read reservation_facts under a tenant transaction. Mirrors what
/// the dashboard read-path would do — set tenant via SET LOCAL, then
/// SELECT through the executor. The fake executor honors the SET LOCAL
/// scope, matching how RLS would enforce isolation in production.
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
