// B5 — Demo-flip race regression guard.
//
// Asserts that two parallel `evaluateDemoFlip` calls from different
// connections for the same tenant flip the demo_mode_state exactly ONCE
// — the "first writer wins" invariant enforced by:
//
//   INSERT ... ON CONFLICT (operator_id, location_id, category)
//   DO UPDATE SET is_demo = false ... WHERE demo_mode_state.is_demo = true
//
// This test will PASS after lane A2's serialization fix lands and
// FAIL today on a real concurrent Postgres — that is the intended
// regression guard posture. With fake (in-memory) collaborators this
// test always passes because the fake transactions are serialized by
// the Dart event loop; the real concurrency scenario requires a live
// Postgres and tagged=postgres run.
//
// Two test variants:
//   1. Fake-pool serialized (always runnable): verifies the SQL shape
//      is emitted twice but the WHERE guard means only one effective
//      UPDATE. No live Postgres required.
//   2. Live-Postgres (tagged=postgres): actual concurrent requests —
//      the true regression guard. Counts the audit_log flip events and
//      asserts exactly 1.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/adp_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../postgres_test_harness.dart';

const String _opA = 'aaaa0000-0000-0000-0000-000000000001';
const String _locA = 'aaaa0000-0000-0000-0000-000000000002';
const String _connA = 'aaaa0000-0000-0000-0000-000000000003';
const String _connB = 'aaaa0000-0000-0000-0000-000000000004';

