// Phase 8 (`8.transport.clover-pos`) — Postgres credential store tests.
//
// Covers:
//   * readMerchantId returns metadata.merchant_id when present, null
//     when missing.
//   * readWebhookSubscriptionId returns metadata.webhook_subscription_id
//     when present, null when missing.
//   * wipe nulls vendor_credentials ciphertext columns and flips the
//     connector_connection row to disconnected.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_postgres_credential_store.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  group('CloverPosPostgresCredentialStore — readMerchantId', () {
    test('returns metadata.merchant_id when present', () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA, metadata: <String, Object?>{
          'merchant_id': 'M-9001',
        });
      final store = CloverPosPostgresCredentialStore(
        TenantTransactionWrapper(pool),
      );
      final id = await store.readMerchantId(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(id, 'M-9001');
    });

    test('returns null when no connection row', () async {
      final pool = _FakePool();
      final store = CloverPosPostgresCredentialStore(
        TenantTransactionWrapper(pool),
      );
      final id = await store.readMerchantId(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(id, isNull);
    });

    test('returns null when metadata.merchant_id missing', () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA, metadata: const <String, Object?>{});
      final store = CloverPosPostgresCredentialStore(
        TenantTransactionWrapper(pool),
      );
      final id = await store.readMerchantId(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(id, isNull);
    });
  });

  group('CloverPosPostgresCredentialStore — readWebhookSubscriptionId', () {
    test('returns metadata.webhook_subscription_id when present', () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA, metadata: <String, Object?>{
          'webhook_subscription_id': 'sub-1',
        });
      final store = CloverPosPostgresCredentialStore(
        TenantTransactionWrapper(pool),
      );
      final id = await store.readWebhookSubscriptionId(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(id, 'sub-1');
    });

    test('returns null when key missing', () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA, metadata: const <String, Object?>{});
      final store = CloverPosPostgresCredentialStore(
        TenantTransactionWrapper(pool),
      );
      final id = await store.readWebhookSubscriptionId(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(id, isNull);
    });
  });

  group('CloverPosPostgresCredentialStore — wipe', () {
    test('nulls vendor_credentials ciphertext + flips connection to disconnected',
        () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA, metadata: <String, Object?>{
          'merchant_id': 'M-9001',
        })
        ..seedCredential(_opA, _locA);
      final store = CloverPosPostgresCredentialStore(
        TenantTransactionWrapper(pool),
      );
      final ok = await store.wipe(operatorId: _opA, locationId: _locA);
      expect(ok, isTrue);
      final cred = pool.credentials['$_opA|$_locA|clover']!;
      expect(cred['access_token_ciphertext'], isNull);
      expect(cred['refresh_token_ciphertext'], isNull);
      expect(cred['is_active'], isFalse);
      expect(pool.connectionStatus['$_opA|$_locA|clover'], 'disconnected');
      expect(pool.disconnectReason['$_opA|$_locA|clover'], 'operator_action');
      expect(pool.webhookProvisioned['$_opA|$_locA|clover'], isFalse);
    });

    test('returns true even when no rows match (idempotent)', () async {
      final pool = _FakePool();
      final store = CloverPosPostgresCredentialStore(
        TenantTransactionWrapper(pool),
      );
      final ok = await store.wipe(operatorId: _opA, locationId: _locA);
      expect(ok, isTrue);
    });
  });
}

class _FakePool implements PostgresPool {
  final Map<String, Map<String, Object?>> _connectionMetadata =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> credentials =
      <String, Map<String, Object?>>{};
  final Map<String, String> connectionStatus = <String, String>{};
  final Map<String, String?> disconnectReason = <String, String?>{};
  final Map<String, bool> webhookProvisioned = <String, bool>{};

  void seedConnection(
    String operatorId,
    String locationId, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final key = '$operatorId|$locationId|clover';
    _connectionMetadata[key] = <String, Object?>{...metadata};
    connectionStatus[key] = 'connected';
    disconnectReason[key] = null;
    webhookProvisioned[key] = true;
  }

  void seedCredential(String operatorId, String locationId) {
    final key = '$operatorId|$locationId|clover';
    credentials[key] = <String, Object?>{
      'access_token_ciphertext': <int>[1, 2, 3],
      'refresh_token_ciphertext': <int>[4, 5, 6],
      'is_active': true,
    };
  }

  @override
  Future<PostgresTransaction> beginTransaction() async => _FakeTransaction(this);
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction(this.pool);
  final _FakePool pool;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) return const <PostgresRow>[];
    if (sql.contains('select metadata->>@metadata_key as value')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final key = '$operatorId|$locationId|clover';
      if (!pool._connectionMetadata.containsKey(key)) {
        return const <PostgresRow>[];
      }
      final metadataKey = parameters['metadata_key'] as String;
      final value = pool._connectionMetadata[key]?[metadataKey];
      return <PostgresRow>[
        <String, Object?>{'value': value},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) return 0;
    if (sql.contains('update public.vendor_credentials')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final key = '$operatorId|$locationId|clover';
      final cred = pool.credentials[key];
      if (cred == null) return 0;
      cred['access_token_ciphertext'] = null;
      cred['refresh_token_ciphertext'] = null;
      cred['token_expires_at'] = null;
      cred['is_active'] = false;
      cred['consecutive_refresh_failures'] = 0;
      return 1;
    }
    if (sql.contains('update public.connector_connection')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final key = '$operatorId|$locationId|clover';
      if (!pool._connectionMetadata.containsKey(key)) return 0;
      pool.connectionStatus[key] = 'disconnected';
      pool.disconnectReason[key] = 'operator_action';
      pool.webhookProvisioned[key] = false;
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
