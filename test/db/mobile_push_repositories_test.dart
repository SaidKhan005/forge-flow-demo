import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mobile_push_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mobile_push_tokens_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _op = '11111111-1111-1111-1111-111111111111';
const String _loc = '22222222-2222-2222-2222-222222222222';
const String _user = '33333333-3333-3333-3333-333333333333';
const String _tokenId = '44444444-4444-4444-4444-444444444444';
const String _messageId = '55555555-5555-5555-5555-555555555555';

void main() {
  group('MobilePushTokensRepository', () {
    test(
      'register encrypts token server-side and returns safe metadata',
      () async {
        final now = DateTime.utc(2026, 5, 6, 12);
        final pool = _RecordingPool(
          queryRows: <PostgresRow>[
            _tokenRow(now: now, tokenHash: _hash('fcm-token-123')),
          ],
        );
        final repo = MobilePushTokensRepository(TenantTransactionWrapper(pool));

        final row = await repo.register(
          const MobilePushTokenRegistration(
            operatorId: _op,
            locationId: _loc,
            userId: _user,
            token: 'fcm-token-123',
            platform: 'android',
            provider: 'fcm',
            appVariant: 'operator',
            appEnvironment: 'staging',
            installationId: 'install-1',
            envelopeKey: 'envelope-key',
            clientInfo: <String, Object?>{'app_version': '1.2.3'},
          ),
        );

        final tx = pool.transactions.single;
        final insertSql = tx.querySql.single;
        expect(
          insertSql,
          contains('pgp_sym_encrypt(@token_plaintext, @envelope_key)'),
        );
        expect(insertSql, contains('on conflict'));
        expect(
          tx.queryParameters.single['token_hash'],
          equals(_hash('fcm-token-123')),
        );
        expect(
          tx.queryParameters.single['token_plaintext'],
          equals('fcm-token-123'),
        );
        expect(
          tx.queryParameters.single['envelope_key'],
          equals('envelope-key'),
        );
        expect(tx.queryParameters.single['operator_id'], equals(_op));
        expect(tx.executeSql.first, contains("set_config('app.operator_id'"));
        expect(row.toSafeJson().toString(), isNot(contains('fcm-token-123')));
        expect(row.toSafeJson().toString(), isNot(contains(row.tokenHash)));
        expect(row.pushTokenId, equals(_tokenId));
      },
    );

    test(
      'revoke hashes a token selector and never binds plaintext token',
      () async {
        final pool = _RecordingPool(executeCount: 1);
        final repo = MobilePushTokensRepository(TenantTransactionWrapper(pool));
        final affected = await repo.revoke(
          const MobilePushTokenRevokeCommand(
            operatorId: _op,
            locationId: _loc,
            userId: _user,
            appVariant: 'operator',
            appEnvironment: 'staging',
            token: 'fcm-token-123',
          ),
        );

        expect(affected, equals(1));
        final tx = pool.transactions.single;
        final updateSql = tx.executeSql.last;
        expect(updateSql, contains('token_hash = @token_hash'));
        expect(
          tx.executeParameters.last['token_hash'],
          equals(_hash('fcm-token-123')),
        );
        expect(tx.executeParameters.last.containsKey('token'), isFalse);
        expect(
          tx.executeParameters.last.containsKey('token_plaintext'),
          isFalse,
        );
      },
    );

    test(
      'listSendableTokensForUser decrypts only inside tenant scope',
      () async {
        final pool = _RecordingPool(
          queryRows: <PostgresRow>[
            <String, Object?>{
              'push_token_id': _tokenId,
              'user_id': _user,
              'platform': 'ios',
              'provider': 'fcm',
              'app_variant': 'operator',
              'app_environment': 'staging',
              'token_plaintext': 'decrypted-fcm-token',
            },
          ],
        );
        final repo = MobilePushTokensRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listSendableTokensForUser(
          operatorId: _op,
          locationId: _loc,
          userId: _user,
          appVariant: 'operator',
          appEnvironment: 'staging',
          envelopeKey: 'envelope-key',
        );

        final tx = pool.transactions.single;
        expect(
          tx.querySql.single,
          contains('pgp_sym_decrypt(token_ciphertext, @envelope_key)'),
        );
        expect(tx.querySql.single, contains('revoked_at is null'));
        expect(tx.querySql.single, contains('disabled_at is null'));
        expect(
          tx.queryParameters.single['envelope_key'],
          equals('envelope-key'),
        );
        expect(rows.single.token, equals('decrypted-fcm-token'));
      },
    );
  });

  group('MobilePushOutboxRepository', () {
    test('enqueue stores push payload sidecar with source outbox id', () async {
      final pool = _RecordingPool(
        queryRows: <PostgresRow>[
          _messageRow(data: const <String, Object?>{'route': '/shift'}),
        ],
      );
      final repo = MobilePushOutboxRepository(TenantTransactionWrapper(pool));
      final row = await repo.enqueue(
        const MobilePushOutboxEnqueue(
          operatorId: _op,
          locationId: _loc,
          userId: _user,
          sourceOutboxId: '101',
          sourceTopic: 'auth.user.mfa_recovery_requested',
          dedupeKey: 'auth.user.mfa_recovery_requested:101',
          appVariant: 'operator',
          appEnvironment: 'staging',
          title: 'Recovery requested',
          body: 'A recovery request needs review.',
          data: <String, Object?>{'route': '/shift'},
        ),
      );

      final tx = pool.transactions.single;
      expect(tx.querySql.single, contains('public.mobile_push_outbox'));
      expect(tx.querySql.single, contains('@source_outbox_id::bigint'));
      expect(
        tx.querySql.single,
        contains('on conflict (operator_id, dedupe_key)'),
      );
      expect(tx.queryParameters.single['source_outbox_id'], equals('101'));
      expect(row.sourceOutboxId, equals('101'));
    });

    test('claimBatch uses durable queue claim shape', () async {
      final pool = _RecordingPool(queryRows: <PostgresRow>[_messageRow()]);
      final repo = MobilePushOutboxRepository(TenantTransactionWrapper(pool));
      final rows = await repo.claimBatch(
        operatorId: _op,
        locationId: _loc,
        batchSize: 10,
        userId: _user,
      );

      final tx = pool.transactions.single;
      final claimSql = tx.querySql.single;
      expect(claimSql, contains("status in ('pending', 'partial_failed')"));
      expect(claimSql, contains('for update skip locked'));
      expect(claimSql, contains("set status = 'sending'"));
      expect(claimSql, contains('attempt_count = attempt_count + 1'));
      expect(tx.queryParameters.single['batch_size'], equals(10));
      expect(rows.single.messageId, equals(_messageId));
    });
  });
}

