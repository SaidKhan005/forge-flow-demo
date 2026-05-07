// Phase 8 framework — LightspeedLskBrokerAccessTokenResolver tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('resolveAccessToken delegates to the broker', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'lsk-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      refreshTokenByOp: <String, String>{_opId: 'lsk-refresh'},
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final resolver = LightspeedLskBrokerAccessTokenResolver(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthRefresh: (_) => throw StateError('refresh should not run'),
    );
    final access = await resolver.resolveAccessToken('cred-1');
    expect(access, equals('lsk-bearer'));
    final refresh = await resolver.resolveRefreshToken('cred-1');
    expect(refresh, equals('lsk-refresh'));
  });
}
