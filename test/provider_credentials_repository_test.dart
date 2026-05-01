// Phase 11A.4 — ProviderCredentialsRepository tests.
//
// Exercises the rotate-in-one-transaction contract through a fake
// Postgres pool. Asserts: the rotate path runs UPDATE prior
// is_active=false then INSERT new row in the same transaction, the
// `actor::uuid` parameter binds on both rows, and `listActive`
// returns only `is_active = true` rows ordered by `key_kind`.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/provider_credentials_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _actorId = '33333333-3333-4333-8333-333333333333';

void main() {
  group('ProviderCredentialsRepository.rotate', () {
    test(
      'flips prior is_active to false, then inserts new row, in one transaction',
      () async {
        final returnedRow = <String, Object?>{
          'credential_id': 'cred-new',
          'key_kind': 'anthropic',
          'masked_value': 'sk-a***1234',
          'kms_secret_name': 'kms://stub/new-uuid',
          'created_by': _actorId,
          'updated_by': _actorId,
          'is_active': true,
          'rotated_at': DateTime.utc(2026, 5, 1, 12),
          'created_at': DateTime.utc(2026, 5, 1, 12),
          'updated_at': DateTime.utc(2026, 5, 1, 12),
        };
        final pool = _ProviderCredentialsPool(insertReturnRow: returnedRow);
        final repo = ProviderCredentialsRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repo.rotate(
          keyKind: 'anthropic',
          maskedValue: 'sk-a***1234',
          kmsSecretName: 'kms://stub/new-uuid',
          actorUserId: _actorId,
          adminReason: 'admin.integrations.POST:tester:rotate:anthropic',
        );

        expect(row.credentialId, equals('cred-new'));
        expect(row.maskedValue, equals('sk-a***1234'));
        expect(row.isActive, isTrue);

        // Exactly one transaction. The wrapper issues `SET LOCAL`
        // statements alongside the repo's UPDATE/INSERT; filter to
        // the provider_credentials statements before asserting.
        expect(pool.transactions, hasLength(1));
        final tx = pool.transactions.single;
        final relevantStatements = <int>[];
        for (var i = 0; i < tx.executedSql.length; i++) {
          if (tx.executedSql[i].contains('provider_credentials')) {
            relevantStatements.add(i);
          }
        }
        expect(relevantStatements, hasLength(2));

        final updateIdx = relevantStatements[0];
        final insertIdx = relevantStatements[1];
        // Order matters: UPDATE prior runs BEFORE the INSERT so the
        // partial unique index on (key_kind) where is_active is
        // never violated.
        expect(updateIdx, lessThan(insertIdx));

        expect(tx.executedSql[updateIdx], contains('update provider_credentials'));
        expect(tx.executedSql[updateIdx], contains('is_active = false'));
        expect(
          tx.executedSql[updateIdx],
          contains('where key_kind = @key_kind'),
        );
        expect(tx.executedSql[updateIdx], contains('and is_active = true'));
        expect(tx.parameters[updateIdx]['key_kind'], equals('anthropic'));
        expect(tx.parameters[updateIdx]['actor'], equals(_actorId));

        expect(
          tx.executedSql[insertIdx],
          contains('insert into provider_credentials'),
        );
        expect(tx.executedSql[insertIdx], contains('is_active, rotated_at'));
        expect(tx.executedSql[insertIdx], contains('@key_kind'));
        expect(tx.executedSql[insertIdx], contains('@masked_value'));
        expect(tx.executedSql[insertIdx], contains('@kms_secret_name'));
        // The actor parameter binds on both `created_by` AND
        // `updated_by` so a fresh row carries the rotating admin's
        // user_id on both audit columns.
        expect(
          tx.executedSql[insertIdx],
          contains('@actor::uuid, @actor::uuid'),
        );
        expect(tx.parameters[insertIdx]['actor'], equals(_actorId));
        expect(
          tx.parameters[insertIdx]['masked_value'],
          equals('sk-a***1234'),
        );
        expect(
          tx.parameters[insertIdx]['kms_secret_name'],
          equals('kms://stub/new-uuid'),
        );
      },
    );
  });

  test(
    'rotate binds the actor UUID on both UPDATE prior and INSERT new params',
    () async {
      const distinctActor = '99999999-9999-4999-8999-999999999999';
      final returnedRow = <String, Object?>{
        'credential_id': 'cred-new',
        'key_kind': 'anthropic',
        'masked_value': 'sk-a***1234',
        'kms_secret_name': 'kms://stub/new-uuid',
        'created_by': distinctActor,
        'updated_by': distinctActor,
        'is_active': true,
        'rotated_at': DateTime.utc(2026, 5, 1, 12),
        'created_at': DateTime.utc(2026, 5, 1, 12),
        'updated_at': DateTime.utc(2026, 5, 1, 12),
      };
      final pool = _ProviderCredentialsPool(insertReturnRow: returnedRow);
      final repo = ProviderCredentialsRepository(
        TenantTransactionWrapper(pool),
      );

      await repo.rotate(
        keyKind: 'anthropic',
        maskedValue: 'sk-a***1234',
        kmsSecretName: 'kms://stub/new-uuid',
        actorUserId: distinctActor,
        adminReason: 'admin.integrations.POST:fb-uid:rotate:anthropic',
      );

      final tx = pool.transactions.single;
      // The proxy resolver guarantees a UUID-shaped actor reaches
      // the repo, so every actor binding ends up at the resolved
      // user UUID — no null leaks past the proxy boundary.
      for (final params in tx.parameters) {
        if (params.containsKey('actor')) {
          expect(params['actor'], equals(distinctActor));
        }
      }
    },
  );

  group('ProviderCredentialsRepository.listActive', () {
    test('selects only active rows, ordered by key_kind', () async {
      final pool = _ProviderCredentialsPool(
        listRows: <PostgresRow>[
          <String, Object?>{
            'credential_id': 'cred-anthropic',
            'key_kind': 'anthropic',
            'masked_value': 'sk-a***Q9aB',
            'kms_secret_name': 'kms://stub/anthropic',
            'created_by': _actorId,
            'updated_by': _actorId,
            'is_active': true,
            'rotated_at': DateTime.utc(2026, 4, 1),
            'created_at': DateTime.utc(2026, 4, 1),
            'updated_at': DateTime.utc(2026, 4, 1),
          },
        ],
      );
      final repo = ProviderCredentialsRepository(
        TenantTransactionWrapper(pool),
      );
      final rows = await repo.listActive(
        adminReason: 'admin.integrations.GET:tester:list',
      );
      expect(rows, hasLength(1));
      expect(rows.single.keyKind, equals('anthropic'));
      expect(rows.single.maskedValue, equals('sk-a***Q9aB'));

      final tx = pool.transactions.single;
      final selectStatement = tx.executedSql.firstWhere(
        (sql) => sql.contains('from provider_credentials'),
      );
      expect(selectStatement, contains('where is_active = true'));
      expect(selectStatement, contains('order by key_kind asc'));
    });
  });
}

class _ProviderCredentialsPool implements PostgresPool {
  _ProviderCredentialsPool({
    this.listRows = const <PostgresRow>[],
    this.insertReturnRow,
  });

  final List<PostgresRow> listRows;
  final PostgresRow? insertReturnRow;
  final List<_ProviderCredentialsTransaction> transactions =
      <_ProviderCredentialsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ProviderCredentialsTransaction(
      listRows: listRows,
      insertReturnRow: insertReturnRow,
    );
    transactions.add(tx);
    return tx;
  }
}

class _ProviderCredentialsTransaction extends PostgresTransaction {
  _ProviderCredentialsTransaction({
    required this.listRows,
    required this.insertReturnRow,
  });

  final List<PostgresRow> listRows;
  final PostgresRow? insertReturnRow;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql,
    {PostgresParameters parameters = const <String, Object?>{}}
  ) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into provider_credentials')) {
      final row = insertReturnRow;
      if (row == null) {
        throw StateError('insert called without an insertReturnRow');
      }
      return <PostgresRow>[row];
    }
    if (sql.contains('from provider_credentials')) {
      return listRows;
    }
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql,
    {PostgresParameters parameters = const <String, Object?>{}}
  ) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
