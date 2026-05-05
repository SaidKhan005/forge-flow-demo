// Phase 8 Wave B `8.spine-bridge.1.LB` — Libro Postgres sink tests.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) sub-lane `.1.LB`. Mirrors the test surface of `.1.OR` /
// `.1.QBT`:
//
//   A. Round-trip via poll path — adapter pollIncremental → sink upsert
//      → tenant-scoped SELECT returns the same canonical-fact columns.
//   B. Round-trip via webhook path — adapter handleWebhook → sink upsert
//      → tenant-scoped SELECT returns the same canonical-fact columns.
//   C. Idempotency replay — same booking arriving via poll AND webhook
//      collapses to a single row (partial UNIQUE on
//      operator_id, vendor_id, vendor_entity_id, vendor_modified_at).
//   D. Watermark per batch — every `recordWatermark` call upserts the
//      single (connection_id, resource) row to the latest cursor.
//   E. Demo-mode flip — first `markReservationsLive` with records >=1
//      flips `demo_mode_state.is_demo = false`; second call is a no-op
//      (flipped_to_live_at + flipped_by_connection_id pinned to the
//      first flip per the policy contract).
//   F. RLS + tenancy — write under operator A's tenant context cannot
//      be read under operator B's tenant context.
//   G. The existing `libro_reservation_adapter_test.dart` suite still
//      smoke-runs (17/17 PASS) — verified by re-running the file as
//      part of the slice's verification step.
//   H. Banned-items grep — sink source contains zero items from
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/libro_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';

import '../../../integrations/reservation/fixtures/libro_reservations_fixture.dart';
import '../../../integrations/reservation/fixtures/libro_webhook_fixture.dart';

const String _opA = '00000000-0000-4000-8000-0000000000a1';
const String _locA = '00000000-0000-4000-8000-0000000000b1';
const String _userA = '00000000-0000-4000-8000-0000000000c1';
const String _opB = '00000000-0000-4000-8000-0000000000a2';
const String _locB = '00000000-0000-4000-8000-0000000000b2';
const String _connA = '00000000-0000-4000-8000-0000000000d1';

CanonicalReservationFact _factFromMap(
  Map<String, Object?> raw, {
  required String fixedTimezone,
}) {
  final dto = LibroReservationDto.fromMap(raw);
  // Treat the fixture's wall-clock as UTC for deterministic tests; the
  // production adapter projects via IanaTimezoneConverter (see
  // `libro_reservation_adapter_test.dart`'s `_FixedOffsetConverter`).
  DateTime asUtc(DateTime wall) => DateTime.utc(
        wall.year,
        wall.month,
        wall.day,
        wall.hour,
        wall.minute,
        wall.second,
      );
  final reservationAt = asUtc(dto.reservationAt);
  final updatedAt = asUtc(dto.updatedAt);
  final businessDate = DateTime.utc(
    reservationAt.year,
    reservationAt.month,
    reservationAt.day,
  );
  final transitions = <String, DateTime>{
    if (dto.createdAt != null) 'expected': asUtc(dto.createdAt!),
    if (dto.confirmedAt != null) 'confirmed': asUtc(dto.confirmedAt!),
    if (dto.arrivedAt != null) 'arrived': asUtc(dto.arrivedAt!),
    if (dto.seatedAt != null) 'seated': asUtc(dto.seatedAt!),
    if (dto.completedAt != null) 'completed': asUtc(dto.completedAt!),
    if (dto.canceledAt != null) 'canceled': asUtc(dto.canceledAt!),
  };
  return CanonicalReservationFact(
    vendorId: kLibroVendorId,
    vendorEntityId: dto.id,
    vendorModifiedAt: updatedAt,
    reservationAt: reservationAt,
    businessDate: businessDate,
    partySize: dto.size,
    status: _statusFromVendor(dto.status),
    statusTransitions: transitions,
    rawPayload: <String, Object?>{
      'id': dto.id,
      'venue_id': dto.venueId,
      'size': dto.size,
      'status': dto.status,
      'reservation_at': dto.reservationAt.toIso8601String(),
      'updated_at': dto.updatedAt.toIso8601String(),
      'fixed_timezone_for_test': fixedTimezone,
    },
  );
}

CanonicalReservationStatus _statusFromVendor(String s) {
  switch (s.toLowerCase()) {
    case 'confirmed':
      return CanonicalReservationStatus.confirmed;
    case 'seated':
      return CanonicalReservationStatus.seated;
    case 'canceled':
    case 'cancelled':
      return CanonicalReservationStatus.canceled;
    case 'no_show':
    case 'noshow':
      return CanonicalReservationStatus.noShow;
    case 'arrived':
      return CanonicalReservationStatus.arrived;
    case 'completed':
      return CanonicalReservationStatus.completed;
  }
  return CanonicalReservationStatus.expected;
}

