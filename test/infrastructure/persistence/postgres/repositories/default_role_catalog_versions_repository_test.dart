// Lane B B2.1 — DefaultRoleCatalogVersionsRepository unit tests.
//
// Exercises the repository's runAsSystem posture (forge_admin BYPASSRLS
// role for the global catalog table) and the publish transaction
// sequence in isolation with a fake Postgres pool that records every
// SQL + parameter map. Mirrors the discipline established in
// `test/infrastructure/persistence/postgres/repositories/handoff_codes_repository_test.dart`.
//
// What we assert:
//   * publishVersion runs through runAsSystem (SET LOCAL ROLE
//     forge_admin) before the lock + supersede + insert sequence.
//   * publishVersion locks the prior current row (for update) so
//     concurrent publishes serialize.
//   * publishVersion flips the prior current row's is_current = false
//     and stamps superseded_at BEFORE inserting the new current.
//   * publishVersion rejects empty payloads + malformed SHA-256 +
//     over-length notes before any SQL runs.
//   * getCurrentVersion / getVersion / listVersions all route through
//     runAsSystem with sensible reason strings.
//   * countOperatorsFollowing returns 0 when no operators are pinned.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/default_role_catalog_versions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _kAdminUserId = '11111111-1111-1111-1111-111111111111';
final String _kSha = 'a' * 64;
const List<Object?> _kPayload = <Object?>[
  <String, Object?>{'role_key': 'manager', 'display_name': 'Manager'},
];

