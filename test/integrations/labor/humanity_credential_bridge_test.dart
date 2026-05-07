// Phase 8 framework — HumanityBrokerCredentialBridge tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/humanity_credential_bridge.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart'
    show VendorCredentialHandle;

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('resolveAccessToken delegates to the broker', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'humanity-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      refreshTokenByOp: <String, String>{_opId: 'humanity-refresh'},
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final bridge = HumanityBrokerCredentialBridge(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthRefresh: (_) => throw StateError('refresh should not run'),
    );
    final token = await bridge.resolveAccessToken(
      const VendorCredentialHandle(credentialId: 'c-1'),
    );
    expect(token, equals('humanity-bearer'));
    final refresh = await bridge.resolveRefreshToken(
      const VendorCredentialHandle(credentialId: 'c-1'),
    );
    expect(refresh, equals('humanity-refresh'));
  });
}
