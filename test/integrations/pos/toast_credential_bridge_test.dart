// Phase 8 framework — ToastBrokerAccessTokenResolver tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/integrations/pos/toast_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/toast_pos_adapter.dart'
    show ToastCredentialHandle;

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('resolveAccessToken delegates to the broker', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'toast-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final resolver = ToastBrokerAccessTokenResolver(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthExchange: (_) => throw StateError('refresh should not run'),
    );
    final token = await resolver.resolveAccessToken(
      credentials: const ToastCredentialHandle(
        connectionId: 'conn-1',
        restaurantGuid: 'rg-1',
      ),
    );
    expect(token, equals('toast-bearer'));
    final setLocalIdx = pool.transactions.single.executedSql
        .indexWhere((s) => s.contains("'app.operator_id'"));
    expect(
      pool.transactions.single.parameters[setLocalIdx]['value'],
      equals(_opId),
    );
  });

  test('forceRefresh: true bypasses cache and runs the closure', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'toast-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    var refreshCalls = 0;
    final resolver = ToastBrokerAccessTokenResolver(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthExchange: (_) async {
        refreshCalls += 1;
        return TokenRefreshResult(
          accessToken: 'fresh-toast-bearer',
          expiresAt:
              DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
      },
    );
    final fresh = await resolver.resolveAccessToken(
      credentials: const ToastCredentialHandle(
        connectionId: 'conn-1',
        restaurantGuid: 'rg-1',
      ),
      forceRefresh: true,
    );
    expect(fresh, equals('fresh-toast-bearer'));
    expect(refreshCalls, equals(1));
  });
}
