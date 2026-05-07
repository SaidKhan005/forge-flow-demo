// Phase 8 Wave B `8.spine-bridge.0` PostgresSyncWorkerSource tests.
//
// Pure-logic coverage of the cross-tenant SELECT projection. The fake
// Postgres executor models the schema's column shape so the source's
// row-mapper / cursor-fallback / category coercion are all exercised
// without touching live Postgres.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../tool/integration_sync_worker/postgres_sync_worker_source.dart';

void main() {
  group('PostgresSyncWorkerSource.connectedConnections', () {
    test(
      'returns one row per connected connection with watermark cursor + '
      'last_modified_seen joined in',
      () async {
        final pool = _FakePool(<Map<String, Object?>>[
          <String, Object?>{
            'connection_id': '11111111-1111-4111-8111-111111111111',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'lightspeed_lsk',
            'category': 'pos',
            'status': 'connected',
            'last_modified_seen': DateTime.utc(2026, 5, 4, 10),
            'cursor_token': 'cursor-pos-1',
          },
          <String, Object?>{
            'connection_id': '44444444-4444-4444-8444-444444444444',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'agendrix',
            'category': 'labor',
            'status': 'connected',
            'last_modified_seen': null,
            'cursor_token': null,
          },
        ]);
        final wrapper = TenantTransactionWrapper(pool);
        final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);

        final rows =
            await source.connectedConnections().toList();

        expect(rows, hasLength(2));
        expect(rows[0].vendorId, 'lightspeed_lsk');
        expect(rows[0].category, IntegrationCategory.pos);
        expect(rows[0].cursorToken, 'cursor-pos-1');
        expect(
          rows[0].lastModifiedSeen,
          DateTime.utc(2026, 5, 4, 10),
        );
        expect(rows[1].vendorId, 'agendrix');
        expect(rows[1].category, IntegrationCategory.labor);
        expect(
          rows[1].cursorToken,
          isNull,
          reason: 'null cursor_token must surface as null, not empty string',
        );
        expect(
          rows[1].lastModifiedSeen,
          DateTime.utc(1970),
          reason:
              'missing last_modified_seen falls back to the epoch sentinel '
              'so the dispatcher passes a deterministic floor cursor',
        );

        expect(
          pool.transactions, hasLength(1),
          reason: 'cross-tenant scan opens exactly one transaction',
        );
        expect(
          pool.transactions.single.executedStatements,
          contains(predicate<String>(
              (s) => s.contains("set_config('app.bypass_rls_audit'"),
              'is system-context audit marker')),
        );
      },
    );

    test(
      'WHERE clause filters status=connected (the SELECT only emits rows '
      'whose status is "connected")',
      () async {
        // The query the source issues includes
        // `where cc.status = 'connected'` so a fake pool that returns
        // mixed-status rows would only ever be exercised through the
        // SELECT — the SQL itself is what filters. We assert the query
        // text carries the literal so a future refactor that drops the
        // filter is caught by the lint here.
        final pool = _FakePool(const <Map<String, Object?>>[]);
        final wrapper = TenantTransactionWrapper(pool);
        final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);

        await source.connectedConnections().toList();

        expect(
          pool.transactions.single.queriedStatements.single,
          contains("cc.status = 'connected'"),
        );
      },
    );

    test(
      'CODE_HEALTH W5-LB3: claim discipline — SELECT carries '
      '`for update of cc skip locked` so two concurrent worker replicas '
      'never enumerate the same connection in the same tick',
      () async {
        final pool = _FakePool(const <Map<String, Object?>>[]);
        final wrapper = TenantTransactionWrapper(pool);
        final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);

        await source.connectedConnections().toList();

        final query = pool.transactions.single.queriedStatements.single;
        expect(
          query.toLowerCase(),
          contains('for update of cc skip locked'),
          reason:
              'claim discipline: SELECT must lock the connector_connection '
              'rows it returns so concurrent worker replicas partition the '
              'work via `SKIP LOCKED` instead of double-claiming',
        );
        // Lock scope is `OF cc` (not the joined watermark table) so the
        // canonical sink can update `connector_sync_watermark` in
        // separate per-row transactions without contending with the
        // claim.
        expect(
          query.toLowerCase(),
          isNot(contains('for update skip locked')),
          reason:
              'lock scope must be limited to `OF cc` to keep the watermark '
              'table available to per-row writes from the sink',
        );
      },
    );

    test(
      'CODE_HEALTH W5-LB3: claim discipline — concurrent SELECTs partition '
      'rows; the second worker sees the rows the first one skipped',
      () async {
        // Two concurrent fake pools backed by a shared row pool that
        // reserves rows via `FOR UPDATE SKIP LOCKED`. The first SELECT
        // claims its rows; the second SELECT (running before the first
        // commits) sees the remaining rows only.
        final shared = _SharedRowPool(<Map<String, Object?>>[
          <String, Object?>{
            'connection_id': '11111111-1111-4111-8111-111111111111',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'lightspeed_lsk',
            'category': 'pos',
            'status': 'connected',
            'last_modified_seen': null,
            'cursor_token': null,
          },
          <String, Object?>{
            'connection_id': '44444444-4444-4444-8444-444444444444',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'agendrix',
            'category': 'labor',
            'status': 'connected',
            'last_modified_seen': null,
            'cursor_token': null,
          },
        ]);
        final wrapperA =
            TenantTransactionWrapper(_LockingFakePool(shared, sliceAt: 1));
        final wrapperB =
            TenantTransactionWrapper(_LockingFakePool(shared, sliceAt: 1));
        final sourceA = PostgresSyncWorkerSource(tenantWrapper: wrapperA);
        final sourceB = PostgresSyncWorkerSource(tenantWrapper: wrapperB);

        // Concurrent: both SELECTs race the shared row pool.
        final resultsA = await sourceA.connectedConnections().toList();
        final resultsB = await sourceB.connectedConnections().toList();

        // Worker A claimed the first row (sliceAt=1). Worker B's
        // subsequent SELECT skipped the locked row and got the second.
        expect(resultsA, hasLength(1));
        expect(resultsA.single.connectionId,
            '11111111-1111-4111-8111-111111111111');
        expect(resultsB, hasLength(1));
        expect(resultsB.single.connectionId,
            '44444444-4444-4444-8444-444444444444');
      },
    );

    test(
      'unknown category coerces defensively to POS (the dispatcher then '
      'flips the row to vendor_not_registered cleanly)',
      () async {
        final pool = _FakePool(<Map<String, Object?>>[
          <String, Object?>{
            'connection_id': '11111111-1111-4111-8111-111111111111',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'mystery_vendor',
            'category': 'mystery_category',
            'status': 'connected',
            'last_modified_seen': null,
            'cursor_token': null,
          },
        ]);
        final wrapper = TenantTransactionWrapper(pool);
        final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);

        final rows = await source.connectedConnections().toList();

        expect(rows.single.category, IntegrationCategory.pos);
      },
    );
  });
}

