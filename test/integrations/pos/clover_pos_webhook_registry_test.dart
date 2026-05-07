// Phase 8 (`8.transport.clover-pos`) — webhook registry tests.
//
// Covers:
//   * register subscribes via the API and persists subscription id on
//     `connector_connection.metadata`.
//   * idempotent re-subscribe: second register with subscription id
//     already on file does not call the vendor API again.
//   * unregister calls vendor DELETE and clears metadata key.
//   * unregister tolerates 404 (vendor already revoked) — clears
//     metadata, returns true.
//   * unregister returns false on auth/server error but still clears
//     metadata so a reconnect starts clean.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_production_api_client.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_webhook_registry.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _merchantId = 'M-9001';
const String _callbackUrl = 'https://app.forgeflow.app/v1/integrations/clover/webhook';
const String _subscriptionId = 'sub-1';

void main() {
  group('CloverPosWebhookRegistry — register', () {
    test('subscribes via API and persists subscription id on metadata',
        () async {
      final pool = _FakePool()..seedConnection(_opA, _locA);
      final api = _FakeCloverApi();
      final registry = CloverPosWebhookRegistry(
        TenantTransactionWrapper(pool),
        api: api,
        callbackUrlSource: () => _callbackUrl,
      );

      final id = await registry.register(
        operatorId: _opA,
        locationId: _locA,
        merchantId: _merchantId,
      );

      expect(id, _subscriptionId);
      expect(api.registerCalls, 1);
      expect(api.lastRegisterMerchantId, _merchantId);
      expect(api.lastRegisterCallbackUrl, _callbackUrl);
      expect(pool.metadata['$_opA|$_locA|clover'],
          containsPair('webhook_subscription_id', _subscriptionId));
      expect(pool.webhookProvisioned['$_opA|$_locA|clover'], isTrue);
    });

    test('idempotent re-register skips vendor API', () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA)
        ..seedMetadata(_opA, _locA,
            <String, Object?>{'webhook_subscription_id': _subscriptionId});
      final api = _FakeCloverApi();
      final registry = CloverPosWebhookRegistry(
        TenantTransactionWrapper(pool),
        api: api,
        callbackUrlSource: () => _callbackUrl,
      );

      final id = await registry.register(
        operatorId: _opA,
        locationId: _locA,
        merchantId: _merchantId,
      );

      expect(id, _subscriptionId);
      expect(api.registerCalls, 0,
          reason: 'second register must not re-POST to Clover');
    });

    test('rejects empty merchant id', () async {
      final registry = CloverPosWebhookRegistry(
        TenantTransactionWrapper(_FakePool()),
        api: _FakeCloverApi(),
        callbackUrlSource: () => _callbackUrl,
      );
      expect(
        () => registry.register(
          operatorId: _opA,
          locationId: _locA,
          merchantId: '',
        ),
        throwsArgumentError,
      );
    });

    test('throws when callback URL source returns empty', () async {
      final pool = _FakePool()..seedConnection(_opA, _locA);
      final registry = CloverPosWebhookRegistry(
        TenantTransactionWrapper(pool),
        api: _FakeCloverApi(),
        callbackUrlSource: () => '',
      );
      await expectLater(
        registry.register(
          operatorId: _opA,
          locationId: _locA,
          merchantId: _merchantId,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('CloverPosWebhookRegistry — unregister', () {
    test('calls vendor DELETE and clears metadata key', () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA)
        ..seedMetadata(_opA, _locA, <String, Object?>{
          'webhook_subscription_id': _subscriptionId,
          'merchant_id': _merchantId,
        });
      final api = _FakeCloverApi();
      final registry = CloverPosWebhookRegistry(
        TenantTransactionWrapper(pool),
        api: api,
        callbackUrlSource: () => _callbackUrl,
      );

      final ok = await registry.unregister(
        operatorId: _opA,
        locationId: _locA,
        merchantId: _merchantId,
        subscriptionId: _subscriptionId,
      );

      expect(ok, isTrue);
      expect(api.unregisterCalls, 1);
      // Metadata key removed; merchant_id preserved.
      expect(pool.metadata['$_opA|$_locA|clover']!.containsKey('webhook_subscription_id'),
          isFalse);
      expect(pool.metadata['$_opA|$_locA|clover']!['merchant_id'],
          _merchantId);
      expect(pool.webhookProvisioned['$_opA|$_locA|clover'], isFalse);
    });

    test('tolerates 404 from Clover (already revoked) and returns true',
        () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA)
        ..seedMetadata(_opA, _locA,
            <String, Object?>{'webhook_subscription_id': _subscriptionId});
      final api = _FakeCloverApi()
        ..unregisterError = CloverApiClientErrorException(
          'not found',
          uri: Uri.parse('https://api.clover.com/v3/apps/x/webhooks/y'),
          statusCode: 404,
          body: '',
        );
      final registry = CloverPosWebhookRegistry(
        TenantTransactionWrapper(pool),
        api: api,
        callbackUrlSource: () => _callbackUrl,
      );

      final ok = await registry.unregister(
        operatorId: _opA,
        locationId: _locA,
        merchantId: _merchantId,
        subscriptionId: _subscriptionId,
      );

      expect(ok, isTrue);
      expect(pool.metadata['$_opA|$_locA|clover']!.containsKey('webhook_subscription_id'),
          isFalse);
    });

    test('returns false on auth error but still clears metadata', () async {
      final pool = _FakePool()
        ..seedConnection(_opA, _locA)
        ..seedMetadata(_opA, _locA,
            <String, Object?>{'webhook_subscription_id': _subscriptionId});
      final api = _FakeCloverApi()
        ..unregisterError = CloverApiAuthException(
          '401',
          uri: Uri.parse('https://api.clover.com/v3/apps/x/webhooks/y'),
          statusCode: 401,
          body: '',
        );
      final registry = CloverPosWebhookRegistry(
        TenantTransactionWrapper(pool),
        api: api,
        callbackUrlSource: () => _callbackUrl,
      );

      final ok = await registry.unregister(
        operatorId: _opA,
        locationId: _locA,
        merchantId: _merchantId,
        subscriptionId: _subscriptionId,
      );

      expect(ok, isFalse);
      expect(pool.metadata['$_opA|$_locA|clover']!.containsKey('webhook_subscription_id'),
          isFalse);
    });

    test('rejects empty subscription id', () async {
      final registry = CloverPosWebhookRegistry(
        TenantTransactionWrapper(_FakePool()),
        api: _FakeCloverApi(),
        callbackUrlSource: () => _callbackUrl,
      );
      expect(
        () => registry.unregister(
          operatorId: _opA,
          locationId: _locA,
          merchantId: _merchantId,
          subscriptionId: '',
        ),
        throwsArgumentError,
      );
    });
  });
}

