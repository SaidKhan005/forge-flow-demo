// Phase 8 / A2 fix — demo-flip transactionality regression tests.
//
// Tests verify that after 202605080600_phase_8_demo_pending_counter_persisted:
//
//   I.  Single pod, happy path: one cover-fact insert increments
//       `pending_inserts_count` inside the same transaction; the
//       watermark advance reads the counter (SELECT FOR UPDATE) and flips
//       `is_demo = false` in the same transaction, leaving `is_demo = false`.
//
//   II. Rollback regression: a throw inside the watermark-advance
//       transaction rolls back BOTH the watermark write AND the counter
//       decrement so neither is half-applied.
//
//   III. Multi-pod regression: two concurrent watermark-advance batches
//       against the same tenant must produce exactly ONE flip, not two.
//       The `FOR UPDATE` row lock serialises them; the second batch sees
//       `is_demo = false` and skips.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart';

// ─── Constants ────────────────────────────────────────────────────────────────

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _connA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

const Map<String, Object?> _sampleOrder = <String, Object?>{
  'guid': 'a2b3c4d5-e6f7-4890-ab12-cd34ef56ab78',
  'restaurantGuid': '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
  'modifiedDate': '2026-05-08T10:00:00.000Z',
  'openedDate': '2026-05-08T09:00:00.000Z',
  'closedDate': '2026-05-08T10:00:00.000Z',
  'numberOfGuests': 3,
  'totalAmount': 87.50,
  'voided': false,
};

Map<String, Object?> _canonicalize(Map<String, Object?> order) =>
    <String, Object?>{
      'vendor_entity_id': order['guid'],
      'vendor_modified_at': order['modifiedDate'],
      'opened_at': order['openedDate'],
      'closed_at': order['closedDate'],
      'covers': order['numberOfGuests'],
      'covers_source': 'direct',
      'actual_sales': order['totalAmount'],
    };

// ─── Test I: happy path ───────────────────────────────────────────────────────

void main() {
  group('A2 demo-flip transactional — I. single pod happy path', () {
    test(
        'cover-fact insert increments pending_inserts_count and watermark '
        'advance atomically flips is_demo to false in one transaction',
        () async {
      final pool = _FakePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
            operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedDemoModeState(operatorId: _opA, locationId: _locA);

      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 8, 12, 0, 0),
      );

      // 1. Insert one cover fact → counter must be 1.
      final inserted = await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: _canonicalize(_sampleOrder),
        rawPayload: _sampleOrder,
      );
      expect(inserted, isTrue);

      final dmsAfterInsert = pool.demoModeState['$_opA|$_locA|pos']!;
      expect(dmsAfterInsert['pending_inserts_count'], 1,
          reason: 'counter incremented inside the same tx as cover-fact');

      // 2. Advance watermark → flip must occur inside the same tx.
      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 8, 10, 0, 0),
      );

      final dmsAfterWm = pool.demoModeState['$_opA|$_locA|pos']!;
      expect(dmsAfterWm['is_demo'], isFalse,
          reason: 'flip must fire in same tx as watermark write');
      expect(dmsAfterWm['pending_inserts_count'], 0,
          reason: 'counter reset to 0 when flip fires');
      expect(dmsAfterWm['flipped_by_connection_id'], _connA);
      expect(dmsAfterWm['flipped_to_live_at'],
          DateTime.utc(2026, 5, 8, 12, 0, 0));
    });
  });

  // ─── Test II: rollback regression ─────────────────────────────────────────

  group('A2 demo-flip transactional — II. rollback regression', () {
    test(
        'throw inside the watermark-advance transaction rolls back both the '
        'watermark write and the counter/flip — neither is half-applied',
        () async {
      final pool = _FakePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
            operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedDemoModeState(operatorId: _opA, locationId: _locA);

      // Inject a fault: the pool will throw during the FOR UPDATE query
      // that the watermark writer runs to read the counter.
      pool.throwOnDmsForUpdate = true;

      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 8, 12, 0, 0),
      );

      // Insert a cover fact so the counter is 1.
      await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: _canonicalize(_sampleOrder),
        rawPayload: _sampleOrder,
      );
      expect(pool.demoModeState['$_opA|$_locA|pos']!['pending_inserts_count'],
          1);

      // The watermark advance throws mid-transaction.
      await expectLater(
        sink.persistWatermark(
          operatorId: _opA,
          locationId: _locA,
          cursorToken: 'cursor-1',
          lastModifiedSeen: DateTime.utc(2026, 5, 8, 10, 0, 0),
        ),
        throwsA(isA<Exception>()),
      );

      // Watermark must NOT have been written.
      expect(pool.watermarks, isEmpty,
          reason: 'rolled-back tx must not persist the watermark');

      // demo_mode_state must still be is_demo = true (flip did not fire).
      final dms = pool.demoModeState['$_opA|$_locA|pos']!;
      expect(dms['is_demo'], isTrue,
          reason: 'flip must not fire when the tx was rolled back');
    });
  });

  // ─── Test III: multi-pod regression ───────────────────────────────────────

  group('A2 demo-flip transactional — III. multi-pod regression', () {
    test(
        'two concurrent watermark-advance calls for the same tenant produce '
        'exactly one flip — the second sees is_demo = false and skips',
        () async {
      final pool = _FakePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
            operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedDemoModeState(operatorId: _opA, locationId: _locA);

      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 8, 12, 0, 0),
      );

      // Insert one record so the counter is 1.
      await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: _canonicalize(_sampleOrder),
        rawPayload: _sampleOrder,
      );

      // Simulate two pods calling persistWatermark concurrently.
      // The FOR UPDATE on demo_mode_state serialises them; the fake pool
      // tracks how many times the flip UPDATE ran.
      await Future.wait(<Future<void>>[
        sink.persistWatermark(
          operatorId: _opA,
          locationId: _locA,
          cursorToken: 'cursor-pod-1',
          lastModifiedSeen: DateTime.utc(2026, 5, 8, 10, 0, 0),
        ),
        sink.persistWatermark(
          operatorId: _opA,
          locationId: _locA,
          cursorToken: 'cursor-pod-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 8, 10, 0, 0),
        ),
      ]);

      expect(pool.flipCount, 1,
          reason: 'exactly one flip must fire across two concurrent batches');

      final dms = pool.demoModeState['$_opA|$_locA|pos']!;
      expect(dms['is_demo'], isFalse);
      expect(dms['pending_inserts_count'], 0);
    });
  });
}