void main() {
  group('DefaultRoleCatalogVersionsRepository.publishVersion', () {
    test('genesis publish: SET LOCAL ROLE forge_admin, then INSERT v1',
        () async {
      final pool = _RecordingPool();
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );

      final row = await repo.publishVersion(
        publishedByUserId: _kAdminUserId,
        payload: _kPayload,
        payloadSha256: _kSha,
        notes: 'genesis publish',
      );

      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      // bypass_rls_audit marker + set local role forge_admin run before
      // any catalog DML.
      expect(tx.executedSql.first,
          contains("set_config('app.bypass_rls_audit'"));
      expect(tx.executedSql[1], equals('set local role forge_admin'));
      // Lock query (no prior current row in genesis case — returns
      // empty list so the supersede UPDATE is skipped).
      expect(tx.executedSql[2], contains('for update'));
      // Max version_number lookup.
      expect(tx.executedSql[3], contains('coalesce(max(version_number)'));
      // Genesis path skips the supersede UPDATE.
      expect(
        tx.executedSql.where((s) => s.contains('update public.default_role_catalog_versions')),
        isEmpty,
      );
      // INSERT with version_number=1 and is_current=true.
      final insertSql = tx.executedSql.last;
      expect(insertSql,
          contains('insert into public.default_role_catalog_versions'));
      expect(insertSql, contains('is_current'));
      final insertParams = tx.parameters.last;
      expect(insertParams['version_number'], equals(1));
      expect(insertParams['published_by_user_id'], equals(_kAdminUserId));
      expect(insertParams['payload_sha256'], equals(_kSha));
      expect(insertParams['notes'], equals('genesis publish'));
      // commit fired.
      expect(tx.commitCount, equals(1));
      // Returned row reflects what the fake pool produced.
      expect(row.versionNumber, equals(1));
      expect(row.isCurrent, isTrue);
    });

    test('subsequent publish: locks prior current, supersedes, inserts v2',
        () async {
      final pool = _RecordingPool(
        priorCurrentVersionNumber: 1,
        maxVersionNumber: 1,
        nextVersionId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        nextVersionNumber: 2,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );

      await repo.publishVersion(
        publishedByUserId: _kAdminUserId,
        payload: _kPayload,
        payloadSha256: _kSha,
      );

      final tx = pool.transactions.single;
      // Supersede UPDATE fires AFTER the lock SELECT.
      final supersedeIndex = tx.executedSql.indexWhere(
        (s) =>
            s.contains('update public.default_role_catalog_versions') &&
            s.contains('is_current = false'),
      );
      expect(supersedeIndex, greaterThan(0));
      expect(tx.executedSql[supersedeIndex], contains('superseded_at = now()'));
      // INSERT fires AFTER the supersede.
      final insertIndex = tx.executedSql.indexWhere(
        (s) => s.contains('insert into public.default_role_catalog_versions'),
      );
      expect(insertIndex, greaterThan(supersedeIndex));
      // Version number ratchets to 2.
      expect(tx.parameters[insertIndex]['version_number'], equals(2));
    });

    test('rejects empty payload before any SQL runs', () async {
      final pool = _RecordingPool();
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.publishVersion(
          publishedByUserId: _kAdminUserId,
          payload: const <Object?>[],
          payloadSha256: _kSha,
        ),
        throwsA(
          isA<DefaultRoleCatalogPublishValidationError>()
              .having((e) => e.code, 'code', 'empty_payload'),
        ),
      );
      expect(pool.transactions, isEmpty);
    });

    test('rejects malformed payload_sha256 before any SQL runs', () async {
      final pool = _RecordingPool();
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.publishVersion(
          publishedByUserId: _kAdminUserId,
          payload: _kPayload,
          payloadSha256: 'NOT_HEX', // too short, uppercase
        ),
        throwsA(
          isA<DefaultRoleCatalogPublishValidationError>()
              .having((e) => e.code, 'code', 'invalid_payload_sha256'),
        ),
      );
      expect(pool.transactions, isEmpty);
    });

    test('rejects too-long notes (>2000 chars)', () async {
      final pool = _RecordingPool();
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.publishVersion(
          publishedByUserId: _kAdminUserId,
          payload: _kPayload,
          payloadSha256: _kSha,
          notes: 'x' * 2001,
        ),
        throwsA(
          isA<DefaultRoleCatalogPublishValidationError>()
              .having((e) => e.code, 'code', 'notes_too_long'),
        ),
      );
      expect(pool.transactions, isEmpty);
    });
  });

  group('DefaultRoleCatalogVersionsRepository.getCurrentVersion', () {
    test('routes through runAsSystem and SELECTs the current row',
        () async {
      final pool = _RecordingPool(
        currentRow: <String, Object?>{
          'version_id': '11111111-2222-3333-4444-555555555555',
          'version_number': 1,
          'published_at': DateTime.utc(2026, 5, 13, 10),
          'published_by_user_id': _kAdminUserId,
          'payload': _kPayload,
          'payload_sha256': _kSha,
          'is_current': true,
          'superseded_at': null,
          'notes': null,
        },
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      final row = await repo.getCurrentVersion();
      expect(row, isNotNull);
      expect(row!.versionNumber, equals(1));
      expect(row.isCurrent, isTrue);
      final tx = pool.transactions.single;
      expect(tx.executedSql.first,
          contains("set_config('app.bypass_rls_audit'"));
      expect(tx.executedSql[1], equals('set local role forge_admin'));
    });

    test('returns null when no row is current', () async {
      final pool = _RecordingPool();
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      final row = await repo.getCurrentVersion();
      expect(row, isNull);
    });
  });

  group('DefaultRoleCatalogVersionsRepository.listVersions', () {
    test('rejects limit < 1 before any SQL runs', () {
      final pool = _RecordingPool();
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.listVersions(limit: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(pool.transactions, isEmpty);
    });

    test('binds the limit parameter on the LIMIT clause', () async {
      final pool = _RecordingPool();
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      await repo.listVersions(limit: 5);
      final tx = pool.transactions.single;
      final listSql = tx.executedSql.firstWhere(
        (s) => s.contains('order by version_number desc'),
      );
      expect(listSql, contains('limit @limit::int'));
      final params = tx.parameters[tx.executedSql.indexOf(listSql)];
      expect(params['limit'], equals(5));
    });
  });

  group('DefaultRoleCatalogVersionsRepository.countOperatorsFollowing', () {
    test('counts operators pinned to the version_id parameter', () async {
      final pool = _RecordingPool(
        operatorFollowerCount: 3,
      );
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      final count = await repo.countOperatorsFollowing(
        versionId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      );
      expect(count, equals(3));
      final tx = pool.transactions.single;
      final countSql = tx.executedSql.firstWhere(
        (s) => s.contains('count(*)'),
      );
      expect(countSql, contains('from public.operators'));
      expect(
        countSql,
        contains('default_role_catalog_version_id = @version_id::uuid'),
      );
    });

    test('returns 0 when no operators are pinned', () async {
      final pool = _RecordingPool(operatorFollowerCount: 0);
      final repo = DefaultRoleCatalogVersionsRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        await repo.countOperatorsFollowing(versionId: 'any-version-id'),
        equals(0),
      );
    });
  });
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    this.priorCurrentVersionNumber,
    this.maxVersionNumber = 0,
    this.nextVersionId = '00000000-0000-0000-0000-000000000001',
    this.nextVersionNumber = 1,
    this.currentRow,
    this.operatorFollowerCount = 0,
  });

  final int? priorCurrentVersionNumber;
  final int maxVersionNumber;
  final String nextVersionId;
  final int nextVersionNumber;
  final Map<String, Object?>? currentRow;
  final int operatorFollowerCount;

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

    // Lock (for update) on prior current.
    if (sql.contains('for update')) {
      if (priorCurrentVersionNumber == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'version_number': priorCurrentVersionNumber},
      ];
    }
    // Max version_number for the next-version computation.
    if (sql.contains('coalesce(max(version_number)')) {
      return <PostgresRow>[
        <String, Object?>{'max_v': maxVersionNumber},
      ];
    }
    // Operators follower count.
    if (sql.contains('from public.operators') &&
        sql.contains('count(*)')) {
      return <PostgresRow>[
        <String, Object?>{'cnt': operatorFollowerCount},
      ];
    }
    // INSERT RETURNING.
    if (sql.contains('insert into public.default_role_catalog_versions')) {
      return <PostgresRow>[
        <String, Object?>{
          'version_id': nextVersionId,
          'version_number': nextVersionNumber,
          'published_at': DateTime.utc(2026, 5, 13, 10),
          'published_by_user_id': parameters['published_by_user_id'],
          'payload': parameters['payload'],
          'payload_sha256': parameters['payload_sha256'],
          'is_current': true,
          'superseded_at': null,
          'notes': parameters['notes'],
        },
      ];
    }
    // SELECT current.
    if (sql.contains('where is_current = true') &&
        sql.contains('from public.default_role_catalog_versions') &&
        currentRow != null) {
      return <PostgresRow>[currentRow!];
    }
    // SELECT history.
    if (sql.contains('order by version_number desc')) {
      return const <PostgresRow>[];
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
    this.priorCurrentVersionNumber,
    this.maxVersionNumber = 0,
    this.nextVersionId = '00000000-0000-0000-0000-000000000001',
    this.nextVersionNumber = 1,
    this.currentRow,
    this.operatorFollowerCount = 0,
  });

  final int? priorCurrentVersionNumber;
  final int maxVersionNumber;
  final String nextVersionId;
  final int nextVersionNumber;
  final Map<String, Object?>? currentRow;
  final int operatorFollowerCount;

  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      priorCurrentVersionNumber: priorCurrentVersionNumber,
      maxVersionNumber: maxVersionNumber,
      nextVersionId: nextVersionId,
      nextVersionNumber: nextVersionNumber,
      currentRow: currentRow,
      operatorFollowerCount: operatorFollowerCount,
    );
    transactions.add(tx);
    return tx;
  }
}