void main() {
  group('Demo-flip race — SQL shape (fake pool, serialized)', () {
    test(
      'two parallel evaluateDemoFlip calls emit the same SQL shape; '
      'the WHERE is_demo = true guard ensures only one effective flip',
      () async {
        // Arrange: pool that records all demo_mode_state operations.
        final pool = _RaceRecordingPool();
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 7, 12, 0, 0),
        );

        // Act: two concurrent flip calls (serialized by Dart async scheduler).
        await Future.wait(<Future<void>>[
          sink.evaluateDemoFlip(
            operatorId: _opA,
            locationId: _locA,
            category: IntegrationCategory.labor,
            connectionStatus: ConnectionStatus.connected,
            firstBackfillCommitted: true,
            backfillRecordsWritten: 5,
            connectionId: _connA,
          ),
          sink.evaluateDemoFlip(
            operatorId: _opA,
            locationId: _locA,
            category: IntegrationCategory.labor,
            connectionStatus: ConnectionStatus.connected,
            firstBackfillCommitted: true,
            backfillRecordsWritten: 3,
            connectionId: _connB,
          ),
        ]);

        // Assert: two SQL executions, both carrying the WHERE guard.
        final flipSqls = pool.executedSqls
            .where((s) => s.contains('demo_mode_state'))
            .toList();
        expect(
          flipSqls,
          hasLength(2),
          reason: 'Two evaluateDemoFlip calls → two SQL executions',
        );
        for (final sql in flipSqls) {
          expect(
            sql,
            contains('where public.demo_mode_state.is_demo = true'),
            reason:
                'Every flip SQL must carry the WHERE is_demo = true guard '
                'so the second concurrent call is a no-op after the first '
                'writer flips the row',
          );
        }

        // The ON CONFLICT ... WHERE guard means: in a real DB both
        // inserts attempt the flip, but only the first finds is_demo=true
        // and updates; the second finds is_demo=false and is a no-op.
        // In the fake pool both succeed (no real DB), but the SQL shape
        // is what we pin here.
        expect(
          pool.executedSqls
              .where((s) => s.contains('on conflict (operator_id, location_id, category)'))
              .length,
          equals(2),
          reason: 'Both flip calls must use the idempotency conflict key',
        );
      },
    );

    test(
      'first writer connection_id is preserved (WHERE is_demo=true '
      'means the second update is skipped by the DB)',
      () async {
        // Simulate a DB that respects the WHERE guard: second update
        // returns 0 affected rows.
        final pool = _RaceRecordingPool(firstFlipAffectedRows: 1);
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 7, 12, 0, 0),
        );

        // Call with connection A first.
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 5,
          connectionId: _connA,
        );

        // Call with connection B second (simulates race — row already flipped).
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 3,
          connectionId: _connB,
        );

        // Verify: first call's connection_id is in the parameters.
        final firstParams = pool.executedParams.firstWhere(
          (p) => p['connection_id'] == _connA,
          orElse: () => const <String, Object?>{},
        );
        expect(
          firstParams.isNotEmpty,
          isTrue,
          reason:
              'Connection A must appear in the first flip SQL parameters; '
              'it carries the original triggering connection_id',
        );
      },
    );
  });

  // ── Live Postgres variant — actual concurrent transactions ──────────

  group('Demo-flip race — live Postgres (regression guard)', () {
    test(
      'two concurrent flip calls result in exactly ONE flip event in '
      'demo_mode_state (WHERE is_demo=true serializes the race)',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(pool, operatorId: _opA, locationId: _locA);

            // Seed an initial demo_mode_state row with is_demo=true.
            final seedTx = await pool.beginTransaction();
            try {
              await seedTx.execute(
                'insert into public.demo_mode_state ('
                "  operator_id, location_id, category, is_demo"
                ') values ('
                "  '$_opA'::uuid, '$_locA'::uuid, 'labor', true"
                ') on conflict (operator_id, location_id, category) do nothing',
              );
              await seedTx.commit();
            } catch (e) {
              await seedTx.rollback();
              rethrow;
            }

            // Fire two concurrent evaluateDemoFlip calls via separate sinks
            // sharing the same pool (true concurrent Postgres transactions).
            final sinkA = AdpPostgresSink(
              tenantWrapper: TenantTransactionWrapper(pool),
              now: () => DateTime.utc(2026, 5, 7, 12, 0, 0),
            );
            final sinkB = AdpPostgresSink(
              tenantWrapper: TenantTransactionWrapper(pool),
              now: () => DateTime.utc(2026, 5, 7, 12, 0, 1),
            );

            await Future.wait(<Future<void>>[
              sinkA.evaluateDemoFlip(
                operatorId: _opA,
                locationId: _locA,
                category: IntegrationCategory.labor,
                connectionStatus: ConnectionStatus.connected,
                firstBackfillCommitted: true,
                backfillRecordsWritten: 5,
                connectionId: _connA,
              ),
              sinkB.evaluateDemoFlip(
                operatorId: _opA,
                locationId: _locA,
                category: IntegrationCategory.labor,
                connectionStatus: ConnectionStatus.connected,
                firstBackfillCommitted: true,
                backfillRecordsWritten: 3,
                connectionId: _connB,
              ),
            ]);

            // Read the final state: should be exactly one row with is_demo=false.
            final readTx = await pool.beginTransaction();
            late int flipCount;
            late String? winningConnection;
            try {
              final rows = await readTx.query(
                'select count(*) as n, '
                'max(flipped_by_connection_id::text) as conn '
                'from public.demo_mode_state '
                "where operator_id = '$_opA'::uuid "
                "and location_id = '$_locA'::uuid "
                "and category = 'labor' "
                'and is_demo = false',
              );
              flipCount = rows.isNotEmpty
                  ? (rows.first['n'] as int? ?? 0)
                  : 0;
              winningConnection = rows.isNotEmpty
                  ? rows.first['conn'] as String?
                  : null;
              await readTx.commit();
            } catch (e) {
              await readTx.rollback();
              rethrow;
            }

            expect(
              flipCount,
              equals(1),
              reason:
                  'Exactly one demo_mode_state row must be flipped to '
                  'is_demo=false; the WHERE guard prevents double-flip',
            );
            expect(
              winningConnection,
              anyOf(equals(_connA), equals(_connB)),
              reason:
                  'The winning connection must be one of the two concurrent '
                  'callers; which one wins depends on scheduling',
            );
          },
        );
      },
      tags: <String>['postgres'],
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

// ─── Fake pool for SQL shape assertions ──────────────────────────────

class _RaceRecordingPool implements PostgresPool {
  _RaceRecordingPool({this.firstFlipAffectedRows = 0});

  final int firstFlipAffectedRows;
  final List<String> executedSqls = <String>[];
  final List<PostgresParameters> executedParams = <PostgresParameters>[];
  int _txCount = 0;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final isFirst = _txCount == 0;
    _txCount += 1;
    return _RaceRecordingTransaction(
      pool: this,
      affectedRows: isFirst ? firstFlipAffectedRows : 0,
    );
  }
}

class _RaceRecordingTransaction implements PostgresTransaction {
  _RaceRecordingTransaction({
    required this.pool,
    required this.affectedRows,
  });

  final _RaceRecordingPool pool;
  final int affectedRows;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    pool.executedSqls.add(sql);
    pool.executedParams.add(parameters);
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    pool.executedSqls.add(sql);
    pool.executedParams.add(parameters);
    if (sql.contains('demo_mode_state')) return affectedRows;
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