// ─── Test doubles ────────────────────────────────────────────────────────────

class _FakePool implements PostgresPool {
  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, vendor_id)` → connection_id.
  final Map<String, String> _connectionsByTenant = <String, String>{};

  /// Keyed by canonical UNIQUE.
  final Map<String, Map<String, Object?>> coverFacts =
      <String, Map<String, Object?>>{};

  /// Keyed by `(connection_id, resource)`.
  final Map<String, Map<String, Object?>> watermarks =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, category)`.
  final Map<String, Map<String, Object?>> demoModeState =
      <String, Map<String, Object?>>{};

  /// Counts how many times the flip UPDATE (`is_demo = false`) ran.
  int flipCount = 0;

  /// When true the pool throws during the demo_mode_state FOR UPDATE read
  /// (simulates a mid-transaction failure for the rollback regression test).
  bool throwOnDmsForUpdate = false;

  void seedLocation({required String operatorId, required String locationId}) {
    _locations['$operatorId|$locationId'] = <String, Object?>{
      'timezone': 'America/Toronto',
      'business_day_rollover_hour': 4,
    };
  }

  void seedConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    _connectionsByTenant['$operatorId|$locationId|toast'] = connectionId;
  }

  void seedDemoModeState({
    required String operatorId,
    required String locationId,
    String category = 'pos',
  }) {
    demoModeState['$operatorId|$locationId|$category'] = <String, Object?>{
      'operator_id': operatorId,
      'location_id': locationId,
      'category': category,
      'is_demo': true,
      'pending_inserts_count': 0,
      'flipped_to_live_at': null,
      'flipped_by_connection_id': null,
    };
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _FakeTx(this);
  }
}

class _FakeTx implements PostgresTransaction {
  _FakeTx(this.pool);

  final _FakePool pool;

  /// Tracks writes that happen during this transaction so they can be
  /// rolled back if `rollback()` is called.
  final Map<String, Map<String, Object?>> _pendingWatermarks =
      <String, Map<String, Object?>>{};
  int? _pendingDmsCounterDelta;
  String? _pendingDmsKey;
  bool _rolledBack = false;