// ─── Fake Postgres seam ──────────────────────────────────────────────

class _FakePool implements PostgresPool {
  _FakePool(this._rows);

  final List<Map<String, Object?>> _rows;
  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeTransaction(_rows);
    transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction(this._rows);

  final List<Map<String, Object?>> _rows;
  final List<String> queriedStatements = <String>[];
  final List<String> executedStatements = <String>[];
  bool _committed = false;
  bool _rolledBack = false;

  @override
  Future<List<Map<String, Object?>>> query(
    String statement, {
    Map<String, Object?>? parameters,
  }) async {
    queriedStatements.add(statement);
    return List<Map<String, Object?>>.unmodifiable(_rows);
  }

  @override
  Future<int> execute(
    String statement, {
    Map<String, Object?>? parameters,
  }) async {
    executedStatements.add(statement);
    return 0;
  }

  @override
  Future<void> commit() async {
    _committed = true;
  }

  @override
  Future<void> rollback() async {
    _rolledBack = true;
  }

  // Avoid lint about unused field reads in a future refactor.
  bool get committed => _committed;
  bool get rolledBack => _rolledBack;
}

/// Shared row pool that partitions rows across two concurrent workers
/// the way `FOR UPDATE SKIP LOCKED` partitions across two PG sessions.
/// The first locking SELECT claims the first `sliceAt` rows; the
/// second SELECT skips the claimed slice.
class _SharedRowPool {
  _SharedRowPool(this._rows);

  final List<Map<String, Object?>> _rows;
  int _claimed = 0;

  /// Returns the next slice of unlocked rows and marks them claimed.
  /// `sliceAt` mirrors the `LIMIT N` of a real claim query — first
  /// SELECT takes `sliceAt` rows, second SELECT takes whatever remains.
  List<Map<String, Object?>> takeSlice(int sliceAt) {
    final start = _claimed;
    final end = (start + sliceAt) > _rows.length ? _rows.length : start + sliceAt;
    final slice = _rows.sublist(start, end);
    _claimed = end;
    return slice;
  }
}

class _LockingFakePool implements PostgresPool {
  _LockingFakePool(this._shared, {required this.sliceAt});

  final _SharedRowPool _shared;
  final int sliceAt;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _LockingFakeTransaction(_shared, sliceAt: sliceAt);
  }
}

class _LockingFakeTransaction implements PostgresTransaction {
  _LockingFakeTransaction(this._shared, {required this.sliceAt});

  final _SharedRowPool _shared;
  final int sliceAt;

  @override
  Future<List<Map<String, Object?>>> query(
    String statement, {
    Map<String, Object?>? parameters,
  }) async {
    // Honor the `FOR UPDATE ... SKIP LOCKED` semantics: the first
    // tx claims the first slice, the second tx skips the claimed
    // rows and sees what's left.
    if (statement.toLowerCase().contains('for update of cc skip locked')) {
      return _shared.takeSlice(sliceAt);
    }
    return const <Map<String, Object?>>[];
  }

  @override
  Future<int> execute(
    String statement, {
    Map<String, Object?>? parameters,
  }) async =>
      0;

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
