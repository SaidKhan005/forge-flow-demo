// Lane B B2.3 — DefaultRoleCatalogVersionsRepository.getBlastRadiusCounts
// unit tests.
//
// Pins the SQL shape + runAsSystem posture for the new B2.3
// blast-radius read helper. Mirrors the discipline of the sibling
// `default_role_catalog_versions_repository_test.dart` (fake Postgres
// pool that records every SQL + parameter map) so a future re-audit
// can compare both files side-by-side.
//
// What we assert:
//   1. Routes through runAsSystem (forge_admin BYPASSRLS): the SET
//      LOCAL ROLE line precedes the count query.
//   2. Uses a single CTE so the three counts share one snapshot of
//      `operators` — a concurrent operator-flip cannot leak into a
//      partial result.
//   3. Binds the version_id parameter as uuid (the column is uuid-
//      typed in the migration).
//   4. Returns zero counts when no operators are pinned (PR-merge
//      time / pre-first-live-operator state).
//   5. Returns the recorded counts when one operator is pinned (one
//      operator → one location → one user fan-out).
//   6. Returns the recorded counts when multiple operators are pinned
//      (fan-out test).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/default_role_catalog_versions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _kVersionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

void main() {
  group('DefaultRoleCatalogVersionsRepository.getBlastRadiusCounts', () {
    test('zero state: no operators pinned → all three counts zero', () async {
      final pool = _RecordingPool(
        operatorCount: 0,
        locationCount: 0,
        userCount: 0,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      final counts = await repo.getBlastRadiusCounts(versionId: _kVersionId);
      expect(counts.versionId, equals(_kVersionId));
      expect(counts.operatorCount, equals(0));
      expect(counts.locationCount, equals(0));
      expect(counts.userCount, equals(0));
    });

    test('routes through runAsSystem (SET LOCAL ROLE forge_admin)',
        () async {
      final pool = _RecordingPool(
        operatorCount: 0,
        locationCount: 0,
        userCount: 0,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      await repo.getBlastRadiusCounts(versionId: _kVersionId);
      final tx = pool.transactions.single;
      expect(
        tx.executedSql.first,
        contains("set_config('app.bypass_rls_audit'"),
      );
      expect(tx.executedSql[1], equals('set local role forge_admin'));
      // The CTE query runs after the role elevation.
      expect(tx.executedSql.last, contains('with pinned_operators as'));
    });

    test('binds version_id as uuid parameter', () async {
      final pool = _RecordingPool(
        operatorCount: 0,
        locationCount: 0,
        userCount: 0,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      await repo.getBlastRadiusCounts(versionId: _kVersionId);
      final tx = pool.transactions.single;
      final countsSql = tx.executedSql.firstWhere(
        (s) => s.contains('with pinned_operators as'),
      );
      expect(countsSql, contains('@version_id::uuid'));
      final params = tx.parameters[tx.executedSql.indexOf(countsSql)];
      expect(params['version_id'], equals(_kVersionId));
    });

    test('CTE query references operators + locations + users', () async {
      final pool = _RecordingPool(
        operatorCount: 0,
        locationCount: 0,
        userCount: 0,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      await repo.getBlastRadiusCounts(versionId: _kVersionId);
      final tx = pool.transactions.single;
      final countsSql = tx.executedSql.firstWhere(
        (s) => s.contains('with pinned_operators as'),
      );
      // The CTE is the only authoritative source of the pinned set;
      // both fan-out counts join through it.
      expect(countsSql, contains('from public.operators'));
      expect(countsSql, contains('default_role_catalog_version_id'));
      expect(countsSql, contains('from public.locations'));
      expect(countsSql, contains('from public.users'));
    });

    test('single-operator fan-out: 1 operator, 1 location, 1 user',
        () async {
      final pool = _RecordingPool(
        operatorCount: 1,
        locationCount: 1,
        userCount: 1,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      final counts = await repo.getBlastRadiusCounts(versionId: _kVersionId);
      expect(counts.operatorCount, equals(1));
      expect(counts.locationCount, equals(1));
      expect(counts.userCount, equals(1));
    });

    test('multi-operator fan-out: 47 operators, 312 locations, 1403 users',
        () async {
      final pool = _RecordingPool(
        operatorCount: 47,
        locationCount: 312,
        userCount: 1403,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      final counts = await repo.getBlastRadiusCounts(versionId: _kVersionId);
      expect(counts.operatorCount, equals(47));
      expect(counts.locationCount, equals(312));
      expect(counts.userCount, equals(1403));
    });

    test('returns versionId verbatim (echoes caller input)', () async {
      const String customId = '00000000-1111-2222-3333-444444444444';
      final pool = _RecordingPool(
        operatorCount: 2,
        locationCount: 5,
        userCount: 8,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      final counts = await repo.getBlastRadiusCounts(versionId: customId);
      expect(counts.versionId, equals(customId));
    });

    test('toJson returns the four-key shape the proxy serialises',
        () async {
      const counts = DefaultRoleCatalogBlastRadiusCounts(
        versionId: 'v',
        operatorCount: 3,
        locationCount: 7,
        userCount: 11,
      );
      expect(counts.toJson(), <String, Object?>{
        'version_id': 'v',
        'operator_count': 3,
        'location_count': 7,
        'user_count': 11,
      });
    });
  });
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    required this.operatorCount,
    required this.locationCount,
    required this.userCount,
  });

  final int operatorCount;
  final int locationCount;
  final int userCount;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('with pinned_operators as')) {
      return <PostgresRow>[
        <String, Object?>{
          'operator_count': operatorCount,
          'location_count': locationCount,
          'user_count': userCount,
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
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}

class _RecordingPool implements PostgresPool {
  _RecordingPool({
    required this.operatorCount,
    required this.locationCount,
    required this.userCount,
  });

  final int operatorCount;
  final int locationCount;
  final int userCount;

  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      operatorCount: operatorCount,
      locationCount: locationCount,
      userCount: userCount,
    );
    transactions.add(tx);
    return tx;
  }
}