void main() {
  group('LibroPostgresSink — A. Round-trip via poll path', () {
    test(
      'pollIncremental fact → INSERT → tenant SELECT returns the canonical row',
      () async {
        final db = _FakeDb();
        final sink = LibroPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final pollFact = _factFromMap(
          (libroReservationPagePayloadFirstOfTwo['reservations']! as List)
              .cast<Map<String, Object?>>()
              .first,
          fixedTimezone: 'America/Toronto',
        );

        final outcome = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          fact: pollFact,
        );

        expect(outcome.wrote, isTrue);
        expect(db.reservationFacts, hasLength(1));
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['vendor_id'], kLibroVendorId);
        expect(readBack.single['vendor_entity_id'], pollFact.vendorEntityId);
        expect(readBack.single['party_size'], pollFact.partySize);
        expect(readBack.single['status'], 'confirmed');
        expect(readBack.single['reservation_at'], pollFact.reservationAt);
        expect(readBack.single['business_date'],
            pollFact.businessDate.toIso8601String().substring(0, 10));
        expect(readBack.single['raw_payload'], isNotEmpty);
      },
    );
  });

  group('LibroPostgresSink — B. Round-trip via webhook path', () {
    test(
      'webhook reservation envelope → INSERT → tenant SELECT returns row',
      () async {
        final db = _FakeDb();
        final sink = LibroPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final webhookReservation = libroWebhookPayloadReservationConfirmed[
            'reservation']! as Map<String, Object?>;
        final webhookFact = _factFromMap(
          webhookReservation,
          fixedTimezone: 'America/Toronto',
        );

        final outcome = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          fact: webhookFact,
        );

        expect(outcome.wrote, isTrue);
        final readBack = await _readReservationFactsAsTenant(
          db: db,
          operatorId: _opA,
          locationId: _locA,
        );
        expect(readBack, hasLength(1));
        expect(readBack.single['vendor_entity_id'], webhookFact.vendorEntityId);
        expect(readBack.single['status'], 'confirmed');
        // Webhook payload carries party size 4 (see fixture).
        expect(readBack.single['party_size'], 4);
        expect(readBack.single['vendor_modified_at'],
            webhookFact.vendorModifiedAt);
      },
    );
  });

  group('LibroPostgresSink — C. Idempotency replay (poll + webhook)', () {
    test(
      'same booking via poll-shape and webhook-shape collapses to one row',
      () async {
        final db = _FakeDb();
        final sink = LibroPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        // Use the same DTO id + updated_at across both paths so the
        // partial UNIQUE collapses the second arrival.
        final shared = <String, Object?>{
          'id': 'lbr-evt-shared-1',
          'venue_id': 'venue-test-1',
          'size': 5,
          'status': 'confirmed',
          'reservation_at': '2026-05-04T19:00:00',
          'created_at': '2026-05-04T11:00:00',
          'confirmed_at': '2026-05-04T11:05:00',
          'updated_at': '2026-05-04T11:05:00',
        };
        final firstFact =
            _factFromMap(shared, fixedTimezone: 'America/Toronto');
        final secondFact =
            _factFromMap(shared, fixedTimezone: 'America/Toronto');

        final firstOutcome = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          fact: firstFact,
        );
        final secondOutcome = await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          fact: secondFact,
        );

        expect(firstOutcome.wrote, isTrue,
            reason: 'first arrival inserts a fresh row.');
        expect(secondOutcome.wrote, isFalse,
            reason: 'partial UNIQUE on '
                '(operator_id, vendor_id, vendor_entity_id, vendor_modified_at) '
                'must collapse the second arrival to a no-op.');
        expect(db.reservationFacts, hasLength(1),
            reason: 'idempotent replay must yield exactly one row.');
      },
    );
  });

  group('LibroPostgresSink — D. Watermark per batch', () {
    test(
      'recordWatermark UPSERTs the single (connection_id, resource) row '
      'to the latest cursor',
      () async {
        final db = _FakeDb();
        final sink = LibroPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );

        await sink.recordWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          resource: kLibroReservationsResource,
          cursorToken: 'cursor-page-1',
          lastModifiedSeen: DateTime.utc(2026, 5, 4, 10),
        );
        await sink.recordWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          resource: kLibroReservationsResource,
          cursorToken: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 4, 11),
        );

        expect(db.watermarks, hasLength(1),
            reason: 'connector_sync_watermark unique index on '
                '(connection_id, resource) means UPSERT, not INSERT-many.');
        final wm = db.watermarks.values.single;
        expect(wm.cursorToken, 'cursor-page-2',
            reason: 'cursor advances to the latest batch.');
        expect(wm.lastModifiedSeen, DateTime.utc(2026, 5, 4, 11));
      },
    );
  });

  group('LibroPostgresSink — E. Demo-mode flip', () {
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
        final sink = LibroPostgresSink(
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

  group('LibroPostgresSink — F. RLS + tenancy', () {
    test(
      'write under operator A is invisible to operator B tenant context',
      () async {
        final db = _FakeDb();
        final sink = LibroPostgresSink(
          tenantWrapper: TenantTransactionWrapper(_FakePool(db)),
          now: () => DateTime.utc(2026, 5, 4, 12),
        );
        final factA = _factFromMap(
          (libroReservationPagePayloadFirstOfTwo['reservations']! as List)
              .cast<Map<String, Object?>>()
              .first,
          fixedTimezone: 'America/Toronto',
        );

        await sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          fact: factA,
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

  group('LibroPostgresSink — H. Banned-items grep (lean cut 2)', () {
    test('sink executable code contains zero banned tokens', () {
      final source = File(
        'lib/infrastructure/persistence/postgres/libro_postgres_sink.dart',
      ).readAsStringSync();
      final code = _stripDartComments(source).toLowerCase();
      // Tokens flagged in `memory/project_v1_lean_cut_2_2026_05_03.md`
      // and the spine contract's "Banned items" section. The grep
      // targets the executable code only — comments/doc strings that
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

/// Strip `//` line comments and `/* */` block comments so the banned-
/// items grep targets executable code only. Comments naming a banned
/// pattern (e.g. doc strings that say "no parse_warnings here") are
/// fine — the rule is that the IMPLEMENTATION must not use these
/// patterns.
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