PostgresRow _tokenRow({required DateTime now, required String tokenHash}) {
  return <String, Object?>{
    'push_token_id': _tokenId,
    'operator_id': _op,
    'user_id': _user,
    'platform': 'android',
    'provider': 'fcm',
    'app_variant': 'operator',
    'app_environment': 'staging',
    'installation_id': 'install-1',
    'token_hash': tokenHash,
    'enabled_at': now,
    'revoked_at': null,
    'last_seen_at': now,
    'last_sent_at': null,
  };
}

PostgresRow _messageRow({
  Map<String, Object?> data = const <String, Object?>{},
}) {
  return <String, Object?>{
    'message_id': _messageId,
    'operator_id': _op,
    'user_id': _user,
    'source_outbox_id': '101',
    'source_topic': 'auth.user.mfa_recovery_requested',
    'dedupe_key': 'auth.user.mfa_recovery_requested:101',
    'app_variant': 'operator',
    'app_environment': 'staging',
    'title': 'Recovery requested',
    'body': 'A recovery request needs review.',
    'deeplink': '/settings/security',
    'data': data,
    'status': 'sending',
    'attempt_count': 1,
  };
}

String _hash(String value) => sha256.convert(value.codeUnits).toString();

class _RecordingPool implements PostgresPool {
  _RecordingPool({
    this.queryRows = const <PostgresRow>[],
    this.executeCount = 0,
  });

  final List<PostgresRow> queryRows;
  final int executeCount;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      queryRows: queryRows,
      executeCount: executeCount,
    );
    transactions.add(tx);
    return tx;
  }
}

class _RecordingTransaction implements PostgresTransaction {
  _RecordingTransaction({required this.queryRows, required this.executeCount});

  final List<PostgresRow> queryRows;
  final int executeCount;
  final List<String> querySql = <String>[];
  final List<PostgresParameters> queryParameters = <PostgresParameters>[];
  final List<String> executeSql = <String>[];
  final List<PostgresParameters> executeParameters = <PostgresParameters>[];
  int commitCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    querySql.add(sql);
    queryParameters.add(parameters);
    return queryRows;
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executeSql.add(sql);
    executeParameters.add(parameters);
    return executeCount;
  }

  @override
  Future<void> commit() async {
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {}
}