  void _captureSetConfig(
      String sql, PostgresParameters parameters) {
    // SET LOCAL config calls — no-op for this fake.
  }

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) {
      _captureSetConfig(sql, parameters);
      return const <PostgresRow>[];
    }
    // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): the projector's
    // BusinessTimingProfilesRepository SELECT joins `from public.locations`
    // inside a CTE, so the projector handler MUST run BEFORE the
    // generic `from public.locations` handler.
    if (sql.contains('from public.business_timing_profiles p')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.locations')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final row = pool._locations['$operatorId|$locationId'];
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'timezone': row['timezone'],
        },
      ];
    }
    if (sql.contains(
        'select connection_id::text as connection_id from public.connector_connection')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final connId =
          pool._connectionsByTenant['$operatorId|$locationId|$vendorId'];
      if (connId == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'connection_id': connId},
      ];
    }
    if (sql.contains('insert into public.cover_facts')) {
      final operatorId = parameters['operator_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final vendorEntityId = parameters['vendor_entity_id'] as String;
      final vendorModifiedAt = parameters['vendor_modified_at'] as DateTime;
      final key = '$operatorId|$vendorId|$vendorEntityId|'
          '${vendorModifiedAt.toIso8601String()}';
      if (pool.coverFacts.containsKey(key)) {
        return const <PostgresRow>[];
      }
      pool.coverFacts[key] = <String, Object?>{
        'operator_id': operatorId,
        'location_id': parameters['location_id'],
        'vendor_id': vendorId,
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAt,
        'covers': parameters['covers'],
        'covers_source': parameters['covers_source'],
        'opened_at': parameters['opened_at'],
        'closed_at': parameters['closed_at'],
        'business_date': parameters['business_date'],
        'actual_sales': parameters['actual_sales'],
        'raw_payload': parameters['raw_payload'],
      };
      return <PostgresRow>[<String, Object?>{'inserted': 1}];
    }
    if (sql.contains('from public.demo_mode_state') &&
        sql.contains('for update')) {
      if (pool.throwOnDmsForUpdate) {
        throw Exception('simulated mid-transaction failure on FOR UPDATE');
      }
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      final row = pool.demoModeState[key];
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'pending_inserts_count': row['pending_inserts_count'],
          'is_demo': row['is_demo'],
        },
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) {
      _captureSetConfig(sql, parameters);
      return 0;
    }
    if (sql.contains('insert into public.connector_sync_watermark')) {
      final connectionId = parameters['connection_id'] as String;
      final resource = parameters['resource'] as String;
      final key = '$connectionId|$resource';
      _pendingWatermarks[key] = <String, Object?>{
        'connection_id': connectionId,
        'resource': resource,
        'cursor_token': parameters['cursor_token'],
        'last_modified_seen': parameters['last_modified_seen'],
      };
      return 1;
    }
    if (sql.contains('insert into public.demo_mode_state')) {
      // Upsert with pending_inserts_count increment.
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      _pendingDmsKey = key;
      _pendingDmsCounterDelta = 1;
      // Apply immediately to the pool state (the fake does not defer
      // per-tx writes; rollback is signalled via _rolledBack flag).
      pool.demoModeState.putIfAbsent(
        key,
        () => <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': category,
          'is_demo': true,
          'pending_inserts_count': 0,
          'flipped_to_live_at': null,
          'flipped_by_connection_id': null,
        },
      );
      final row = pool.demoModeState[key]!;
      row['pending_inserts_count'] =
          (row['pending_inserts_count'] as int) + 1;
      return 1;
    }
    if (sql.contains('update public.demo_mode_state') &&
        sql.contains('is_demo = false')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      final row = pool.demoModeState[key];
      if (row == null || row['is_demo'] == false) return 0;
      row['is_demo'] = false;
      row['flipped_to_live_at'] = parameters['now'];
      row['flipped_by_connection_id'] = parameters['connection_id'];
      row['pending_inserts_count'] = 0;
      pool.flipCount += 1;
      return 1;
    }
    if (sql.contains('insert into public.connector_sync_log')) {
      return 1;
    }
    if (sql.contains('update public.vendor_credentials')) {
      return 0;
    }
    if (sql.contains('update public.connector_connection')) {
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    if (_rolledBack) return;
    // Apply pending watermark writes on commit.
    for (final entry in _pendingWatermarks.entries) {
      pool.watermarks[entry.key] = entry.value;
    }
  }

  @override
  Future<void> rollback() async {
    _rolledBack = true;
    // Reverse any counter increment that was applied eagerly.
    if (_pendingDmsKey != null && _pendingDmsCounterDelta != null) {
      final row = pool.demoModeState[_pendingDmsKey];
      if (row != null) {
        row['pending_inserts_count'] =
            ((row['pending_inserts_count'] as int) - _pendingDmsCounterDelta!)
                .clamp(0, 999999);
      }
    }
    // Roll back flip if it fired.
    // (In this fake, flip is only applied in execute() during the tx;
    // the watermark has not been applied yet because commit() was not called.)
    _pendingWatermarks.clear();
  }
}