// ─── Test doubles ────────────────────────────────────────────────────

class _FakeCloverApi implements CloverApiClient {
  int registerCalls = 0;
  int unregisterCalls = 0;
  String? lastRegisterMerchantId;
  String? lastRegisterCallbackUrl;
  CloverApiException? unregisterError;

  @override
  Future<CloverOrdersPage> listOrders({
    required String merchantId,
    required DateTime modifiedFrom,
    required DateTime modifiedTo,
    required int offset,
    required int limit,
  }) async {
    return const CloverOrdersPage(
      elements: <Map<String, Object?>>[],
      nextOffset: null,
    );
  }

  @override
  Future<Map<String, Object?>> getOrder({
    required String merchantId,
    required String orderId,
  }) async =>
      const <String, Object?>{};

  @override
  Future<String> registerWebhook({
    required String merchantId,
    required String callbackUrl,
    required List<String> eventTypes,
  }) async {
    registerCalls += 1;
    lastRegisterMerchantId = merchantId;
    lastRegisterCallbackUrl = callbackUrl;
    return _subscriptionId;
  }

  @override
  Future<void> unregisterWebhook({
    required String merchantId,
    required String subscriptionId,
  }) async {
    unregisterCalls += 1;
    final err = unregisterError;
    if (err != null) throw err;
  }
}

class _FakePool implements PostgresPool {
  /// `(operator_id, location_id, vendor_id)` -> mutable metadata map.
  final Map<String, Map<String, Object?>> metadata =
      <String, Map<String, Object?>>{};
  final Map<String, bool> webhookProvisioned = <String, bool>{};
  final Set<String> _connections = <String>{};

  void seedConnection(String operatorId, String locationId) {
    _connections.add('$operatorId|$locationId|clover');
    metadata.putIfAbsent('$operatorId|$locationId|clover',
        () => <String, Object?>{});
    webhookProvisioned.putIfAbsent(
        '$operatorId|$locationId|clover', () => false);
  }

  void seedMetadata(
    String operatorId,
    String locationId,
    Map<String, Object?> values,
  ) {
    final key = '$operatorId|$locationId|clover';
    metadata[key] = <String, Object?>{
      ...?metadata[key],
      ...values,
    };
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _FakeTransaction(this);
  }
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
    if (sql.contains("metadata->>'webhook_subscription_id'")) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final key = '$operatorId|$locationId|clover';
      if (!pool._connections.contains(key)) return const <PostgresRow>[];
      final value = pool.metadata[key]?['webhook_subscription_id'];
      return <PostgresRow>[
        <String, Object?>{'webhook_subscription_id': value},
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
    if (sql.contains('update public.connector_connection')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final key = '$operatorId|$locationId|clover';
      if (!pool._connections.contains(key)) return 0;
      final current = pool.metadata.putIfAbsent(key, () => <String, Object?>{});
      if (sql.contains('jsonb_build_object')) {
        // Add the subscription id key.
        final subId = parameters['subscription_id'] as String;
        current['webhook_subscription_id'] = subId;
        pool.webhookProvisioned[key] = true;
      } else if (sql.contains("- 'webhook_subscription_id'")) {
        // Remove the subscription id key.
        current.remove('webhook_subscription_id');
        pool.webhookProvisioned[key] = false;
      }
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
