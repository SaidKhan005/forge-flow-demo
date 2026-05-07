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
